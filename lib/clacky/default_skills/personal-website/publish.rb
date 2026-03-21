#!/usr/bin/env ruby
# publish.rb — Publish or delete a profile card on the platform
#
# Usage:
#   ruby publish.rb publish --name "NAME" --html-file /path/to/card.html
#   ruby publish.rb delete  --slug SLUG
#
# On first publish, prints the card URL and saves the update token to
# ~/.clacky/card_token (used for future updates/deletes).
#
# Environment:
#   CARD_API_BASE   — platform base URL (default: https://app.clacky.ai)
#   CARD_HMAC_SECRET — shared secret (default matches platform default)

require "net/http"
require "uri"
require "json"
require "openssl"
require "digest"
require "optparse"
require "fileutils"

# ── Config ───────────────────────────────────────────────────────────────────

API_BASE     = ENV.fetch("CLACKY_LICENSE_SERVER", "https://www.openclacky.com")
HMAC_SECRET  = ENV.fetch("CARD_HMAC_SECRET", "openclacky-card-v1-default-secret-change-me")
TOKEN_FILE   = File.expand_path("~/clacky_workspace/personal_website/token.json")

# ── HMAC signing ─────────────────────────────────────────────────────────────

def device_fingerprint
  # Combine stable machine identifiers into an opaque hash
  parts = []
  parts << `hostname`.strip
  # macOS: hardware UUID
  hw = `system_profiler SPHardwareDataType 2>/dev/null | grep 'Hardware UUID'`.strip
  parts << hw unless hw.empty?
  # Fallback: username
  parts << ENV["USER"].to_s
  Digest::SHA256.hexdigest(parts.join("|"))[0, 16]
end

def hmac_headers
  ts          = Time.now.to_i.to_s
  fingerprint = device_fingerprint
  payload     = "openclacky:#{ts}:#{fingerprint}"
  signature   = OpenSSL::HMAC.hexdigest("SHA256", HMAC_SECRET, payload)
  {
    "X-Card-Timestamp"   => ts,
    "X-Card-Fingerprint" => fingerprint,
    "X-Card-Signature"   => signature,
    "Content-Type"       => "application/json"
  }
end

# ── HTTP helpers ──────────────────────────────────────────────────────────────

def http_request(method, path, body: nil)
  uri  = URI.parse("#{API_BASE}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.read_timeout = 15
  http.open_timeout = 10

  req_class = { "POST" => Net::HTTP::Post, "PATCH" => Net::HTTP::Patch,
                "DELETE" => Net::HTTP::Delete }[method]
  req = req_class.new(uri.path)
  hmac_headers.each { |k, v| req[k] = v }
  req.body = body.to_json if body

  response = http.request(req)
  parsed   = JSON.parse(response.body) rescue { "raw" => response.body }
  [response.code.to_i, parsed]
rescue => e
  warn "❌ Network error: #{e.message}"
  exit 1
end

# ── Token storage ─────────────────────────────────────────────────────────────

def load_token_data
  return {} unless File.exist?(TOKEN_FILE)
  JSON.parse(File.read(TOKEN_FILE)) rescue {}
end

def save_token_data(data)
  FileUtils.mkdir_p(File.dirname(TOKEN_FILE))
  File.write(TOKEN_FILE, JSON.pretty_generate(data))
  File.chmod(0600, TOKEN_FILE)
end

# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_publish(name:, html_file:)
  unless File.exist?(html_file)
    warn "❌ HTML file not found: #{html_file}"
    exit 1
  end

  html_content = File.read(html_file, encoding: "utf-8")

  if html_content.bytesize > 1_048_576
    warn "❌ HTML file exceeds 1MB (#{html_content.bytesize / 1024}KB)"
    exit 1
  end

  token_data = load_token_data

  # If we already have a slug + token, do an update (PATCH) instead of create
  if token_data["slug"] && token_data["update_token"]
    slug  = token_data["slug"]
    token = token_data["update_token"]

    uri  = URI.parse("#{API_BASE}/api/v1/personal_websites/#{slug}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    req  = Net::HTTP::Patch.new(uri.path)
    hmac_headers.each { |k, v| req[k] = v }
    req["X-Card-Token"] = token
    req.body = { html_content: html_content }.to_json
    resp   = http.request(req)
    status = resp.code.to_i
    body   = JSON.parse(resp.body) rescue { "raw" => resp.body }

    if status == 200
      puts "✅ Website updated: #{body["url"]}"
    else
      warn "❌ Update failed (#{status}): #{body["error"] || body.inspect}"
      exit 1
    end
  else
    # First publish — POST to create
    status, body = http_request("POST", "/api/v1/personal_websites",
      body: { name: name, html_content: html_content })

    if status == 201
      save_token_data("slug" => body["slug"], "update_token" => body["update_token"])
      puts "✅ Website published: #{body["url"]}"
      puts "   Slug: #{body["slug"]}"
      puts "   Token saved to: #{TOKEN_FILE}"
    else
      warn "❌ Publish failed (#{status}): #{body["error"] || body.inspect}"
      exit 1
    end
  end
end

def cmd_delete(slug: nil)
  token_data = load_token_data
  token = token_data["update_token"]
  slug  = slug || token_data["slug"]

  unless token && slug
    warn "❌ No published website found (#{TOKEN_FILE} missing or incomplete)."
    warn "   Nothing to delete."
    exit 1
  end

  uri  = URI.parse("#{API_BASE}/api/v1/personal_websites/#{slug}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  req  = Net::HTTP::Delete.new(uri.path)
  hmac_headers.each { |k, v| req[k] = v }
  req["X-Card-Token"] = token

  resp   = http.request(req)
  status = resp.code.to_i
  body   = JSON.parse(resp.body) rescue { "raw" => resp.body }

  if status == 200
    File.delete(TOKEN_FILE) if File.exist?(TOKEN_FILE)
    puts "✅ Personal website deleted: /~#{slug}"
  else
    warn "❌ Delete failed (#{status}): #{body["error"] || body.inspect}"
    exit 1
  end
rescue => e
  warn "❌ Network error: #{e.message}"
  exit 1
end

# ── CLI parsing ───────────────────────────────────────────────────────────────

command = ARGV.shift

case command
when "publish"
  options = {}
  OptionParser.new do |opts|
    opts.on("--name NAME")          { |v| options[:name]      = v }
    opts.on("--html-file FILE")     { |v| options[:html_file] = v }
  end.parse!

  unless options[:name] && options[:html_file]
    warn "Usage: ruby publish.rb publish --name NAME --html-file FILE"
    exit 1
  end

  cmd_publish(name: options[:name], html_file: File.expand_path(options[:html_file]))

when "delete"
  options = {}
  OptionParser.new do |opts|
    opts.on("--slug SLUG") { |v| options[:slug] = v }  # optional, auto-read from token file
  end.parse!

  cmd_delete(slug: options[:slug])

else
  warn "Usage: ruby publish.rb publish|delete [options]"
  warn "  publish --name NAME --html-file FILE"
  warn "  delete  --slug SLUG"
  exit 1
end
