# frozen_string_literal: true

require "webrick"
require "websocket/driver"
require "json"
require "thread"
require "fileutils"
require_relative "session_registry"
require_relative "web_ui_controller"

module Clacky
  module Server
    # HttpServer runs an embedded WEBrick HTTP server with WebSocket support.
    #
    # Routes:
    #   GET  /                       → serves index.html (embedded web UI)
    #   GET  /api/sessions           → JSON list of sessions
    #   POST /api/sessions           → create a new session
    #   DELETE /api/sessions/:id     → delete a session
    #   GET  /ws                     → WebSocket upgrade (all real-time communication)
    class HttpServer
      WEB_ROOT = File.expand_path("../web", __dir__)

      def initialize(host: "127.0.0.1", port: 7070, agent_config:, client_factory:)
        @host           = host
        @port           = port
        @agent_config   = agent_config
        @client_factory = client_factory  # callable: -> { Clacky::Client.new(...) }
        @registry       = SessionRegistry.new
        @ws_clients     = {}  # session_id => [WebSocketConnection, ...]
        @ws_mutex       = Mutex.new
      end

      def start
        server = WEBrick::HTTPServer.new(
          BindAddress:     @host,
          Port:            @port,
          Logger:          WEBrick::Log.new(File::NULL),
          AccessLog:       []
        )

        # Mount all routes on the root servlet
        server.mount_proc("/") { |req, res| dispatch(req, res) }

        # Graceful shutdown on Ctrl-C
        trap("INT")  { server.shutdown }
        trap("TERM") { server.shutdown }

        puts "🌐 Clacky Web UI running at http://#{@host}:#{@port}"
        puts "   Press Ctrl-C to stop."

        # Auto-create a default session on startup
        create_default_session

        server.start
      end

      private

      # ── Router ────────────────────────────────────────────────────────────────

      def dispatch(req, res)
        path   = req.path
        method = req.request_method

        # WebSocket upgrade
        if websocket_upgrade?(req)
          handle_websocket(req, res)
          return
        end

        case [method, path]
        when ["GET",    "/"]                 then serve_index(res)
        when ["GET",    "/api/sessions"]     then api_list_sessions(res)
        when ["POST",   "/api/sessions"]     then api_create_session(req, res)
        else
          if method == "DELETE" && path.start_with?("/api/sessions/")
            session_id = path.sub("/api/sessions/", "")
            api_delete_session(session_id, res)
          else
            not_found(res)
          end
        end
      end

      # ── Static file ───────────────────────────────────────────────────────────

      def serve_index(res)
        html_path = File.join(WEB_ROOT, "index.html")
        if File.exist?(html_path)
          res.status       = 200
          res.content_type = "text/html; charset=utf-8"
          res.body         = File.read(html_path)
        else
          res.status = 404
          res.body   = "index.html not found"
        end
      end

      # ── REST API ──────────────────────────────────────────────────────────────

      def api_list_sessions(res)
        json_response(res, 200, { sessions: @registry.list })
      end

      def api_create_session(req, res)
        body = parse_json_body(req)
        name        = body["name"]
        working_dir = default_working_dir

        # Validate working directory
        unless Dir.exist?(working_dir)
          json_response(res, 422, { error: "Directory does not exist: #{working_dir}" })
          return
        end

        session_id = build_session(name: name, working_dir: working_dir)
        json_response(res, 201, { session: @registry.list.find { |s| s[:id] == session_id } })
      end

      # Auto-create a default session when the server starts.
      def create_default_session
        working_dir = default_working_dir
        FileUtils.mkdir_p(working_dir) unless Dir.exist?(working_dir)
        build_session(name: "Session 1", working_dir: working_dir)
      end

      def api_delete_session(session_id, res)
        if @registry.delete(session_id)
          # Notify connected clients the session is gone
          broadcast(session_id, { type: "session_deleted", session_id: session_id })
          unsubscribe_all(session_id)
          json_response(res, 200, { ok: true })
        else
          json_response(res, 404, { error: "Session not found" })
        end
      end

      # ── WebSocket ─────────────────────────────────────────────────────────────

      def websocket_upgrade?(req)
        req["Upgrade"]&.downcase == "websocket"
      end

      # Hijacks the TCP socket from WEBrick and hands it to websocket-driver.
      def handle_websocket(req, res)
        # Prevent WEBrick from closing the socket after this handler returns
        socket = req.instance_variable_get(:@socket)

        driver = WebSocket::Driver.rack(
          RackEnvAdapter.new(req, socket),
          max_length: 10 * 1024 * 1024
        )

        conn = WebSocketConnection.new(socket, driver)

        driver.on(:open)    { on_ws_open(conn) }
        driver.on(:message) { |event| on_ws_message(conn, event.data) }
        driver.on(:close)   { on_ws_close(conn) }
        driver.on(:error)   { |event| $stderr.puts "WS error: #{event.message}" }

        driver.start

        # Read loop — blocks this thread until the socket closes
        begin
          buf = String.new("", encoding: "BINARY")
          loop do
            chunk = socket.read_nonblock(4096, buf, exception: false)
            case chunk
            when :wait_readable
              IO.select([socket], nil, nil, 30)
            when nil
              break  # EOF
            else
              driver.parse(chunk)
            end
          end
        rescue IOError, Errno::ECONNRESET, Errno::EPIPE
          # Client disconnected
        ensure
          on_ws_close(conn)
          driver.close rescue nil
        end

        # Tell WEBrick not to send any response (we handled everything)
        res.instance_variable_set(:@header, {})
        res.status = -1
      rescue => e
        $stderr.puts "WebSocket handler error: #{e.class}: #{e.message}"
      end

      def on_ws_open(conn)
        # Client will send a "subscribe" message to bind to a session
      end

      def on_ws_message(conn, raw)
        msg = JSON.parse(raw)
        type = msg["type"]

        case type
        when "subscribe"
          session_id = msg["session_id"]
          if @registry.exist?(session_id)
            conn.session_id = session_id
            subscribe(session_id, conn)
            # Send current session state to the new subscriber
            sessions = @registry.list
            conn.send_json(type: "session_list", sessions: sessions)
            conn.send_json(type: "subscribed", session_id: session_id)
          else
            conn.send_json(type: "error", message: "Session not found: #{session_id}")
          end

        when "message"
          session_id = msg["session_id"] || conn.session_id
          handle_user_message(session_id, msg["content"].to_s, msg["images"] || [])

        when "confirmation"
          session_id = msg["session_id"] || conn.session_id
          deliver_confirmation(session_id, msg["id"], msg["result"])

        when "interrupt"
          session_id = msg["session_id"] || conn.session_id
          interrupt_session(session_id)

        when "list_sessions"
          conn.send_json(type: "session_list", sessions: @registry.list)

        when "ping"
          conn.send_json(type: "pong")

        else
          conn.send_json(type: "error", message: "Unknown message type: #{type}")
        end
      rescue JSON::ParserError => e
        conn.send_json(type: "error", message: "Invalid JSON: #{e.message}")
      rescue => e
        conn.send_json(type: "error", message: e.message)
      end

      def on_ws_close(conn)
        unsubscribe(conn)
      end

      # ── Session actions ───────────────────────────────────────────────────────

      def handle_user_message(session_id, content, images)
        return unless @registry.exist?(session_id)

        session = @registry.get(session_id)
        return if session[:status] == :running

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        return unless agent

        @registry.update(session_id, status: :running)

        thread = Thread.new do
          Dir.chdir(session[:working_dir]) do
            agent.run(content, images: images)
          end
          @registry.update(session_id, status: :idle, error: nil)

          # Persist session
          session_manager = Clacky::SessionManager.new
          session_manager.save(agent.to_session_data(status: :success))

          # Push updated session list to all connected clients
          broadcast_all(type: "session_list", sessions: @registry.list)
        rescue Clacky::AgentInterrupted
          @registry.update(session_id, status: :idle)
          broadcast(session_id, { type: "interrupted", session_id: session_id })
        rescue => e
          @registry.update(session_id, status: :error, error: e.message)
          broadcast(session_id, { type: "error", session_id: session_id, message: e.message })
        end

        @registry.with_session(session_id) { |s| s[:thread] = thread }
      end

      def deliver_confirmation(session_id, conf_id, result)
        ui = nil
        @registry.with_session(session_id) { |s| ui = s[:ui] }
        ui&.deliver_confirmation(conf_id, result)
      end

      def interrupt_session(session_id)
        @registry.with_session(session_id) do |s|
          s[:thread]&.raise(Clacky::AgentInterrupted, "Interrupted by user")
        end
      end

      # ── WebSocket subscription management ─────────────────────────────────────

      def subscribe(session_id, conn)
        @ws_mutex.synchronize do
          @ws_clients[session_id] ||= []
          @ws_clients[session_id] << conn
        end
      end

      def unsubscribe(conn)
        @ws_mutex.synchronize do
          @ws_clients.each_value { |list| list.delete(conn) }
        end
      end

      def unsubscribe_all(session_id)
        @ws_mutex.synchronize { @ws_clients.delete(session_id) }
      end

      # Broadcast an event to all clients subscribed to a session.
      def broadcast(session_id, event)
        clients = @ws_mutex.synchronize { (@ws_clients[session_id] || []).dup }
        clients.each { |conn| conn.send_json(event) rescue nil }
      end

      # Broadcast an event to every connected client.
      def broadcast_all(event)
        clients = @ws_mutex.synchronize { @ws_clients.values.flatten.uniq }
        clients.each { |conn| conn.send_json(event) rescue nil }
      end

      # ── Helpers ───────────────────────────────────────────────────────────────

      # Default working directory for new sessions.
      def default_working_dir
        File.expand_path("~/clacky_workspace")
      end

      # Create a session in the registry and wire up Agent + WebUIController.
      # Returns the new session_id.
      def build_session(name:, working_dir:)
        session_id = @registry.create(name: name, working_dir: working_dir)

        client = @client_factory.call
        agent  = Clacky::Agent.new(client, @agent_config.dup, working_dir: working_dir)

        broadcaster = method(:broadcast)
        ui = WebUIController.new(session_id, broadcaster)
        agent.instance_variable_set(:@ui, ui)

        @registry.with_session(session_id) do |s|
          s[:agent] = agent
          s[:ui]    = ui
        end

        session_id
      end

      def json_response(res, status, data)
        res.status       = status
        res.content_type = "application/json; charset=utf-8"
        res["Access-Control-Allow-Origin"] = "*"
        res.body = JSON.generate(data)
      end

      def parse_json_body(req)
        return {} if req.body.nil? || req.body.empty?

        JSON.parse(req.body)
      rescue JSON::ParserError
        {}
      end

      def not_found(res)
        res.status = 404
        res.body   = "Not Found"
      end

      # ── Inner classes ─────────────────────────────────────────────────────────

      # Thin adapter so websocket-driver (which expects a Rack env) can work with WEBrick.
      class RackEnvAdapter
        def initialize(req, socket)
          @req    = req
          @socket = socket
        end

        def env
          {
            "REQUEST_METHOD" => @req.request_method,
            "HTTP_HOST"      => @req["Host"],
            "REQUEST_URI"    => @req.request_uri.to_s,
            "HTTP_UPGRADE"   => @req["Upgrade"],
            "HTTP_CONNECTION"          => @req["Connection"],
            "HTTP_SEC_WEBSOCKET_KEY"   => @req["Sec-WebSocket-Key"],
            "HTTP_SEC_WEBSOCKET_VERSION" => @req["Sec-WebSocket-Version"],
            "rack.hijack"    => proc {},
            "rack.input"     => StringIO.new
          }
        end

        def write(data)
          @socket.write(data)
        end
      end

      # Wraps a raw TCP socket + WebSocket driver, providing a thread-safe send method.
      class WebSocketConnection
        attr_accessor :session_id

        def initialize(socket, driver)
          @socket     = socket
          @driver     = driver
          @send_mutex = Mutex.new
        end

        def send_json(data)
          @send_mutex.synchronize { @driver.text(JSON.generate(data)) }
        rescue => e
          $stderr.puts "WS send error: #{e.message}"
        end
      end
    end
  end
end
