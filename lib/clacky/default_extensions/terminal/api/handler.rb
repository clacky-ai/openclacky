# frozen_string_literal: true

require_relative "runtime"

# Interactive shell for the right-hand panel.
#
# Split of responsibilities:
#   - HTTP builds a shell: it is the only layer that can resolve a session's
#     working directory through `session_manager`.
#   - WebSocket carries the data plane (`ext.terminal.*` frames), because the
#     PTY reader thread can push output to one connection without polling.
#
# Every route is localhost-only. A terminal is arbitrary command execution, and
# the server can be bound to a LAN/public address with an access key — the key
# protects the UI, not the machine behind it.
class TerminalExtension < Clacky::ApiExtension
  LOOPBACK = %w[127.0.0.1 ::1 ::ffff:127.0.0.1 ::ffff:0:0:1].freeze
  WS_PREFIX = "ext.terminal."

  get "/info" do
    json(
      local: local_request?,
      shell: Clacky::Extensions::Terminal::Runtime::Session.default_shell,
      sessions: local_request? ? Clacky::Extensions::Terminal::Runtime.list : []
    )
  end

  post "/open" do
    error!("terminals are only available to clients on this machine", status: 403) unless local_request?

    body = json_body
    session = begin
      Clacky::Extensions::Terminal::Runtime.open(
        cwd:  working_dir_for(body["session_id"]),
        cols: clamp_int(body["cols"], 1, 1000, 80),
        rows: clamp_int(body["rows"], 1, 500, 24)
      )
    rescue Clacky::Extensions::Terminal::Runtime::PlatformError => e
      error!(e.message, status: 501)
    rescue Clacky::Extensions::Terminal::Runtime::CapacityError => e
      error!(e.message, status: 429)
    end

    json(term_id: session.id, cwd: session.cwd, shell: session.shell)
  end

  post "/close" do
    error!("terminals are only available to clients on this machine", status: 403) unless local_request?

    Clacky::Extensions::Terminal::Runtime.close(json_body["term_id"])
    json(ok: true)
  end

  # Runs on the WebSocket reader thread: every branch must stay cheap. Anything
  # that could block (spawning a shell, resolving a session) lives in a route.
  def self.on_ws_event(conn, message)
    type = message["type"].to_s
    return false unless type.start_with?(WS_PREFIX)

    runtime = Clacky::Extensions::Terminal::Runtime
    term_id = message["term_id"].to_s

    case type.delete_prefix(WS_PREFIX)
    when "attach"
      session = runtime.find(term_id)
      # A restarted server has no shells, so the client would otherwise keep a
      # pane that can never print again.
      if session
        session.attach(conn)
      else
        conn.send_json(type: "ext.terminal.gone", term_id: term_id)
      end
    when "input"
      runtime.find(term_id)&.write(message["data"].to_s)
    when "resize"
      runtime.find(term_id)&.resize(message["cols"], message["rows"])
    when "detach"
      runtime.find(term_id)&.detach(conn)
    when "close"
      runtime.close(term_id)
    else
      return false
    end
    true
  end

  def self.on_ws_close(conn)
    Clacky::Extensions::Terminal::Runtime.detach(conn)
  end

  private def local_request?
    ip = begin
      req.remote_ip
    rescue StandardError
      nil
    end
    ip ||= begin
      peer = req.peeraddr
      peer && peer[3]
    rescue StandardError
      nil
    end
    LOOPBACK.include?(ip.to_s)
  end

  private def working_dir_for(session_id)
    id = session_id.to_s
    data = id.empty? ? nil : session_manager&.load(id)
    dir = data && data[:working_dir].to_s
    return Dir.home if dir.nil? || dir.empty? || !Dir.exist?(dir)

    dir
  end

  private def clamp_int(value, min, max, fallback)
    number = value.to_i
    return fallback unless number.positive?

    [[number, min].max, max].min
  end
end
