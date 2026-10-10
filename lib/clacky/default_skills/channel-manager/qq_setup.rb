#!/usr/bin/env ruby
# frozen_string_literal: true

# QQ channel setup helper for the channel-manager skill.
#
# Usage:
#   qq_setup.rb --validate "<APP_ID> <APP_SECRET>" [--sandbox]
#
# Exchanges the AppID/AppSecret for a bot access_token via the QQ Open
# Platform, so the skill can validate credentials BEFORE posting them to the
# server API. Prints a small JSON document on success; exits non-zero with an
# error message on failure. Uses only the Ruby standard library.

require "json"
require "net/http"
require "uri"

PORTAL_URL = "https://q.qq.com"
# The token endpoint is shared by production and sandbox ("不区分正式环境、沙箱环境");
# only the openapi host differs.
TOKEN_URL = "https://api.bot.qq.com/app/getAppAccessToken"

def fail!(message)
  warn({ "ok" => false, "error" => message }.to_json)
  exit 1
end

def print_usage
  warn "Usage: #{$PROGRAM_NAME} --validate \"<APP_ID> <APP_SECRET>\" [--sandbox]"
  warn "       #{$PROGRAM_NAME} --portal-url"
  exit 2
end

def parse_pair(pair)
  app_id, app_secret = pair.to_s.split(/\s+/, 2)
  fail!("missing app_id or app_secret") if app_id.nil? || app_id.empty? || app_secret.nil? || app_secret.empty?
  [app_id, app_secret]
end

def request_token(app_id, app_secret)
  uri = URI(TOKEN_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = { appId: app_id, clientSecret: app_secret }.to_json
  http.request(req)
end

def parse_body(res)
  JSON.parse(res.body)
rescue JSON::ParserError
  fail!("non-JSON response (HTTP #{res.code})")
end

def validate!(pair, sandbox: false)
  app_id, app_secret = parse_pair(pair)
  res = request_token(app_id, app_secret)
  data = parse_body(res)
  if res.is_a?(Net::HTTPSuccess) && data["access_token"]
    puts({ "ok" => true, "app_id" => app_id, "sandbox" => sandbox, "expires_in" => data["expires_in"] }.to_json)
  else
    fail!(data["message"] || data["msg"] || "token request failed (HTTP #{res.code})")
  end
end

mode = ARGV.first
print_usage if mode.nil?

case mode
when "--portal-url"
  puts PORTAL_URL
when "--validate"
  validate!(ARGV[1], sandbox: ARGV.include?("--sandbox"))
else
  print_usage
end
