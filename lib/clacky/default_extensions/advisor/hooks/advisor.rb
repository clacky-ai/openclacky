# frozen_string_literal: true

# Advisor extension core: tool-trail recording, wrap-up signal detection, and
# a lightweight LLM call that produces next-step recommendations.
#
# Shared by hooks/advisor_tool_use.rb (after_tool_use) and
# hooks/advisor_complete.rb (on_complete). One Worker instance per agent,
# attached to the agent's ivar, so both hooks see the same state.
#
# All work that touches the LLM runs on a detached ThreadRegistry thread; the
# after_tool_use callback itself only does O(1) bookkeeping so the main loop
# is never blocked.

module Clacky
  module Advisor
    RULE_PATH = File.expand_path("../advisors/general.md", __dir__)
    USER_CONFIG_PATH = File.expand_path("~/.clacky/advisor.yml")
    AGENTS_DIR = File.expand_path("~/.clacky/agents")
    PROFILE_CHARS = 1000

    DEFAULTS = {
      "enabled" => false,
      "max_tokens" => 8000
    }.freeze

    WRITE_TOOLS = %w[write edit file_write file_edit].freeze
    TRAIL_LIMIT = 30
    BRIEF_ACTIONS = 8
    CONVERSATION_TURNS = 8
    SUMMARY_LIMIT = 200
    MESSAGE_LIMIT = 200

    class << self
      def enabled_for?(agent)
        return false if agent.instance_variable_get(:@is_subagent)
        enabled?
      end

      def enabled?
        config_for(nil)["enabled"] != false
      end

      def config_for(_agent)
        DEFAULTS.merge(user_config)
      end

      # Persist the enabled flag to ~/.clacky/advisor.yml, keeping any other
      # user-set keys (model, max_tokens) intact. Resets the cache so the next
      # enabled?/config_for read reflects the new value immediately.
      def set_enabled(value)
        reset_user_config!
        current = user_config
        current["enabled"] = value ? true : false
        FileUtils.mkdir_p(File.dirname(USER_CONFIG_PATH))
        File.write(USER_CONFIG_PATH, YAML.dump(current))
        reset_user_config!
        true
      end

      def reset_user_config!
        @user_config = nil
      end

      def worker_for(agent)
        worker = agent.instance_variable_get(:@advisor_worker)
        return worker if worker

        worker = Worker.new(agent)
        agent.instance_variable_set(:@advisor_worker, worker)
        worker
      end

      private def user_config
        return @user_config if @user_config
        return @user_config = {} unless File.file?(USER_CONFIG_PATH)

        @user_config = begin
          YAMLCompat.safe_load(File.read(USER_CONFIG_PATH)) || {}
        rescue StandardError => e
          Clacky::Logger.warn("[Advisor] failed to read #{USER_CONFIG_PATH}: #{e.message}")
          {}
        end
      end
    end

    # One per agent. observe_tool runs on the main agent thread (must stay
    # cheap); the analysis runs on a detached thread spawned once per round
    # from finish_run (the on_complete hook).
    class Worker
      def initialize(agent)
        @agent = agent
        @mutex = Mutex.new
        @trail = []
        @tools_this_run = 0
      end

      # after_tool_use callback. O(1): append to the trail for the brief.
      def observe_tool(call, result)
        name = call[:name].to_s
        @mutex.synchronize do
          @tools_this_run += 1
          @trail << [name, summarize(result)]
          @trail = @trail.last(TRAIL_LIMIT)
        end
      end

      # on_complete callback: a run ended. Snapshot this round's state and
      # analyse asynchronously — one recommendation per round, including
      # rounds with no tool calls at all (e.g. the very first "hi"). The
      # pending event is emitted synchronously so the UI can show a "working"
      # state immediately instead of the card popping in out of nowhere.
      def finish_run
        snapshot = @mutex.synchronize do
          snap = {
            tools: @tools_this_run,
            trail: @trail.dup,
            user_message: recent_user_message,
            conversation: recent_conversation
          }
          @trail.clear
          @tools_this_run = 0
          snap
        end
        Clacky::Logger.info("[Advisor] finish_run",
                            session: @agent.session_id.to_s,
                            tools: snapshot[:tools],
                            trail: snapshot[:trail].size,
                            user: snapshot[:user_message].to_s[0, 80])
        emit_pending
        ThreadRegistry.spawn(name: "advisor-#{@agent.session_id}", daemon: true) do
          analyze(snapshot)
        end
      rescue StandardError => e
        warn_error("schedule", e)
      end

      private def analyze(snapshot)
        cfg = Advisor.config_for(@agent)
        advice = generate_advice(cfg, snapshot)
        Clacky::Logger.info("[Advisor] analyze",
                            session: @agent.session_id.to_s,
                            len: advice.length,
                            head: advice[0, 100].to_s)
        if advice.empty? || advice.strip == "none"
          @agent.emit_event("ext.advisor.done", reason: "empty")
        else
          push_advice(advice)
        end
      rescue StandardError => e
        warn_error("analyze", e)
        @agent.emit_event("ext.advisor.done", reason: "error", message: e.message.to_s[0, 200])
      end

      private def generate_advice(cfg, snapshot)
        rule = File.file?(RULE_PATH) ? File.read(RULE_PATH) : ""
        client = advisor_client(cfg)
        return "" unless client

        # The main agent sees SOUL.md/USER.md (language preference, persona);
        # the advisor call must too, or recommendations ignore the user's
        # language/style expectations.
        system = rule.dup
        ctx = profile_context
        system = "#{system}\n\n#{ctx}" unless ctx.empty?

        raw = client.send_messages(
          [{ role: "system", content: system }, { role: "user", content: build_brief(snapshot) }],
          model: advisor_model_name(cfg),
          max_tokens: cfg["max_tokens"],
          reasoning_effort: "low"
        )
        raw.to_s.strip
      end

      # User persona files (~/.clacky/agents/USER.md + SOUL.md), truncated to
      # the same budget the main system prompt uses. Absent/empty files are
      # skipped so no placeholder text leaks into the recommendation prompt.
      private def profile_context
        parts = []
        [["USER.md", "USER PROFILE"], ["SOUL.md", "AGENT SOUL"]].each do |file, label|
          path = File.join(AGENTS_DIR, file)
          next unless File.file?(path) && !File.zero?(path)

          content = File.read(path).strip
          parts << "[#{label}]\n#{content[0, PROFILE_CHARS]}"
        end
        parts.join("\n\n")
      end

      # advisor.yml may name a `model` from the configured models list; that
      # entry gets its own Client so a fast/cheap provider can be used for
      # recommendations regardless of the primary model. Falls back to the
      # agent's own client when unset or unmatched.
      private def advisor_client(cfg)
        name = cfg["model"].to_s
        main_client = @agent.instance_variable_get(:@client)
        return main_client if name.empty?

        @advisor_client ||= begin
          entry = @agent.config.find_model_by_name_and_url(name)
          if entry
            Clacky::Client.new(
              entry["api_key"],
              base_url: entry["base_url"],
              model: entry["model"],
              anthropic_format: entry["anthropic_format"] == true
            )
          else
            main_client
          end
        end
      end

      private def emit_pending
        @agent.emit_event("ext.advisor.pending")
      rescue StandardError
        nil
      end

      private def push_advice(advice)
        @agent.emit_event("ext.advisor.recommendations", content: advice)
      end

      private def advisor_model_name(cfg)
        explicit = cfg["model"].to_s
        return explicit unless explicit.empty?

        lite = @agent.config.lite_model_config_for_current
        (lite && lite["model"]) || @agent.config.model_name
      end

      private def build_brief(snapshot)
        parts = []
        parts << "[Advisor brief]"
        parts << "Project: #{File.basename(@agent.working_dir.to_s)}"
        parts << "Tools used this round: #{snapshot[:tools]}"
        if snapshot[:trail].empty?
          parts << "Recent actions: (none — this round had no tool calls)"
        else
          parts << "Recent actions:"
          snapshot[:trail].last(BRIEF_ACTIONS).each do |name, summary|
            parts << "- #{name}: #{summary}"
          end
        end
        parts << "Recent conversation (most recent last):"
        if snapshot[:conversation].empty?
          parts << "(empty)"
        else
          snapshot[:conversation].each { |role, text| parts << "- #{role}: #{text}" }
        end
        parts.join("\n")
      end

      private def recent_user_message
        conversation = recent_conversation
        msg = conversation.reverse.find { |role, _| role == "user" }
        msg ? msg[1] : "—"
      end

      private def recent_conversation
        history = @agent.history
        return [] unless history

        history.to_a.last(CONVERSATION_TURNS).filter_map do |m|
          role = m[:role].to_s
          next unless %w[user assistant].include?(role)

          content = m[:content]
          content = content.join("\n") if content.is_a?(Array)
          text = content.to_s.gsub(/\s+/, " ").strip
          next if text.empty?

          [role, text.length > MESSAGE_LIMIT ? "#{text[0, MESSAGE_LIMIT]}…" : text]
        end
      end

      private def summarize(result)
        return "" unless result

        content = result.is_a?(Hash) ? result[:content] : result.to_s
        content = content.join(" ") if content.is_a?(Array)
        text = content.to_s.gsub(/\s+/, " ").strip
        text.length > SUMMARY_LIMIT ? "#{text[0, SUMMARY_LIMIT]}…" : text
      end

      private def warn_error(stage, error)
        Clacky::Logger.warn("[Advisor] #{stage} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
