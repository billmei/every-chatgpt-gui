#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'optparse'

# Parse command line options
options = {
  token: ENV['GITHUB_TOKEN'],
  sleep: 1
}

OptionParser.new do |opts|
  opts.banner = "Usage: github_data_enhancer.rb [options] <input_file> [output_file]"
  
  opts.on("-t", "--token TOKEN", "GitHub API token (can also use GITHUB_TOKEN env var)") do |t|
    options[:token] = t
  end
  
  opts.on("-s", "--sleep SECONDS", "Sleep time between API calls (default: 1)") do |s|
    options[:sleep] = s.to_f
  end
  
  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

# Constants
GITHUB_API_BASE = "https://api.github.com"
RATE_LIMIT_SLEEP = options[:sleep]  # Sleep between API calls

# Helper method to extract GitHub user and repo from URL
def extract_github_info(url)
  # Skip if URL doesn't contain github.com
  return nil unless url && url.include?('github.com')
  
  # Extract user and repo from the URL
  # Format could be:
  # - https://github.com/user/repo
  # - github.com/user/repo
  parts = url.split('github.com/').last.split('/')
  return nil if parts.length < 2
  
  user = parts[0]
  repo = parts[1]
  
  # Remove any trailing elements like .git or query parameters
  repo = repo.split(/[.#?]/)[0]
  
  # Additional validation
  return nil if user.nil? || user.empty? || repo.nil? || repo.empty?
  
  return { user: user, repo: repo }
end

# Helper method to fetch data from GitHub API
def fetch_github_data(endpoint, token = nil)
  uri = URI.parse("#{GITHUB_API_BASE}#{endpoint}")
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/vnd.github.v3+json"
  request["User-Agent"] = "Ruby/GitHub-Data-Enhancer"
  
  # Add authentication token if provided
  request["Authorization"] = "token #{token}" if token && !token.empty?
  
  begin
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.read_timeout = 10  # Set timeout to avoid hanging
      http.request(request)
    end
  rescue => e
    puts "Network error when accessing #{endpoint}: #{e.message}"
    return nil
  end
  
  if response.code == "200"
    return JSON.parse(response.body)
  elsif response.code == "403" && response.body.include?("rate limit")
    puts "Rate limit exceeded. Please use a GitHub token with: -t YOUR_TOKEN"
    puts "Or set the GITHUB_TOKEN environment variable."
    exit 1
  elsif response.code == "404"
    puts "Resource not found at #{endpoint}"
    return nil
  else
    puts "Error fetching data from #{endpoint}: #{response.code} - #{response.body}"
    return nil
  end
end

# Categorize technologies into languages and frameworks
def categorize_technologies(languages_data)
  # Ensure we handle nil, empty, or non-hash responses
  return { language: nil, framework: nil } if !languages_data.is_a?(Hash) || languages_data.empty?
  
  # Programming languages (distinct from frameworks)
  programming_languages = [
    'JavaScript', 'TypeScript', 'Python', 'Java', 'Ruby', 'Go', 'PHP', 'C#', 
    'C++', 'C', 'Rust', 'Swift', 'Kotlin', 'Scala', 'Perl', 'Lua', 'Haskell',
    'Elixir', 'Erlang', 'Clojure', 'F#', 'Dart', 'R', 'Julia'
  ]
  
  # Framework mapping
  frameworks = [
    'Vue', 'React', 'Angular', 'Svelte', 'Next.js', 'Nuxt', 'Remix', 'Express', 
    'Rails', 'Django', 'Flask', 'Laravel', 'Spring', 'Symfony', 'ASP.NET', 
    'Phoenix', 'jQuery', 'TensorFlow', 'PyTorch', 'Electron', 'Bootstrap',
    'Tailwind', 'Nest.js', 'FastAPI', 'Redux', 'Vuex', 'Vuetify'
  ]
  
  # Filter out non-relevant technologies
  non_relevant = ['HTML', 'CSS', 'Dockerfile', 'Makefile', 'Shell', 'Batchfile', 'PowerShell']
  filtered_data = languages_data.reject { |lang, _| non_relevant.include?(lang) }
  return { language: nil, framework: nil } if filtered_data.empty?
  
  # Sort by byte count descending
  sorted_techs = filtered_data.sort_by { |_, count| -count }
  
  # First identify frameworks
  found_frameworks = sorted_techs.select { |tech, _| frameworks.include?(tech) }
                              .map { |tech, _| tech }
                              .take(2)
                              .join(', ')
  
  # Then identify the primary language (not including identified frameworks)
  primary_language = nil
  
  # First try to find a recognized programming language
  sorted_techs.each do |tech, _|
    # Skip if it's already identified as a framework
    next if found_frameworks.include?(tech)
    
    if programming_languages.include?(tech)
      primary_language = tech
      # Treat TypeScript as JavaScript
      primary_language = 'JavaScript' if tech == 'TypeScript'
      break
    end
  end
  
  # If no known language found, use the highest count entry that's not a framework
  if primary_language.nil? && !sorted_techs.empty?
    # Use the first technology that's not a framework
    non_framework_techs = sorted_techs.reject { |tech, _| frameworks.include?(tech) }
    primary_language = non_framework_techs.first[0] unless non_framework_techs.empty?
  end
  
  return { 
    language: primary_language, 
    framework: found_frameworks.empty? ? nil : found_frameworks
  }
end

# Main function to enhance a row with GitHub data
def enhance_row(row, token = nil)
  # Look for GitHub URL in the row - more robust pattern
  github_url = row.match(/\((https?:\/\/(?:www\.)?github\.com\/[^)\s]+)\)/)
  return row unless github_url
  
  # Extract the URL from markdown format
  url = github_url[1]
  github_info = extract_github_info(url)
  return row unless github_info
  
  # Call GitHub API to get repository info
  puts "Fetching data for #{github_info[:user]}/#{github_info[:repo]}..."
  sleep(RATE_LIMIT_SLEEP)
  repo_data = fetch_github_data("/repos/#{github_info[:user]}/#{github_info[:repo]}", token)
  unless repo_data
    puts "Warning: Could not fetch repository data for #{github_info[:user]}/#{github_info[:repo]}"
    return row
  end
  
  # Call GitHub API to get languages info
  sleep(RATE_LIMIT_SLEEP)
  languages_data = fetch_github_data("/repos/#{github_info[:user]}/#{github_info[:repo]}/languages", token)
  unless languages_data
    puts "Warning: Could not fetch language data for #{github_info[:user]}/#{github_info[:repo]}"
  end
  
  # Extract stars and categorize technologies
  stars = repo_data["stargazers_count"]
  tech_info = categorize_technologies(languages_data)
  
  # Add the information to the row
  enhanced_row = row.chomp
  if tech_info[:language] || stars
    enhanced_row += " | "
    enhanced_row += tech_info[:language] if tech_info[:language]
    enhanced_row += " | #{tech_info[:framework]}" if tech_info[:framework]
    enhanced_row += " | #{stars} ⭐" if stars
  end
  
  return enhanced_row
end

# Main function to process the file
def process_file(input_file, token = nil)
  output_lines = []
  processed_count = 0
  enhanced_count = 0
  
  File.readlines(input_file, encoding: 'UTF-8').each_with_index do |line, index|
    begin
      # Skip lines that are not items or are headers
      if line.strip.start_with?("- ") && line.include?("[") && line.include?("]")
        processed_count += 1
        original_line = line.dup
        enhanced_line = enhance_row(line, token)
        
        # Check if line was actually enhanced
        enhanced_count += 1 if enhanced_line != original_line.chomp
        
        output_lines << enhanced_line
      else
        output_lines << line.chomp
      end
    rescue => e
      puts "Warning: Error processing line #{index+1}: #{e.message}"
      output_lines << line.chomp
    end
  end
  
  puts "Processed #{processed_count} items, enhanced #{enhanced_count} items"
  return output_lines.join("\n")
end

# Main execution
if ARGV.length < 1
  puts "Usage: ruby github_data_enhancer.rb [options] <input_file> [output_file]"
  puts "Use --help for more options"
  exit 1
end

input_file = ARGV[0]
output_file = ARGV[1] || "#{input_file}.enhanced.md"

begin
  # Check if input file exists
  unless File.exist?(input_file)
    puts "Error: Input file '#{input_file}' does not exist"
    exit 1
  end
  
  # Check token and warn if not provided
  if options[:token].nil? || options[:token].empty?
    puts "Warning: No GitHub token provided. You may hit rate limits."
    puts "Set GITHUB_TOKEN environment variable or use -t/--token option."
  else
    puts "Using GitHub token for authentication"
  end
  
  puts "Processing #{input_file}..."
  enhanced_content = process_file(input_file, options[:token])
  
  begin
    File.open(output_file, 'w') do |file|
      file.puts enhanced_content
    end
    puts "Enhanced content written to #{output_file}"
  rescue Errno::EACCES => e
    puts "Error: Permission denied when writing to '#{output_file}'"
    exit 1
  rescue => e
    puts "Error writing to output file: #{e.message}"
    exit 1
  end
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace
  exit 1
end
