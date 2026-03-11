# frozen_string_literal: true

module Clacky
  module IM
    # Main IM bridge daemon.
    # Loads configuration, starts adapters, and routes messages to Agent instances.
    class Daemon
      def initialize(config: nil)
        @config = config || Config.load
        @adapters = []
        @session_manager = nil
      end

      # Start the daemon
      # @return [void]
      def start
        Clacky::Logger.info "Starting IM bridge..."
        Clacky::Logger.info "Enabled platforms: #{@config.enabled_platforms.join(', ')}"

        agent_config = build_agent_config

        @session_manager = SessionManager.new(
          agent_config: agent_config,
          working_dir: @config.working_dir
        )

        @adapters = build_adapters

        if @adapters.empty?
          Clacky::Logger.error "No IM adapters configured. Check ~/.clacky/im-bridge/config.env"
          return
        end

        Clacky::Logger.info "IM bridge started"

        threads = @adapters.map do |adapter|
          Thread.new do
            Clacky::Logger.info "Starting #{adapter.platform_id} adapter..."
            adapter.start do |event|
              route_message(adapter, event)
            end
          rescue => e
            Clacky::Logger.error "#{adapter.platform_id} adapter crashed", error: e
          end
        end

        threads.each(&:join)
      end

      # Stop the daemon gracefully
      # @return [void]
      def stop
        Clacky::Logger.info "Stopping IM bridge..."
        @adapters.each(&:stop)
        Clacky::Logger.info "IM bridge stopped"
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

        Clacky::Logger.info "[#{platform}:#{chat_id}] #{text[0..80]}"

        session = @session_manager.get_or_create(
          platform: platform,
          chat_id: chat_id,
          adapter: adapter
        )

        if session[:status] == :running
          Clacky::Logger.warn "[#{platform}:#{chat_id}] Session busy, ignoring message"
          adapter.send_text(chat_id, "⏳ Still working on the previous task...")
          return
        end

        @session_manager.update_status(platform: platform, chat_id: chat_id, status: :running)

        Thread.new do
          session[:agent].run(text)
        rescue Clacky::AgentInterrupted
          Clacky::Logger.info "[#{platform}:#{chat_id}] Agent interrupted"
        rescue => e
          Clacky::Logger.error "[#{platform}:#{chat_id}] Agent error", error: e
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
          adapters << adapter if adapter
        end

        adapters
      end

      # Build a single adapter
      # @param platform [Symbol] Platform identifier
      # @return [Base, nil] Adapter instance
      def build_adapter(platform)
        klass = Adapters.find(platform)
        unless klass
          Clacky::Logger.warn "Adapter for #{platform} is not yet implemented"
          return nil
        end

        config = @config.platform_config(platform)
        adapter = klass.new(config)
        errors = adapter.validate_config(config)
        if errors.any?
          Clacky::Logger.error "#{platform} config errors: #{errors.join(', ')}"
          return nil
        end

        adapter
      end
    end
  end
end
