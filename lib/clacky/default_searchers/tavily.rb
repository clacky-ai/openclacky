#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8

#
# Clacky Tavily Searcher — CLI interface
#
# Usage:
#   ruby tavily.rb "<query>" [max_results]
#
# Input:
#   ENV["CLACKY_SEARCH_KEY"] — Tavily API key (set from ~/.clacky/search.yml)
#
# Output:
#   stdout — JSON array of {"title","url","snippet"}
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# Dependencies: none (stdlib only)
#
# This file lives in ~/.clacky/searchers/ and can be modified by the user.
# Copy it as a starting point for other providers (Serper, Brave, an internal
# search service...) — anything honouring the contract above works.
#
# VERSION: 1

require "net/http"
require "json"
require "uri"

API_URL = "https://api.tavily.com/search"
TIMEOUT = 20

def fail_with(message)
  warn message
  exit 1
end

query = ARGV[0].to_s.strip
max_results = (ARGV[1] || 10).to_i
max_results = 10 if max_results <= 0

fail_with("Usage: tavily.rb \"<query>\" [max_results]") if query.empty?

api_key = ENV["CLACKY_SEARCH_KEY"].to_s.strip
fail_with("Tavily API key is not configured") if api_key.empty?

uri = URI(API_URL)
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
http.open_timeout = TIMEOUT
http.read_timeout = TIMEOUT

request = Net::HTTP::Post.new(uri)
request["Content-Type"] = "application/json"
request["Authorization"] = "Bearer #{api_key}"
request.body = JSON.generate(
  query: query,
  search_depth: "basic",
  max_results: [max_results, 20].min,
  include_answer: false,
  include_images: false,
  include_raw_content: false
)

begin
  response = http.request(request)
rescue StandardError => e
  fail_with("Tavily request failed: #{e.message}")
end

unless response.is_a?(Net::HTTPSuccess)
  detail = begin
    JSON.parse(response.body)["detail"] || response.body
  rescue StandardError
    response.body
  end
  fail_with("Tavily returned #{response.code}: #{detail.to_s[0, 200]}")
end

begin
  payload = JSON.parse(response.body)
rescue JSON::ParserError => e
  fail_with("Tavily returned malformed JSON: #{e.message}")
end

results = Array(payload["results"]).filter_map do |item|
  next unless item.is_a?(Hash)

  url = item["url"].to_s
  next if url.empty?

  snippet = item["content"].to_s.gsub(/\s+/, " ").strip
  { "title" => item["title"].to_s, "url" => url, "snippet" => snippet[0, 400] }
end

puts JSON.generate(results)
