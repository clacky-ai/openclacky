# frozen_string_literal: true

require_relative "channel_ui_controller"

module Clacky
  module Channel
    # ChannelManager starts and supervises IM platform adapter threads.
    # When an inbound message arrives it:
    #   1. Resolves (or auto-creates) a Session bound to this IM identity
    #   2. Retrieves the WebUIController for that session
    #   3. Creates a ChannelUIController and subscribes it to the WebUIController
    #   4. Runs the agent task via run_agent_task (same as HttpServer)
    #   5. Unsubscribes the ChannelUIController when the task finishes
    #
    # Thread model: each adapter runs two long-lived threads (read loop + ping).
    # ChannelManager itself is non-blocking — call #start from HttpServer after
    # the WEBrick server has started.
    #
    # Session binding: the first message from an IM identity automatically creates
    # a new session and binds it. Users can use /bind <session_id> to switch to an
    # existing WebUI session instead. Bindings are stored in the session registry as
    # :channel_keys => Set of channel key strings.
    # WebUI sessions are persisted by HttpServer — channel adds no extra persistence.
    class ChannelManager
      # @param session_registry   [Clacky::Server::SessionRegistry]
      # @param session_builder    [Proc] (name:, working_dir:) => session_id — from HttpServer
      # @param run_agent_task     [Proc] (session_id, agent, &task) — from HttpServer
      # @param interrupt_session  [Proc] (session_id) — from HttpServer
      # @param channel_config     [Clacky::ChannelConfig]
      # @param binding_mode       [:chat | :chat_user | :user] how to map IM identities to sessions.
      #   :chat (default)      — one session per chat (all users in a chat share it).
      #   :chat_user           — one session per (chat, user) pair.
      #   :user                — one session per user (merges all chats).
      def initialize(session_registry:, session_builder:, run_agent_task:, interrupt_session:, channel_config:, binding_mode: :chat)
        @registry          = session_registry
        @session_builder   = session_builder
        @run_agent_task    = run_agent_task
        @interrupt_session = interrupt_session
        @channel_config    = channel_config
        @binding_mode      = binding_mode
        @adapters          = []
        @adapter_threads   = []
        @running           = false
        @mutex             = Mutex.new
        @session_counters  = Hash.new(0)
      end

      # Start all enabled adapters in background threads. Non-blocking.
      def start
        enabled_platforms = @channel_config.enabled_platforms
        if enabled_platforms.empty?
          Clacky::Logger.info("[ChannelManager] No channels configured — skipping")
          return
        end

        Clacky::Logger.info("[ChannelManager] Starting channels: #{enabled_platforms.join(", ")}")
        @running = true

        restore_channel_bindings

        enabled_platforms.each { |platform| start_adapter(platform) }
      end

      # Stop all adapters gracefully.
      def stop
        @running = false
        @mutex.synchronize do
          @adapters.each { |adapter| safe_stop_adapter(adapter) }
          @adapters.clear
        end
        @adapter_threads.each { |t| t.join(1) }
        @adapter_threads.clear
      end

      # @return [Array<Symbol>] platforms currently running
      def running_platforms
        @mutex.synchronize { @adapters.map(&:platform_id) }
      end

      # Proactively send a message to a user on the given platform.
      #
      # For Weixin (iLink protocol) a context_token is required for every outbound
      # message.  This method looks up the most-recently cached token for user_id.

      # Return the currently-live adapter for a given platform, or nil if none running.
      # Thread-safe — acquires @mutex to read from @adapters.
      # @param platform [Symbol, String]
      # @return [Object, nil]
      def adapter_for(platform)
        platform = platform.to_sym
        @mutex.synchronize { @adapters.find { |a| a.platform_id == platform } }
      end

      # If no token is found the message cannot be delivered and nil is returned.
      #
      # For Feishu and WeCom the chat_id / user_id is sufficient — no token needed.
      #
      # @param platform [Symbol, String] e.g. :weixin, :feishu, :wecom
      # @param user_id  [String]         IM user identifier
      # @param message  [String]         plain-text (or markdown) message to send
      # @return [Hash, nil]  adapter result hash, or nil on failure
      def send_to_user(platform, user_id, message)
        platform = platform.to_sym
        adapter  = adapter_for(platform)

        unless adapter
          Clacky::Logger.warn("[ChannelManager] send_to_user: no running adapter for :#{platform}")
          return nil
        end

        Clacky::Logger.info("[ChannelManager] send_to_user :#{platform} → #{user_id}")
        adapter.send_text(user_id, message)
      rescue StandardError => e
        Clacky::Logger.error("[ChannelManager] send_to_user failed: #{e.message}")
        nil
      end

      # Return a list of known user IDs for the given platform.
      # Collected from every message that has been processed since the server started.
      # Weixin stores context_tokens keyed by user_id; feishu/wecom track chat_ids
      # via the session binding table in the registry.
      #
      # @param platform [Symbol, String]
      # @return [Array<String>]
      def known_users(platform)
        platform = platform.to_sym
        adapter  = adapter_for(platform)
        return [] unless adapter

        # Weixin adapter exposes @context_tokens whose keys are user_ids
        if adapter.respond_to?(:context_token_user_ids)
          return adapter.context_token_user_ids
        end

        # Fallback: scan session registry for channel_keys matching this platform.
        # Key formats depend on binding_mode:
        #   :user       → "platform:user:USER_ID"
        #   :chat       → "platform:chat:CHAT_ID"
        #   :chat_user  → "platform:chat:CHAT_ID:user:USER_ID"
        #
        # For send_text we need the chat_id (Feishu/WeCom use chat_id as the
        # receive_id for outbound messages), so we extract the chat portion.
        prefix = "#{platform}:"
        ids = []
        @registry.list.each do |summary|
          @registry.with_session(summary[:id]) do |s|
            (s[:channel_keys] || []).each do |key|
              next unless key.start_with?(prefix)

              remainder = key.sub(prefix, "") # e.g. "chat:OC_ID:user:OU_ID" or "user:UID" or "chat:CID"
              ids << extract_chat_id(remainder)
            end
          end
        end
        ids.compact.uniq
      end

      # Hot-reload a single platform adapter with updated config.
      # Stops the existing adapter (if running), then starts a new one if enabled.
      # @param platform [Symbol]
      # @param config [Clacky::ChannelConfig]
      def reload_platform(platform, config)
        # Stop existing adapter for this platform
        @mutex.synchronize do
          existing = @adapters.find { |a| a.platform_id == platform }
          if existing
            safe_stop_adapter(existing)
            @adapters.delete(existing)
          end
        end

        # Start new adapter if enabled
        if config.enabled?(platform)
          @channel_config = config
          start_adapter(platform)
          Clacky::Logger.info("[ChannelManager] :#{platform} adapter reloaded")
        else
          Clacky::Logger.info("[ChannelManager] :#{platform} disabled — adapter not started")
        end
      end


      def start_adapter(platform)
        klass = Adapters.find(platform)
        unless klass
          Clacky::Logger.warn("[ChannelManager] No adapter registered for :#{platform} — skipping")
          return
        end

        raw_config = @channel_config.platform_config(platform)
        Clacky::Logger.info("[ChannelManager] Initializing :#{platform} adapter")
        adapter = klass.new(raw_config)

        errors = adapter.validate_config(raw_config)
        if errors.any?
          Clacky::Logger.warn("[ChannelManager] Config errors for :#{platform}: #{errors.join(", ")}")
          return
        end

        @mutex.synchronize { @adapters << adapter }
        Clacky::Logger.info("[ChannelManager] :#{platform} adapter ready, starting thread")

        thread = Thread.new do
          Thread.current.name = "channel-#{platform}"
          adapter_loop(adapter)
        end

        @adapter_threads << thread
      end

      def adapter_loop(adapter)
        Clacky::Logger.info("[ChannelManager] :#{adapter.platform_id} adapter loop started")
        adapter.start do |event|
          summary = event[:text].to_s.lines.first.to_s.strip[0, 80]
          summary = "[image]" if summary.empty? && !event[:files].to_a.empty?
          Clacky::Logger.info("[ChannelManager] :#{adapter.platform_id} message from #{event[:user_id]} in #{event[:chat_id]}: #{summary}")
          route_message(adapter, event)
        rescue StandardError => e
          Clacky::Logger.warn("[ChannelManager] Error routing :#{adapter.platform_id} message: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
          adapter.send_text(event[:chat_id], "Error: #{e.message}")
        end
      rescue StandardError => e
        Clacky::Logger.warn("[ChannelManager] :#{adapter.platform_id} adapter crashed: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
        if @running
          Clacky::Logger.info("[ChannelManager] :#{adapter.platform_id} restarting in 5s...")
          sleep 5
          retry
        end
      end

      def route_message(adapter, event)
        if event[:observe_only]
          return
        end

        if event[:unsupported]
          adapter.send_text(event[:chat_id], "Sorry, this message type is not supported.")
          return
        end

        text  = event[:text]&.strip
        files = event[:files] || []
        return if (text.nil? || text.empty?) && files.empty?

        # Handle built-in commands
        if text&.match?(KNOWN_COMMAND) || text&.match?(/\A([\?h]|help)\z/i)
          handle_command(adapter, event, text)
          return
        end

        session_id = resolve_session(event)
        if session_id
          bind_key_to_session(channel_key(event), session_id)
        else
          session_id = auto_create_session(adapter, event)
        end

        session = @registry.get(session_id)
        unless session
          Clacky::Logger.warn("[ChannelManager] Session #{session_id[0, 8]} not found in registry after create")
          adapter.send_text(event[:chat_id], "Failed to initialize session. Please try again.")
          return
        end

        sub_count = web_ui_for_session_diag(session_id)
        Clacky::Logger.info("[ChannelManager] Routing to session #{session_id[0, 8]} (status=#{session[:status]}, text=#{text.inspect}, channel_subs=#{sub_count})")

        # If session is running, interrupt it AND wait for the old thread to
        # actually unwind before starting a new task. Without the join, two
        # threads briefly race on the same agent/history and the old thread
        # can land an assistant.tool_calls message that the new thread then
        # ships to the LLM with no matching tool result — DeepSeek (strict
        # OpenAI-compat) rejects this with HTTP 400 "insufficient tool
        # messages following tool_calls message". CLI already waits via
        # join(2); we do the same here so all entrypoints behave alike.
        if session[:status] == :running
          Clacky::Logger.info("[ChannelManager] Session busy, interrupting previous task")
          old_thread = nil
          @registry.with_session(session_id) { |s| old_thread = s[:thread] }
          @interrupt_session.call(session_id)
          if old_thread&.alive?
            old_thread.join(2)
            if old_thread.alive?
              Clacky::Logger.warn("[ChannelManager] previous task did not finish within 2s; continuing anyway (watchdog will escalate)")
            end
          end
        end

        agent  = session[:agent]
        web_ui = session[:ui]

        # Set channel info on the agent so session context includes platform/sender.
        agent.channel_info = extract_channel_info(event) if agent.respond_to?(:channel_info=)

        # Re-attach channel UI if it was dropped (session was evicted from memory and rebuilt by ensure).
        ensure_channel_ui_subscribed(session_id, event)

        # Update reply context so responses thread under the current message.
        channel_ui_for_session(session_id)&.update_message_context(event)

        # Sync the inbound message to WebUI so it shows up in the browser session.
        # source: :channel prevents the message from being echoed back to the IM channel.
        web_ui&.show_user_message(text, source: :channel) unless text.nil? || text.empty?

        # Prepend buffered group history so the agent knows what was discussed
        # before it was @-mentioned. Buffer is cleared atomically on take.
        # WebUI always receives the raw user text — context is agent-only.
        prompt = build_prompt_with_context(event, text)

        # Start typing keepalive BEFORE sending any message.
        # sendmessage cancels the typing indicator in WeChat protocol,
        # so keepalive must be running when "Thinking..." is sent so it
        # immediately re-asserts the typing state after that message.
        chat_id       = event[:chat_id]
        context_token = event[:context_token]
        adapter.start_typing_keepalive(chat_id, context_token) if adapter.respond_to?(:start_typing_keepalive)

        # Acknowledge to the IM channel only — WebUI doesn't need a "Thinking..." noise.
        adapter.send_text(chat_id, "Thinking...")

        @run_agent_task.call(session_id, agent) do
          begin
            Clacky::Logger.info("[ChannelManager] agent.run START session=#{session_id[0, 8]} text=#{text.inspect}")
            agent.run(prompt, files: files, display_text: text)
            Clacky::Logger.info("[ChannelManager] agent.run END   session=#{session_id[0, 8]} text=#{text.inspect}")
          rescue StandardError => e
            Clacky::Logger.error("[ChannelManager] agent.run RAISED session=#{session_id[0, 8]} #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}")
            raise
          ensure
            adapter.stop_typing_keepalive(chat_id) if adapter.respond_to?(:stop_typing_keepalive)
          end
        end
      end

      def handle_command(adapter, event, text)
        chat_id = event[:chat_id]
        key     = channel_key(event)

        case text
        when /\A([\?h]|help)\z/i
          adapter.send_text(chat_id, COMMAND_HELP)

        when "/new", "/clear"
          session_id = auto_create_session(adapter, event)
          adapter.send_text(chat_id, "New session `#{session_id[0, 8]}` created.") if session_id

        when /\A\/model\b/i
          handle_model_command(adapter, event, text)

        when /\A\/skills\b/i
          handle_skills_command(adapter, event)

        when /\A\/bind\s+(\S+)\z/i
          arg = Regexp.last_match(1)
          # Support numeric index from /list (1-based)
          session_id = if arg =~ /\A\d+\z/
            recent = @registry.list.first(5)
            idx = arg.to_i - 1
            recent[idx]&.fetch(:id, nil)
          else
            arg
          end
          unless session_id && @registry.get(session_id)
            adapter.send_text(chat_id, "Session not found. Use /list to see available sessions.")
            return
          end

          # Detach channel_ui from the old session's web_ui, reattach to the new one.
          old_session_id = resolve_session(event)
          channel_ui = old_session_id ? channel_ui_for_session(old_session_id) : nil

          if channel_ui
            @registry.with_session(old_session_id) { |s| s[:ui]&.unsubscribe_channel(channel_ui); s.delete(:channel_ui) }
          else
            channel_ui = ChannelUIController.new(event, -> { adapter_for(event[:platform]) })
          end

          bind_key_to_session(key, session_id)
          @registry.with_session(session_id) do |s|
            s[:ui]&.subscribe_channel(channel_ui)
            s[:channel_ui] = channel_ui
          end

          Clacky::Logger.info("[ChannelManager] Bound #{key} -> session #{session_id[0, 8]}")
          adapter.send_text(chat_id, "Bound to session `#{session_id[0, 8]}`.")

        when "/stop"
          session_id = resolve_session(event)
          unless session_id
            adapter.send_text(chat_id, "No session bound.")
            return
          end
          @interrupt_session.call(session_id)
          adapter.send_text(chat_id, "Task interrupted.")

        when "/unbind"
          unbound = false
          @registry.list.each do |summary|
            @registry.with_session(summary[:id]) do |s|
              unbound = true if s[:channel_keys]&.delete(key)
            end
          end
          adapter.send_text(chat_id, unbound ? "Unbound." : "No binding found.")

        when "/status"
          session_id = resolve_session(event)
          if session_id
            session = @registry.get(session_id)
            model = session&.dig(:agent)&.current_model_info
            model_name = model&.dig(:model) || "unknown"
            adapter.send_text(chat_id, "Bound to session `#{session_id[0, 8]}` (status: #{session&.dig(:status) || "unknown"}, model: #{model_name})")
          else
            adapter.send_text(chat_id, "No session bound yet. Send any message to auto-create one.")
          end

        when "/list"
          list_sessions(adapter, chat_id)

        else
          adapter.send_text(chat_id, "Unknown command. Type ? for help.")
        end
      end

      KNOWN_COMMAND = %r{\A/(new|clear|model|skills|bind|stop|unbind|status|list)\b}i

      COMMAND_HELP = <<~HELP.strip
        Commands:
          ? / h / help - show this help
          /new / /clear - start a new session
          /model - show current model, cards & quick-switch list
          /model <n> - switch card by number
          /model s<n> - quick-switch model under current card
          /model off - reset to card default
          /skills - list available skills
          /<skill> <args> - invoke a skill directly
          /bind <n|session_id> - switch to a session (use /list to see numbers)
          /unbind - remove binding
          /stop - interrupt current task
          /status - show current binding
          /list - show recent sessions
      HELP

      def handle_model_command(adapter, event, text)
        chat_id   = event[:chat_id]
        session_id = resolve_session(event)

        unless session_id
          adapter.send_text(chat_id, "No session bound. Send any message to auto-create one first.")
          return
        end

        session = @registry.get(session_id)
        agent = session&.dig(:agent)
        unless agent
          adapter.send_text(chat_id, "Session not ready.")
          return
        end

        arg = text.sub(/\A\/model\s*/i, "").strip

        if arg.empty?
          show_model_list(adapter, chat_id, agent)
        elsif arg =~ /\A\d+\z/
          switch_model_by_index(adapter, chat_id, agent, arg.to_i - 1)
        elsif arg =~ /\As(\d+)\z/i
          switch_quick_by_index(adapter, chat_id, agent, $1.to_i - 1)
        else
          switch_model_by_name(adapter, chat_id, agent, arg)
        end
      end

      def show_model_list(adapter, chat_id, agent)
        info = agent.current_model_info
        current = info&.dig(:model) || "unknown"
        sub     = info&.dig(:sub_model)
        card    = info&.dig(:card_model)

        header  = "Current: #{current}"
        header += " (#{card})" if card && sub && sub != current
        header += " (#{card})" if card && !sub

        result = header

        # Card list
        models = agent.available_models
        unless models.empty?
          lines = models.each_with_index.map do |name, i|
            marker = name == current ? " *" : ""
            "#{i + 1}. #{name}#{marker}"
          end
          result += "\n\nCards (/model <n>):\n#{lines.join("\n")}"
        end

        # Quick-switch models under current provider
        info = agent.current_model_info
        provider_id = Clacky::Providers.find_by_base_url(info&.dig(:base_url))
        if provider_id
          quick = Clacky::Providers.models(provider_id)
          unless quick.empty?
            current_for_quick = sub || current
            quick_lines = quick.each_with_index.map do |name, i|
              marker = name == current_for_quick ? " *" : ""
              "  s#{i + 1}. #{name}#{marker}"
            end
            result += "\n\nQuick switch (/model s<n>):\n#{quick_lines.join("\n")}"
            unless quick.include?(current_for_quick)
              result += "\n(#{current_for_quick} not in this provider; switch card first)"
            end
          end
        end

        adapter.send_text(chat_id, result)
      end

      def switch_model_by_index(adapter, chat_id, agent, idx)
        models = agent.config.models
        if idx < 0 || idx >= models.length
          adapter.send_text(chat_id, "Invalid number. Use /model to see available cards.")
          return
        end

        model_id = models[idx]["id"]
        if agent.switch_model_by_id(model_id)
          new_info = agent.current_model_info
          adapter.send_text(chat_id, "Switched to #{new_info&.dig(:model) || model_id}.")
        else
          adapter.send_text(chat_id, "Failed to switch model.")
        end
      end

      def switch_quick_by_index(adapter, chat_id, agent, idx)
        info = agent.current_model_info
        provider_id = Clacky::Providers.find_by_base_url(info&.dig(:base_url))

        unless provider_id
          adapter.send_text(chat_id, "No quick-switch models. Use /model <n> to switch card.")
          return
        end

        quick = Clacky::Providers.models(provider_id)
        if idx < 0 || idx >= quick.length
          adapter.send_text(chat_id, "Invalid s#{idx + 1}. Use /model to see quick-switch list.")
          return
        end

        agent.set_session_sub_model(quick[idx])
        new_info = agent.current_model_info
        adapter.send_text(chat_id, "Switched to #{new_info&.dig(:sub_model) || new_info&.dig(:model)}.")
      end

      def switch_model_by_name(adapter, chat_id, agent, name)
        info = agent.current_model_info
        provider_id = Clacky::Providers.find_by_base_url(info&.dig(:base_url))

        unless provider_id
          adapter.send_text(chat_id, "Current card has no quick-switch models. Use /model <n> to switch card.")
          return
        end

        allowed = Clacky::Providers.models(provider_id)
        if allowed.empty?
          adapter.send_text(chat_id, "No quick-switch models available. Use /model <n> to switch card.")
          return
        end

        # Clear override
        if name =~ /\A(off|clear|none)\z/i
          agent.set_session_sub_model(nil)
          new_info = agent.current_model_info
          adapter.send_text(chat_id, "Back to card default (#{new_info&.dig(:model)}).")
          return
        end

        unless allowed.include?(name)
          adapter.send_text(chat_id, "'#{name}' not available. Use /model to see quick-switch list.")
          return
        end

        agent.set_session_sub_model(name)
        new_info = agent.current_model_info
        adapter.send_text(chat_id, "Switched to #{new_info&.dig(:sub_model) || new_info&.dig(:model)}.")
      end

      def handle_skills_command(adapter, event)
        chat_id    = event[:chat_id]
        session_id = resolve_session(event)

        unless session_id
          adapter.send_text(chat_id, "No session bound. Send any message to auto-create one first.")
          return
        end

        session = @registry.get(session_id)
        agent = session&.dig(:agent)
        unless agent
          adapter.send_text(chat_id, "Session not ready.")
          return
        end

        skills = agent.skill_loader.user_invocable_skills
          .reject { |s| s.source == :default }
          .first(10)
        if skills.empty?
          adapter.send_text(chat_id, "No skills available.")
          return
        end

        lines = skills.each_with_index.map do |s, i|
          desc = s.description.to_s.strip
          desc = desc.empty? ? "(no description)" : desc.length > 50 ? "#{desc[0..49]}..." : desc
          "#{i + 1}. #{s.name} - #{desc}"
        end
        adapter.send_text(chat_id, "Skills:\n#{lines.join("\n")}")
      end

      def resolve_session(event)
        key = channel_key(event)
        @registry.list.each do |summary|
          found = nil
          @registry.with_session(summary[:id]) { |s| found = s[:channel_keys]&.include?(key) }
          return summary[:id] if found

          # Check evicted channel sessions via persisted channel_info
          next unless summary[:source] == "channel"
          next unless @registry.ensure(summary[:id])
          agent = nil
          @registry.with_session(summary[:id]) { |s| agent = s[:agent] }
          next unless agent&.channel_info
          next unless channel_key_from_info(agent.channel_info) == key
          bind_key_to_session(key, summary[:id])
          return summary[:id]
        end
        nil
      rescue StandardError => e
        Clacky::Logger.error("[ChannelManager] Session resolve failed: #{e.message}")
        nil
      end

      def auto_create_session(adapter, event)
        key      = channel_key(event)
        platform = event[:platform].to_s
        count    = @mutex.synchronize { @session_counters[platform] += 1 }
        name     = "#{platform}-#{count}"
        session_id = @session_builder.call(name: name, source: :channel)
        bind_key_to_session(key, session_id)

        # Create a long-lived ChannelUIController for this session and subscribe it
        # to the session's WebUIController. It stays for the session's full lifetime
        # so all events (agent output, errors, status) flow through web_ui → channel_ui.
        channel_ui = ChannelUIController.new(event, -> { adapter_for(event[:platform]) })
        @registry.with_session(session_id) do |s|
          s[:ui]&.subscribe_channel(channel_ui)
          s[:channel_ui] = channel_ui
        end

        Clacky::Logger.info("[ChannelManager] Auto-created session #{session_id[0, 8]} for #{key}")
        session_id
      end

      # Retrieve the ChannelUIController bound to a session (if any).
      def channel_ui_for_session(session_id)
        result = nil
        @registry.with_session(session_id) { |s| result = s[:channel_ui] }
        result
      end

      # Make sure session has a ChannelUIController subscribed to its WebUIController.
      # Needed both at startup (for restored sessions) and after a session is evicted
      # from memory and rebuilt by SessionRegistry#ensure (which drops :ui/:channel_ui).
      def ensure_channel_ui_subscribed(session_id, event)
        needs_attach = false
        @registry.with_session(session_id) do |s|
          needs_attach = s[:ui] && s[:channel_ui].nil?
        end
        return unless needs_attach

        channel_ui = ChannelUIController.new(event, -> { adapter_for(event[:platform]) })
        @registry.with_session(session_id) do |s|
          next unless s[:ui] && s[:channel_ui].nil?
          s[:ui].subscribe_channel(channel_ui)
          s[:channel_ui] = channel_ui
        end
      end

      def web_ui_for_session_diag(session_id)
        result = nil
        @registry.with_session(session_id) do |s|
          ui = s[:ui]
          result = if ui.respond_to?(:channel_subscribed?)
            ui.instance_variable_get(:@channel_subscribers)&.size || 0
          else
            -1
          end
        end
        result
      end

      def bind_key_to_session(key, session_id)
        @registry.list.each do |summary|
          @registry.with_session(summary[:id]) { |s| s[:channel_keys]&.delete(key) }
        end
        @registry.with_session(session_id) do |s|
          s[:channel_keys] ||= Set.new
          s[:channel_keys].add(key)
        end
      end

      def list_sessions(adapter, chat_id)
        sessions = @registry.list.first(5)
        if sessions.empty?
          adapter.send_text(chat_id, "No sessions available.")
          return
        end
        lines = sessions.each_with_index.map do |s, i|
          name = s[:name].to_s.empty? ? "(unnamed)" : s[:name]
          time = s[:updated_at].to_s[5, 11]&.tr("T", " ") || "-"
          "#{i + 1}. `#{s[:id][0, 8]}` #{name} (#{s[:status]}) #{time}"
        end
        adapter.send_text(chat_id, "Recent sessions:\n#{lines.join("\n")}\n\nUse `/bind <n>` to switch.")
      end

      def channel_key(event)
        platform = event[:platform].to_s
        case @binding_mode
        when :chat      then "#{platform}:chat:#{event[:chat_id]}"
        when :user      then "#{platform}:user:#{event[:user_id]}"
        else # :chat_user
          "#{platform}:chat:#{event[:chat_id]}:user:#{event[:user_id]}"
        end
      end

      def channel_key_from_info(channel_info)
        platform = channel_info[:platform].to_s
        chat_id  = channel_info[:chat_id].to_s
        user_id  = channel_info[:user_id].to_s
        case @binding_mode
        when :chat      then "#{platform}:chat:#{chat_id}"
        when :user      then "#{platform}:user:#{user_id}"
        else # :chat_user
          "#{platform}:chat:#{chat_id}:user:#{user_id}"
        end
      end

      private def extract_channel_info(event)
        {
          platform: event[:platform],
          user_id:  event[:user_id],
          chat_id:  event[:chat_id]
        }
      end

      # Extract the chat_id from the remainder of a channel_key (after removing "platform:" prefix).
      #
      # Possible formats:
      #   "chat:CHAT_ID:user:USER_ID"  → CHAT_ID  (chat_user mode)
      #   "chat:CHAT_ID"               → CHAT_ID  (chat mode)
      #   "user:USER_ID"               → USER_ID  (user mode — use user_id as fallback)
      #
      # For Feishu/WeCom send_text, the chat_id is what's needed as receive_id.
      private def extract_chat_id(remainder)
        if remainder.start_with?("chat:")
          # "chat:CHAT_ID:user:USER_ID" or "chat:CHAT_ID"
          after_chat = remainder.sub("chat:", "")
          # If there's a ":user:" segment, strip it and everything after
          idx = after_chat.index(":user:")
          idx ? after_chat[0...idx] : after_chat
        elsif remainder.start_with?("user:")
          # user-only mode: no chat_id available, use user_id
          remainder.sub("user:", "")
        else
          remainder
        end
      end

      def restore_channel_bindings
        bound_keys = Set.new
        restored_count = 0
        @registry.list(limit: nil).each do |summary|
          info = summary[:channel_info]
          next unless info.is_a?(Hash) && info[:platform] && info[:user_id] && info[:chat_id]

          @registry.ensure(summary[:id])
          agent = nil
          @registry.with_session(summary[:id]) { |s| agent = s[:agent] }
          next unless agent&.channel_info

          info = agent.channel_info
          next unless info[:platform] && info[:user_id] && info[:chat_id]

          key = channel_key_from_info(info)

          event = { platform: info[:platform], chat_id: info[:chat_id] }
          ensure_channel_ui_subscribed(summary[:id], event)

          next unless bound_keys.add?(key)
          bind_key_to_session(key, summary[:id])

          Clacky::Logger.info("[ChannelManager] Restored channel binding #{key} -> session #{summary[:id][0, 8]}")
          restored_count += 1
        end
        Clacky::Logger.info("[ChannelManager] Restored #{restored_count} channel binding(s)") if restored_count > 0
      end

      def safe_stop_adapter(adapter)
        adapter.stop
      rescue StandardError => e
        Clacky::Logger.warn("[ChannelManager] Error stopping #{adapter.platform_id}: #{e.message}")
      end

      # Prepend sender identity and optional group chat history to the user's message.
      # Returns the original text unchanged when there is no extra context.
      private def build_prompt_with_context(event, text)
        user_id = event[:user_id].to_s
        sender  = user_id

        history = event[:group_history]
        if history.nil? || history.empty?
          return "[Sender: #{sender}]\n#{text}"
        end

        lines  = history.map { |e| "#{e[:user_id]}: #{e[:text]}" }.join("\n")
        header = "[Group chat history (#{history.size} messages)]"
        [header, lines, "---", "[Sender: #{sender}]", text].join("\n")
      end
    end
  end
end
