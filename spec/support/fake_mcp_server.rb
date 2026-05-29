#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal MCP server for end-to-end testing. Speaks JSON-RPC 2.0 over stdio,
# implements: initialize, tools/list, tools/call.
# Tools:
#   echo(message: string) -> echoes back
#   add(a: number, b: number) -> sum

require "json"

STDOUT.sync = true

TOOLS = [
  {
    "name" => "echo",
    "description" => "Echo back the provided message.",
    "inputSchema" => {
      "type" => "object",
      "properties" => {
        "message" => { "type" => "string" }
      },
      "required" => ["message"]
    }
  },
  {
    "name" => "add",
    "description" => "Return the sum of a and b.",
    "inputSchema" => {
      "type" => "object",
      "properties" => {
        "a" => { "type" => "number" },
        "b" => { "type" => "number" }
      },
      "required" => ["a", "b"]
    }
  }
].freeze

def reply(id, result)
  STDOUT.puts JSON.generate(jsonrpc: "2.0", id: id, result: result)
end

def reply_error(id, code, message)
  STDOUT.puts JSON.generate(jsonrpc: "2.0", id: id, error: { code: code, message: message })
end

while (line = STDIN.gets)
  line.strip!
  next if line.empty?

  begin
    msg = JSON.parse(line)
  rescue JSON::ParserError
    next
  end

  method = msg["method"]
  id     = msg["id"]
  params = msg["params"] || {}

  case method
  when "initialize"
    reply(id, {
      "protocolVersion" => "2024-11-05",
      "capabilities" => { "tools" => {} },
      "serverInfo" => { "name" => "fake-mcp", "version" => "0.1.0" }
    })
  when "notifications/initialized"
    # notification, no reply
  when "tools/list"
    reply(id, { "tools" => TOOLS })
  when "tools/call"
    name = params["name"]
    args = params["arguments"] || {}
    case name
    when "echo"
      reply(id, { "content" => [{ "type" => "text", "text" => "echo: #{args["message"]}" }] })
    when "add"
      sum = args["a"].to_f + args["b"].to_f
      reply(id, { "content" => [{ "type" => "text", "text" => sum.to_s }] })
    else
      reply_error(id, -32601, "Unknown tool: #{name}")
    end
  else
    reply_error(id, -32601, "Unknown method: #{method}") if id
  end
end
