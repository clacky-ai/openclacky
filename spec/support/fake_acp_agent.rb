# frozen_string_literal: true

require "json"
require "rbconfig"

STDOUT.sync = true
STDERR.sync = true

def emit(payload)
  STDOUT.write(JSON.generate(payload))
  STDOUT.write("\n")
end

def respond(id, result)
  return unless id

  emit("jsonrpc" => "2.0", "id" => id, "result" => result)
end

def append_shutdown_marker(value)
  path = ENV["FAKE_ACP_SHUTDOWN_MARKER"]
  return unless path && !path.empty?

  File.open(path, "a") { |file| file.puts(value) }
end

term_received = false
term_recorded = false
child_pids = []
trap("TERM") { term_received = true }

STDIN.each_line do |line|
  message = JSON.parse(line)
  id = message["id"]
  method = message["method"]
  params = message["params"] || {}

  unless method
    emit(
      "jsonrpc" => "2.0",
      "method" => "fake/reverse_response",
      "params" => { "response" => message }
    )
    next
  end

  case method
  when "initialize"
    respond(
      id,
      "protocolVersion" => 1,
      "agentCapabilities" => {
        "loadSession" => true,
        "promptCapabilities" => { "image" => true }
      },
      "authMethods" => [{ "id" => "chat-gpt", "name" => "ChatGPT" }],
      "agentInfo" => { "name" => "fake-acp-agent", "version" => "1.0.0" }
    )
  when "session/prompt"
    emit(
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => {
        "sessionId" => params["sessionId"],
        "update" => {
          "sessionUpdate" => "agent_message_chunk",
          "content" => { "type" => "text", "text" => "fake response" }
        }
      }
    )
    respond(id, "stopReason" => "end_turn")
  when "fake/notify"
    emit(
      params["message"] || {
        "jsonrpc" => "2.0",
        "method" => "fake/notification",
        "params" => params
      }
    )
    respond(id, "sent" => true)
  when "fake/reverse_request"
    emit(
      "jsonrpc" => "2.0",
      "id" => params["id"] || 900,
      "method" => params["method"] || "session/request_permission",
      "params" => params["request_params"] || {}
    )
    respond(id, "sent" => true)
  when "fake/inspect"
    env = Array(params["env_keys"]).each_with_object({}) do |key, values|
      values[key] = ENV[key]
    end
    respond(
      id,
      "argv" => ARGV.dup,
      "cwd" => Dir.pwd,
      "pid" => Process.pid,
      "pgid" => Process.getpgrp,
      "env" => env
    )
  when "fake/malformed"
    STDOUT.write(params["line"] || "{not-json")
    STDOUT.write("\n")
    respond(id, "sent" => true)
  when "fake/oversized"
    emit(
      "jsonrpc" => "2.0",
      "method" => "fake/oversized",
      "params" => { "data" => "x" * (params["bytes"] || 4096).to_i }
    )
    respond(id, "sent" => true)
  when "fake/stderr"
    STDERR.write(params["text"].to_s)
    STDERR.write("\n")
    respond(id, "written" => true)
  when "fake/spawn_child"
    child = Process.spawn(
      RbConfig.ruby,
      "-e",
      'trap("TERM") { exit! 0 }; loop { sleep 1 }',
      out: File::NULL,
      err: File::NULL
    )
    child_pids << child
    respond(id, "pid" => child)
  when "fake/exit"
    exit(params.fetch("status", 0).to_i)
  else
    emit(
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => { "code" => -32_601, "message" => "Method not found" }
    )
  end
end

append_shutdown_marker("stdin_closed")

if ENV["FAKE_ACP_LINGER_ON_EOF"] == "1"
  loop do
    if term_received && !term_recorded
      append_shutdown_marker("term")
      term_recorded = true
    end

    if term_received && ENV["FAKE_ACP_IGNORE_TERM"] != "1"
      child_pids.each do |pid|
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
        end
      end
      exit(0)
    end

    sleep(0.01)
  end
end
