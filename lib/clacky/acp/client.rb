# frozen_string_literal: true

require "timeout"
require_relative "../thread_registry"

module Clacky
  module Acp
    # Concurrent JSON-RPC client for ACP v1 transports.
    class Client
      class Error < StandardError; end
      class TransportError < Error; end
      class ProtocolError < Error
        attr_reader :code, :method, :remote_message, :data

        def initialize(message = nil, code: nil, method: nil,
                       remote_message: nil, data: nil)
          @code = code
          @method = method && method.to_s
          @remote_message = remote_message && remote_message.to_s
          @data = data
          super(message)
        end
      end
      class RequestTimeout < Error; end

      PROTOCOL_VERSION = 1
      INITIALIZE_TIMEOUT = 15
      MAX_REVERSE_REQUESTS = 16
      MAX_RETIRED_REQUEST_IDS = 128
      NotificationSubscription = Struct.new(:method, :session_id, :handler)

      attr_reader :initialize_result

      def initialize(transport:)
        @transport = transport
        @next_id = 0
        @pending = {}
        @retired_request_ids = {}
        @retired_request_order = []
        @notification_handlers = Hash.new { |hash, key| hash[key] = [] }
        @request_handlers = {}
        @active_reverse_requests = 0
        @lock = Mutex.new
        @started = false
        @initialize_result = {}

        @transport.on_message { |message| handle_message(message) }
      end

      def start(client_info:, capabilities: {}, timeout: INITIALIZE_TIMEOUT)
        return self if initialized?

        @transport.start
        result = raw_request(
          "initialize",
          {
            protocolVersion: PROTOCOL_VERSION,
            clientCapabilities: capabilities,
            clientInfo: client_info
          },
          timeout: timeout
        )
        unless result["protocolVersion"].to_i == PROTOCOL_VERSION
          raise ProtocolError,
                "ACP initialize returned unsupported protocol version #{result['protocolVersion'].inspect}"
        end

        @lock.synchronize do
          @initialize_result = result
          @started = true
        end
        self
      rescue StandardError
        @transport.stop rescue nil
        raise
      end

      def stop
        @lock.synchronize { @started = false }
        fail_pending("ACP client stopped")
        @transport.stop
        self
      rescue StandardError
        self
      end

      def initialized?
        @lock.synchronize { @started }
      end

      def alive?
        initialized? && @transport.alive?
      end

      def agent_info
        @lock.synchronize { deep_copy(@initialize_result["agentInfo"] || {}) }
      end

      def agent_capabilities
        @lock.synchronize { deep_copy(@initialize_result["agentCapabilities"] || {}) }
      end

      def auth_methods
        @lock.synchronize { deep_copy(@initialize_result["authMethods"] || []) }
      end

      def request(method, params = {}, timeout: nil, before_send: nil,
                  on_sent: nil, on_send_error: nil)
        ensure_started!
        raw_request(
          method,
          params,
          timeout: timeout,
          before_send: before_send,
          on_sent: on_sent,
          on_send_error: on_send_error
        )
      end

      def notify(method, params = {})
        ensure_started!
        @transport.send_message(jsonrpc: "2.0", method: method, params: params)
        nil
      rescue StandardError => e
        raise_transport_error(e)
      end

      def on_notification(method, session_id: nil, &block)
        raise ArgumentError, "notification handler block required" unless block

        subscription = NotificationSubscription.new(
          method.to_s,
          session_id && session_id.to_s,
          block
        )
        @lock.synchronize do
          @notification_handlers[method.to_s] << subscription
        end
        subscription
      end

      def remove_notification_handler(subscription)
        return false unless subscription.is_a?(NotificationSubscription)

        @lock.synchronize do
          handlers = @notification_handlers[subscription.method]
          !!handlers.delete(subscription)
        end
      end

      def on_request(method, &block)
        raise ArgumentError, "request handler block required" unless block

        @lock.synchronize { @request_handlers[method.to_s] = block }
        self
      end

      def pending_request_count
        @lock.synchronize { @pending.length }
      end

      def stderr_tail(bytes: 4096)
        @transport.stderr_tail(bytes: bytes)
      end

      private def raw_request(method, params, timeout:, before_send: nil,
                              on_sent: nil, on_send_error: nil)
        queue = Queue.new
        id = @lock.synchronize do
          @next_id += 1
          @pending[@next_id] = { queue: queue, method: method.to_s }
          @next_id
        end

        begin
          before_send&.call
          @transport.send_message(
            jsonrpc: "2.0", id: id, method: method.to_s, params: params
          )
          on_sent&.call
        rescue StandardError => e
          on_send_error&.call
          @lock.synchronize { @pending.delete(id) }
          raise_transport_error(e)
        end

        response = if timeout.nil?
                     queue.pop
                   else
                     Timeout.timeout(timeout) { queue.pop }
                   end
        raise response[:exception] if response.is_a?(Hash) && response[:exception]

        if (remote_error = response["error"])
          code = remote_error["code"]
          raise ProtocolError.new(
            "ACP request '#{method}' failed (code #{code})",
            code: code,
            method: method,
            remote_message: remote_error["message"],
            data: deep_copy(remote_error["data"])
          )
        end

        response["result"]
      rescue Timeout::Error
        retire_request_id(id) if id
        raise RequestTimeout, "ACP request '#{method}' timed out"
      ensure
        @lock.synchronize { @pending.delete(id) } if id
      end

      private def handle_message(message)
        unless message.is_a?(Hash)
          return protocol_failure("ACP emitted a non-object message")
        end

        if message["__transport_closed__"]
          @lock.synchronize { @started = false }
          fail_pending(message["error"].to_s.empty? ? "ACP transport closed" : message["error"])
          return
        end

        if message["__transport_error__"]
          fail_pending(message["error"].to_s.empty? ? "ACP transport failed" : message["error"])
          return
        end

        unless message["jsonrpc"] == "2.0"
          return protocol_failure("ACP emitted a message without JSON-RPC 2.0")
        end

        if message.key?("id") && !message.key?("method")
          has_result = message.key?("result")
          has_error = message.key?("error")
          unless has_result ^ has_error
            return protocol_failure("invalid ACP response: expected exactly one of result or error")
          end
          if has_error && !message["error"].is_a?(Hash)
            return protocol_failure("invalid ACP response: error must be an object")
          end

          pending, retired = @lock.synchronize do
            entry = @pending.delete(message["id"])
            was_retired = @retired_request_ids.delete(message["id"])
            @retired_request_order.delete(message["id"]) if was_retired
            [entry, was_retired]
          end
          if pending
            pending[:queue] << message
          elsif !retired
            protocol_failure("ACP emitted a response for an unknown request id")
          end
          return
        end

        if message.key?("id") && message["method"]
          unless message["method"].is_a?(String) &&
                 (message["params"].nil? || message["params"].is_a?(Hash))
            return protocol_failure("ACP emitted an invalid reverse request")
          end
          dispatch_reverse_request(message)
          return
        end

        if message["method"]
          unless message["method"].is_a?(String) &&
                 (message["params"].nil? || message["params"].is_a?(Hash))
            return protocol_failure("ACP emitted an invalid notification")
          end
          return dispatch_notification(message)
        end

        protocol_failure("ACP emitted an unrecognized JSON-RPC message")
      end

      private def dispatch_notification(message)
        method = message["method"].to_s
        params = message["params"] || {}
        session_id = params["sessionId"] || params["session_id"]
        handlers = @lock.synchronize { Array(@notification_handlers[method]).dup }

        handlers.each do |subscription|
          expected_session_id = subscription.session_id
          next if expected_session_id && expected_session_id != session_id.to_s

          subscription.handler.call(params)
        rescue StandardError => e
          Clacky::Logger.warn(
            "[ACP] notification handler failed",
            method: method,
            error: e.class.name
          ) if defined?(Clacky::Logger)
        end
      end

      private def dispatch_reverse_request(message)
        id = message["id"]
        method = message["method"].to_s
        params = message["params"] || {}
        handler = @lock.synchronize { @request_handlers[method] }
        reserved = false
        spawned = false

        unless handler
          @transport.send_message(
            jsonrpc: "2.0",
            id: id,
            error: { code: -32_601, message: "Method not found" }
          )
          return
        end

        unless reserve_reverse_request_slot
          @transport.send_message(
            jsonrpc: "2.0",
            id: id,
            error: { code: -32_603, message: "Too many active ACP requests" }
          )
          return
        end
        reserved = true

        spawn_handler_thread(method) do
          begin
            result = handler.call(params) || {}
            @transport.send_message(jsonrpc: "2.0", id: id, result: result)
          rescue StandardError => e
            Clacky::Logger.warn(
              "[ACP] request handler failed",
              method: method,
              error: e.class.name
            ) if defined?(Clacky::Logger)
            @transport.send_message(
              jsonrpc: "2.0",
              id: id,
              error: { code: -32_603, message: "Internal error" }
            )
          ensure
            release_reverse_request_slot
          end
        end
        spawned = true
      rescue StandardError => e
        release_reverse_request_slot if reserved && !spawned
        Clacky::Logger.warn(
          "[ACP] failed to dispatch reverse request",
          method: method,
          error: e.class.name
        ) if defined?(Clacky::Logger)
      end

      private def reserve_reverse_request_slot
        @lock.synchronize do
          next false if @active_reverse_requests >= MAX_REVERSE_REQUESTS

          @active_reverse_requests += 1
          true
        end
      end

      private def release_reverse_request_slot
        @lock.synchronize do
          @active_reverse_requests -= 1 if @active_reverse_requests.positive?
        end
      end

      private def spawn_handler_thread(method, &block)
        Clacky::ThreadRegistry.spawn(
          name: "acp-request:#{method}", daemon: true, &block
        )
      end

      private def fail_pending(message)
        fail_pending_with(TransportError.new(message.to_s))
      end

      private def fail_pending_with(exception)
        pending = @lock.synchronize do
          values = @pending.values
          @pending.clear
          values
        end
        pending.each { |entry| entry[:queue] << { exception: exception } }
      end

      private def protocol_failure(message)
        @lock.synchronize { @started = false }
        fail_pending_with(ProtocolError.new(message))
        nil
      end

      private def retire_request_id(id)
        @lock.synchronize do
          return if @retired_request_ids.key?(id)

          @retired_request_ids[id] = true
          @retired_request_order << id
          while @retired_request_order.length > MAX_RETIRED_REQUEST_IDS
            expired = @retired_request_order.shift
            @retired_request_ids.delete(expired)
          end
        end
      end

      private def ensure_started!
        raise TransportError, "ACP client is not initialized" unless initialized?
        raise TransportError, "ACP transport is not running" unless @transport.alive?
      end

      private def raise_transport_error(error)
        raise error if error.is_a?(Error)

        raise TransportError, "ACP transport error: #{error.class}: #{error.message}"
      end

      private def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), copy|
            copy[deep_copy(key)] = deep_copy(item)
          end
        when Array
          value.map { |item| deep_copy(item) }
        else
          begin
            value.dup
          rescue TypeError
            value
          end
        end
      end
    end
  end
end
