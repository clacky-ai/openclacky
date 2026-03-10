# frozen_string_literal: true

require "fileutils"
require "logger"
require "json"

module Clacky
  module IM
    # Main IM bridge daemon.
    # Loads configuration, starts adapters, and routes messages to Agent instances.
    class Daemon
      LOG_FILE = File.join(Dir.home, ".clacky", "im-bridge", "logs", "bridge.log")
      PID_FILE = File.join(Dir.home, ".clacky", "im-bridge", "runtime", "bridge.pid")
      STATUS_FILE = File.join(Dir.home, ".clacky", "im-bridge", "runtime", "status.json")

      def initialize(config: nil)
        @config = config || Config.load
        @adapters = []
        @session_manager = nil
        @logger = nil
        @running = false
      end

      # Start the daemon
      # @return [void]
      def start
        setup_runtime_dirs
        setup_logger

        @logger.info "Starting IM bridge daemon..."
        @logger.info "Enabled platforms: #{@config.enabled_platforms.join(', ')}"

        # Build agent config
        agent_config = build_agent_config

        # Create session manager
        @session_manager = SessionManager.new(
          agent_config: agent_config,
          working_dir: @config.working_dir
        )

        # Build adapters
        @adapters = build_adapters

        if @adapters.empty?
          @logger.error "No adapters configured. Check ~/.clacky/im-bridge/config.env"
          write_status(running: false, error: "No adapters configured")
          return
        end

        @running = true
        write_status(running: true, platforms: @config.enabled_platforms)
        @logger.info "IM bridge daemon started (PID: #{Process.pid})"

        # Start adapter threads
        threads = @adapters.map do |adapter|
          Thread.new do
            @logger.info "Starting #{adapter.platform_id} adapter..."
            adapter.start do |event|
              route_message(adapter, event)
            end
          rescue => e
            @logger.error "#{adapter.platform_id} adapter crashed: #{e.message}"
            @logger.error e.backtrace.join("\n")
          end
        end

        # Wait for all adapter threads
        threads.each(&:join)
      end

      # Stop the daemon gracefully
      # @return [void]
      def stop
        @logger&.info "Stopping IM bridge daemon..."
        @running = false
        @adapters.each(&:stop)
        write_status(running: false)
        @logger&.info "IM bridge daemon stopped"
      end

      private

      # Route an inbound message to the appropriate Agent session
      # @param adapter [Base] Source adapter
      # @param event [Hash] Inbound message event
      # @return [void]
      def route_message(adapter, event)
        return unless event[:type] == :message

        platform = adapter.platform_id.to_sym
        chat_id = event[:chat_id]
        text = event[:text]

        @logger.info "[#{platform}:#{chat_id}] #{text[0..80]}"

        # Get or create agent session (UIController is created inside session_manager on first access)
        session = @session_manager.get_or_create(
          platform: platform,
          chat_id: chat_id,
          adapter: adapter
        )

        # Skip if agent is already running
        if session[:status] == :running
          @logger.warn "[#{platform}:#{chat_id}] Session busy, ignoring message"
          adapter.send_text(chat_id, "⏳ Still working on the previous task...")
          return
        end

        # Run agent in background thread
        @session_manager.update_status(platform: platform, chat_id: chat_id, status: :running)

        Thread.new do
          session[:agent].run(text)
        rescue Clacky::AgentInterrupted
          @logger.info "[#{platform}:#{chat_id}] Agent interrupted"
        rescue => e
          @logger.error "[#{platform}:#{chat_id}] Agent error: #{e.message}"
          @logger.error e.backtrace.join("\n")
          @session_manager.set_error(platform: platform, chat_id: chat_id, error: e)
          adapter.send_text(chat_id, "❌ Error: #{e.message}")
        ensure
          @session_manager.update_status(platform: platform, chat_id: chat_id, status: :idle)
        end
      end

      # Build agent configuration from bridge config
      # @return [AgentConfig]
      def build_agent_config
        agent_config = Clacky::AgentConfig.load
        agent_config.permission_mode = @config.permission_mode.to_sym
        agent_config
      end

      # Build adapter instances based on configuration
      # @return [Array<Base>] Adapter instances
      def build_adapters
        adapters = []

        @config.enabled_platforms.each do |platform|
          adapter = build_adapter(platform.to_sym)
          if adapter
            adapters << adapter
          else
            @logger.warn "Unknown platform: #{platform}"
          end
        end

        adapters
      end

      # Build a single adapter
      # @param platform [Symbol] Platform identifier
      # @return [Base, nil] Adapter instance
      def build_adapter(platform)
        klass = Adapters.find(platform)
        unless klass
          @logger.warn "Adapter for #{platform} is not yet implemented"
          return nil
        end

        config = @config.platform_config(platform)
        adapter = klass.new(config)
        errors = adapter.validate_config(config)
        if errors.any?
          @logger.error "#{platform} config errors: #{errors.join(', ')}"
          return nil
        end

        adapter
      end

      # Setup runtime directories
      # @return [void]
      def setup_runtime_dirs
        FileUtils.mkdir_p(File.dirname(LOG_FILE))
        FileUtils.mkdir_p(File.dirname(PID_FILE))
        File.write(PID_FILE, Process.pid.to_s)
      end

      # Setup logger with secret redaction
      # @return [void]
      def setup_logger
        @logger = ::Logger.new(LOG_FILE, 5, 10 * 1024 * 1024) # 5 files, 10MB each
        @logger.formatter = proc do |severity, datetime, progname, msg|
          "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{redact_secrets(msg)}\n"
        end
      end

      # Write daemon status to file
      # @param status [Hash] Status data
      # @return [void]
      def write_status(status)
        FileUtils.mkdir_p(File.dirname(STATUS_FILE))
        data = {
          pid: Process.pid,
          started_at: Time.now.iso8601
        }.merge(status)

        tmp = "#{STATUS_FILE}.tmp"
        File.write(tmp, JSON.generate(data))
        File.rename(tmp, STATUS_FILE)
      rescue => e
        warn "Failed to write status: #{e.message}"
      end

      # Redact sensitive values from log messages
      # @param message [String] Log message
      # @return [String] Message with secrets redacted
      def redact_secrets(message)
        message.to_s
          .gsub(/app_secret['":\s]+([^\s,'"}{]+)/) { "app_secret: ****#{$1[-4..]}" }
          .gsub(/api_key['":\s]+([^\s,'"}{]+)/) { "api_key: ****#{$1[-4..]}" }
          .gsub(/Bearer [A-Za-z0-9._-]{20,}/) { "Bearer ****" }
      end
    end
  end
end
