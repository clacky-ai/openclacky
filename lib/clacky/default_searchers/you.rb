#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8

#
# Clacky You.com Searcher (keyed) — CLI interface
#
# Usage:
#   ruby you.rb "<query>" [max_results]
#
# Input:
#   ENV["CLACKY_SEARCH_KEY"] — You.com API key (set from ~/.clacky/search.yml);
#                              falls back to ENV["YDC_API_KEY"]
#
# Output:
#   stdout — JSON array of {"title","url","snippet"}
#   stderr — error messages
#   exit 0 — success
#   exit 1 — failure
#
# Dependencies: none (stdlib only)
#
# Without a key, the built-in web_search already uses You.com's free tier
# (100 searches/day per IP). This searcher is for keyed, higher-volume use.
#
# VERSION: 1

require "net/http"
require "json"
require "uri"

API_URL = "https://ydc-index.io/v1/search"
USER_AGENT = "youdotcom-integration/clacky-ai-openclacky"
TIMEOUT = 20

def fail_with(message)
  warn message
  exit 1
end

query = ARGV[0].to_s.strip
max_results = (ARGV[1] || 10).to_i
max_results = 10 if max_results <= 0

fail_with("Usage: you.rb \"<query>\" [max_results]") if query.empty?

api_key = ENV["CLACKY_SEARCH_KEY"].to_s.strip
api_key = ENV["YDC_API_KEY"].to_s.strip if api_key.empty?
fail_with("You.com API key is not configured") if api_key.empty?

uri = URI(API_URL)
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
http.open_timeout = TIMEOUT
http.read_timeout = TIMEOUT

request = Net::HTTP::Post.new(uri)
request["Content-Type"] = "application/json"
request["X-API-Key"] = api_key
request["User-Agent"] = USER_AGENT
request.body = JSON.generate(query: query, count: [max_results, 20].min)

begin
  response = http.request(request)
rescue StandardError => e
  fail_with("You.com request failed: #{e.message}")
end

unless response.is_a?(Net::HTTPSuccess)
  hint = case response.code.to_i
         when 401, 403 then "check the API key"
         when 402 then "out of credits"
         when 429 then "rate limited, retry after #{response["retry-after"] || "a moment"}s"
         end
  fail_with("You.com returned #{response.code}#{hint ? " (#{hint})" : ""}: #{response.body.to_s[0, 200]}")
end

begin
  payload = JSON.parse(response.body)
rescue JSON::ParserError => e
  fail_with("You.com returned malformed JSON: #{e.message}")
end

web = payload.is_a?(Hash) ? payload.dig("results", "web") : nil
results = Array(web).filter_map do |item|
  next unless item.is_a?(Hash)

  url = item["url"].to_s
  next if url.empty?

  snippet = item["description"].to_s
  snippet = Array(item["snippets"]).join(" ") if snippet.strip.empty?
  { "title" => item["title"].to_s, "url" => url, "snippet" => snippet.gsub(/\s+/, " ").strip[0, 400] }
end

puts JSON.generate(results.first(max_results))
