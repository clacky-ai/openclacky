# frozen_string_literal: true

require "securerandom"

module Clacky
  module IM
    # Session manager for IM bridge.
    # Maps (platform, chat_id) to Agent instances so each chat has its own agent.
    #
    # Thread-safe: shared across adapter threads, all public methods protected by a Mutex.
    class SessionManager
      SESSION_TIMEOUT = 24 * 60 * 60 # 24 hours

      def initialize(agent_config:, working_dir:)
        @agent_config = agent_config
        @working_dir = working_dir
        @sessions = {}
        @mutex = Mutex.new
      end

      # Get or create a session for a chat.
      # @param platform [Symbol] Platform identifier (:feishu, :wecom, etc.)
      # @param chat_id [String] Chat identifier
      # @param adapter [Base] Platform adapter instance for this chat
      # @return [Hash] Session hash with :agent, :status
      def get_or_create(platform:, chat_id:, adapter:)
        session_key = "#{platform}:#{chat_id}"

        @mutex.synchronize do
          cleanup_stale_sessions
          @sessions[session_key] ||= create_session(session_key, platform, chat_id, adapter)
          @sessions[session_key][:accessed_at] = Time.now
          @sessions[session_key]
        end
      end

      # Update session status
      # @param platform [Symbol] Platform identifier
      # @param chat_id [String] Chat identifier
      # @param status [Symbol] New status (:idle, :running, :error)
      # @return [void]
      def update_status(platform:, chat_id:, status:)
        session_key = "#{platform}:#{chat_id}"

        @mutex.synchronize do
          session = @sessions[session_key]
          session[:status] = status if session
        end
      end

      # Set error for a session
      # @param platform [Symbol] Platform identifier
      # @param chat_id [String] Chat identifier
      # @param error [Exception, String] Error object or message
      # @return [void]
      def set_error(platform:, chat_id:, error:)
        session_key = "#{platform}:#{chat_id}"

        @mutex.synchronize do
          session = @sessions[session_key]
          return unless session

          session[:status] = :error
          session[:error] = error.is_a?(Exception) ? error.message : error.to_s
        end
      end

      private

      # Create a new session
      # @param session_key [String] Unique session key
      # @param platform [Symbol] Platform identifier
      # @param chat_id [String] Chat identifier
      # @param adapter [Base] Platform adapter instance
      # @return [Hash] New session hash
      def create_session(session_key, platform, chat_id, adapter)
        ui = UIController.new(platform: platform, chat_id: chat_id, adapter: adapter)

        client = Clacky::Client.new(
          @agent_config.api_key,
          base_url: @agent_config.base_url,
          anthropic_format: @agent_config.anthropic_format?
        )

        agent = Clacky::Agent.new(
          client,
          @agent_config,
          working_dir: @working_dir,
          ui: ui,
          profile: "general"
        )

        {
          session_key: session_key,
          agent: agent,
          status: :idle,
          error: nil,
          accessed_at: Time.now
        }
      end

      # Remove idle sessions not accessed within SESSION_TIMEOUT.
      # Called inside @mutex, no need to synchronize again.
      def cleanup_stale_sessions
        cutoff = Time.now - SESSION_TIMEOUT
        @sessions.delete_if { |_, s| s[:status] == :idle && s[:accessed_at] < cutoff }
      end
    end
  end
end
