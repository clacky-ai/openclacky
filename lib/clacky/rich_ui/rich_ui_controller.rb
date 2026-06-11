# frozen_string_literal: true

require "json"
require "uri"
require "base64"
require "set"
require "ruby_rich"
require_relative "../ui_interface"
require_relative "../providers"
require_relative "../ui2/components/welcome_banner"
require_relative "extensions/ruby_rich_patches"
require_relative "shell/rich_agent_shell"
require_relative "components/sidebar"
require_relative "components/thinking_live_view"
require_relative "components/status_view"
require_relative "layout_adapter"
require_relative "progress_handle_adapter"
require_relative "components/dialogs/config_menu_dialog"
require_relative "components/dialogs/form_dialog"
require_relative "components/dialogs/approval_dialog"

module Clacky
  class RichUIController
    include Clacky::UIInterface

    STREAMING_MARKDOWN_THRESHOLD = 240
    STREAMING_MARKDOWN_CHUNK_SIZE = 6
    STREAMING_MARKDOWN_DELAY = 0.03

    COMMANDS = [
      { label: "/clear", value: "/clear", description: "Clear output and restart session" },
      { label: "/config", value: "/config", description: "Open configuration" },
      { label: "/undo", value: "/undo", description: "Restore a previous task state" },
      { label: "/help", value: "/help", description: "Show commands" },
      { label: "/exit", value: "/exit", description: "Exit application", aliases: ["/quit"] }
    ].freeze

    attr_reader :layout, :shell, :running
    attr_accessor :config, :available_models

    def initialize(config = {})
      @config = {
        working_dir: config[:working_dir],
        mode: config[:mode],
        model: config[:model],
        theme: config[:theme]
      }
      @welcome_banner = Clacky::UI2::Components::WelcomeBanner.new
      @available_models = config[:model_names] || [config[:model] || "unknown"]
      @shell = RichAgentShell.new(
        title: "OpenClacky",
        subtitle: config[:working_dir].to_s,
        model: config[:model].to_s,
        theme: RubyRich::Theme.agent_dark,
        commands: COMMANDS
      )
      @shell.instance_variable_set(:@clacky_controller, self)
      @layout = LayoutAdapter.new(@shell)
      @input_callback = nil
      @interrupt_callback = nil
      @work_label = nil
      @ctrl_c_warning = nil
      @latest_latency = nil
      @always_allow_fingerprints = Set.new
      @mode_toggle_callback = nil
      @model_switch_callback = nil
      @time_machine_callback = nil
      @tasks_count = 0
      @total_cost = 0.0
      @running = false
      @turn_active = false
      @tool_ids = []
      @todo_items = []
      @explicit_todo_cycle = false
      @tool_activities = []
      @tool_activity_by_id = {}
      @legacy_progress = {}
      @stdout_lines = []
      @callback_threads = []
      @stream_threads = []

      wire_shell_callbacks
    end

    def initialize_and_show_banner(recent_user_messages: nil)
      @running = true
      @shell.update_status(session_status)
      if recent_user_messages && !recent_user_messages.empty?
        @shell.add_separator("recent session")
        recent_user_messages.each { |message| @shell.add_user_message(message) }
      else
        add_plain_block(render_welcome_banner)
      end
    end

    def start
      initialize_and_show_banner unless @running
      start_input_loop
    end

    def start_input_loop
      @running = true
      @shell.start
    ensure
      @running = false
    end

    def stop(clear_screen: false)
      @running = false
      @shell.stop
      RubyRich::Terminal.clear if clear_screen
    end

    # Max description length for slash-menu display. Skill descriptions can be
    # hundreds of chars; RubyRich Composer renders each command as a single line
    # and long lines wrap or clip unpredictably. Truncating at registration is
    # simpler and more reliable than patching the gem's render_command.
    SKILL_DESC_MAX = 50

    def set_skill_loader(skill_loader, agent_profile = nil)
      return unless skill_loader

      skills = skill_loader.user_invocable_skills
      skills = skills.select { |s| s.allowed_for_agent?(agent_profile.name) } if agent_profile

      skills.each do |skill|
        desc = skill.description.to_s
        desc = desc.length > SKILL_DESC_MAX ? "#{desc[0, SKILL_DESC_MAX - 1]}…" : desc
        @shell.composer.register_command(
          name: skill.slash_command,
          description: desc
          # No handler — text falls through to submit callback → CLI → agent
        )
      end
    end

    def set_agent(_agent, _agent_profile = nil); end

    def on_input(&block)
      @input_callback = block
    end

    def on_interrupt(&block)
      @interrupt_callback = block
    end

    def on_mode_toggle(&block)
      @mode_toggle_callback = block
    end

    def on_model_switch(&block)
      @model_switch_callback = block
    end

    def on_time_machine(&block)
      @time_machine_callback = block
    end

    def append_output(content)
      return if content.nil?

      @shell.add_markdown(content.to_s)
    end

    def log(message, level: :info)
      case level.to_sym
      when :error then show_error(message)
      when :warning, :warn then show_warning(message)
      when :debug then nil
      else show_info(message)
      end
    end

    def show_assistant_message(content, files:)
      thinking_text, clean_text = extract_thinking_and_content(content)
      unless thinking_text.to_s.strip.empty?
        # Show live thinking with spinner + timer in fixed area
        @shell.thinking_live.start_thinking
        stream_thinking_live(thinking_text.strip)
        elapsed = @shell.thinking_live.instance_variable_get(:@start_time)
        elapsed = elapsed ? (Time.now - elapsed).round(1) : 0.0
        @shell.thinking_live.finish_thinking
        # Also add collapsed thinking block for reference (Ctrl+O to expand)
        @shell.add_thinking(thinking_text.strip, status: "#{elapsed}s", collapsed: true)
        # Hide the live area so transcript expands back to full height
        @shell.thinking_live.idle!
      end
      text = clean_text
      stream_thread = nil
      stream_thread = add_conversation_markdown(text) unless text.nil? || text.strip.empty?
      if stream_thread.is_a?(Thread)
        add_file_summary_after(stream_thread, files)
      else
        add_file_summary(files)
      end
    end

    # Stream thinking text into the live area character by character.
    # After streaming completes, the finished state shows for ~1 second.
    def stream_thinking_live(text, chunk_size: 3, delay: 0.008)
      text.each_char.each_slice(chunk_size) do |chars|
        @shell.thinking_live.append_text(chars.join)
        sleep(delay)
      end
      # Brief pause to show "Thinking done" before next content renders
      sleep(0.6)
    end

    def show_tool_call(name, args)
      id = @shell.start_tool_call(name: name.to_s, input: format_args(args), status: :running)
      if id
        @tool_ids << id
        track_tool_activity(id, tool_activity_label(name, args), :running)
        @work_label = "#{name}…"
      end
    end

    def show_tool_result(result)
      if (id = @tool_ids.pop)
        @shell.finish_tool_call(id, status: :done, output: tool_output_text(result.to_s, :done))
        update_tool_activity(id, :done)
      else
        @shell.add_markdown(result.to_s)
      end
    end

    def show_tool_stdout(lines)
      @stdout_lines.concat(Array(lines).map(&:to_s))
    end

    def show_tool_error(error)
      message = error.is_a?(Exception) ? error.message : error.to_s
      if (id = @tool_ids.pop)
        @shell.finish_tool_call(id, status: :error, output: tool_output_text(message, :error))
        update_tool_activity(id, :error)
      else
        @shell.add_error_message(message)
      end
    end

    def tool_output_text(text, status = :done)
      marker = status == :error ? "[Error]" : "[OK]"
      color = status == :error ? :red : :green
      clean = text.to_s.sub(/\A\[(?:OK|Error)\]\s*/, "")
      "#{RubyRich::AnsiCode.color(color, true)}#{marker}#{RubyRich::AnsiCode.reset} #{clean}"
    end

    def show_tool_args(formatted_args)
      append_output("Args: #{formatted_args}")
    end

    def show_file_write_preview(path, is_new_file:)
      append_output("#{is_new_file ? "Creating" : "Modifying"} file: #{path || "(unknown)"}")
    end

    def show_file_edit_preview(path)
      append_output("Editing file: #{path || "(unknown)"}")
    end

    def show_file_error(error_message)
      show_error(error_message)
    end

    def show_shell_preview(command)
      append_output("$ #{command}")
    end

    def show_diff(old_content, new_content, max_lines: 50)
      require "diffy"
      diff = Diffy::Diff.new(old_content, new_content, context: 3).to_s
      stats = parse_diff_stats(diff)
      header = "─── Diff#{stats}#{" " unless stats.empty?}───"
      lines = diff.lines
      visible = lines.take(max_lines).join
      hidden = lines.length - max_lines
      trailer = hidden.positive? ? "\n... (#{hidden} more lines hidden)" : ""
      @shell.add_diff(content: "#{header}\n#{visible}#{trailer}")
    rescue LoadError
      append_output("Old size: #{old_content.bytesize} bytes\nNew size: #{new_content.bytesize} bytes")
    end

    def parse_diff_stats(diff_text)
      adds = 0
      dels = 0
      hunks = 0
      diff_text.each_line do |line|
        adds += 1 if line.start_with?("+") && !line.start_with?("+++")
        dels += 1 if line.start_with?("-") && !line.start_with?("---")
        hunks += 1 if line.start_with?("@@")
      end
      return "" if adds.zero? && dels.zero?

      parts = []
      parts << "+#{adds}" if adds.positive?
      parts << "-#{dels}" if dels.positive?
      parts << "#{hunks} hunks" if hunks.positive?
      " (#{parts.join(", ")})"
    end

    def show_token_usage(token_data)
      @shell.show_token_usage(
        input: token_data[:prompt_tokens],
        output: token_data[:completion_tokens],
        total: token_data[:total_tokens],
        cost: token_data[:cost]
      )
      @shell.sidebar.update_context(token_data) if @shell.sidebar
    end

    def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false, cost_source: nil)
      set_idle_status
      return if awaiting_user_feedback || iterations <= 5

      parts = ["Completed #{iterations} iterations", "cost $#{cost.round(4)}"]
      parts << "#{duration.round(1)}s" if duration
      append_output(parts.join(" · "))
    end

    def show_info(message, prefix_newline: true)
      _ = prefix_newline
      @shell.add_system_message(message.to_s)
    end

    def show_warning(message)
      @shell.add_system_message("Warning: #{message}")
    end

    def show_error(message)
      @shell.add_error_message(message.to_s)
    end

    def show_success(message)
      @shell.add_system_message("OK: #{message}")
    end

    def show_progress(message = nil, prefix_newline: true, progress_type: "thinking", phase: "active", metadata: {})
      _ = prefix_newline
      type = progress_type.to_s
      if phase.to_s == "done"
        @legacy_progress.delete(type)&.finish(final_message: message)
        return
      end

      handle = @legacy_progress[type]
      if handle
        handle.update(message: message, metadata: metadata)
      else
        @legacy_progress[type] = start_progress(message: message, style: type == "thinking" ? :primary : :quiet)
      end
    end

    def start_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      _ = quiet_on_fast_finish
      ProgressHandleAdapter.new(@shell.start_progress(message || "Working", style: style))
    end

    def with_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      handle = start_progress(message: message, style: style, quiet_on_fast_finish: quiet_on_fast_finish)
      begin
        yield handle
      ensure
        handle.finish
      end
    end

    def update_sessionbar(tasks: nil, cost: nil, cost_source: nil, status: nil, latency: nil, session_id: nil)
      _ = cost_source
      @latest_latency = nil
      if latency.is_a?(Hash)
        ms = latency[:ttft_ms] || latency[:duration_ms]
        @latest_latency = ms ? "#{(ms / 1000.0).round(1)}s" : nil
      end
      @tasks_count = tasks if tasks
      @total_cost = cost if cost
      @status = status if status
      @shell.update_status(session_status)
    end

    def update_todos(todos)
      @todo_items = Array(todos).map { |todo| normalize_todo(todo) }
      @explicit_todo_cycle = true
      refresh_sidebar_tasks
    end

    def set_working_status
      @turn_active = true
      @work_label ||= "working…"
      update_sessionbar(status: "working")
    end

    def set_idle_status
      @turn_active = false
      @work_label = nil
      update_sessionbar(status: "idle")
    end

    def request_confirmation(message, default: true)
      tool_name, params = parse_tool_info(message)
      risk = tool_risk_level(tool_name)
      category = tool_category(tool_name)

      fingerprint = build_fingerprint(tool_name, params)
      return true if @always_allow_fingerprints.include?(fingerprint)

      show_info(message)
      dialog = ApprovalDialog.new(
        tool_name: tool_name || "unknown",
        message: message,
        params: params,
        risk: risk,
        category: category
      )
      result = show_blocking_dialog(dialog)

      case result
      when :approve
        true
      when :always_allow
        @always_allow_fingerprints.add(fingerprint)
        true
      when :deny
        false
      else
        default
      end
    end

    # ── Approval helpers ──────────────────────────────────────

    def parse_tool_info(message)
      return [nil, {}] unless message

      tool_name = message[/\A\w+/]&.downcase
      params = {}

      case tool_name
      when "edit", "write"
        path = message[/\((.+?)\)/, 1]
        params[:path] = path if path
      when "terminal", "shell", "exec"
        cmd = message[/"(.+?)"/, 1]
        params[:command] = cmd if cmd
      when "web_search", "web_fetch"
        params[:query] = message[(message.index("(")&.+(1) || 0)..]&.chomp(")")&.strip
      when "execute", "run"
        params[:command] = message[(message.index("(")&.+(1) || 0)..]&.chomp(")")&.strip
      end

      params.reject! { |_, v| v.to_s.empty? }
      [tool_name, params]
    end

    def tool_risk_level(tool_name)
      case tool_name
      when "read", "grep", "list", "search", "web_search", "web_fetch", "fetch_url"
        :low
      when "edit", "write", "patch", "apply_patch"
        :medium
      when "shell", "terminal", "exec", "execute", "run"
        :high
      when "install", "remove", "delete", "rm", "force"
        :critical
      else
        :medium
      end
    end

    def tool_category(tool_name)
      case tool_name
      when "read", "write", "edit", "patch", "apply_patch", "grep", "list"
        :file
      when "shell", "terminal", "exec", "execute", "run"
        :shell
      when "web_search", "web_fetch", "fetch_url"
        :network
      when "install", "billing", "payment"
        :paid
      else
        :file
      end
    end

    def show_model_switch_dialog
      models = @available_models || [@config[:model] || "unknown"]
      choices = models.each_with_index.map do |name, i|
        current = name == @config[:model]
        { label: "#{current ? "● " : "  "}#{name}", value: name }
      end

      selected = show_menu_dialog(
        title: "Switch Model",
        choices: choices,
        selected_index: models.index(@config[:model]) || 0
      )
      return nil if selected.nil?

      persist_choice = show_menu_dialog(
        title: "Apply Scope",
        choices: [
          { label: "This session only", value: false },
          { label: "Save permanently",  value: true  }
        ],
        selected_index: 0
      )
      return nil if persist_choice.nil?

      { model: selected, persist: persist_choice }
    end

    def build_fingerprint(tool_name, params)
      "#{tool_name}:#{params.sort.to_s}"
    end

    def clear_input
      @shell.composer.editor.clear
    end

    def set_input_tips(message, type: :info)
      update_sessionbar(status: "#{type}: #{message}")
    end

    def show_help
      @shell.add_markdown(<<~HELP)
        Commands:
          /clear - Clear output and restart session
          /exit - Exit application

        Input:
          Shift+Enter - New line
          Up/Down - History navigation
          Ctrl+C - Interrupt current task
      HELP
    end

    def show_config_modal(current_config, test_callback: nil)
      return nil unless @running

      loop do
        choices = config_menu_choices(current_config)
        result = show_menu_dialog(
          title: "Model Configuration",
          choices: choices,
          selected_index: config_initial_selection(choices)
        )
        return nil if result.nil?

        case result[:action]
        when :switch
          return result
        when :add
          new_model = show_model_edit_form(nil, test_callback: test_callback)
          if new_model
            anthropic_format = new_model[:provider] == "anthropic"
            current_config.add_model(
              model: new_model[:model],
              api_key: new_model[:api_key],
              base_url: new_model[:base_url],
              anthropic_format: anthropic_format
            )
            new_id = current_config.models.last["id"]
            return { action: :add, model_id: new_id }
          end
        when :edit
          current_model = current_config.current_model
          edited = show_model_edit_form(current_model, test_callback: test_callback)
          if edited
            current_model["api_key"] = edited[:api_key]
            current_model["model"] = edited[:model]
            current_model["base_url"] = edited[:base_url]
            return { action: :edit, model_id: current_model["id"] }
          end
        when :delete
          if current_config.models.length <= 1
            show_warning("Cannot delete the last model.")
            next
          end

          current_config.remove_model(current_config.current_model_index)
          new_current = current_config.current_model
          return { action: :delete, model_id: new_current && new_current["id"] }
        when :close
          return nil
        end
      end
    end

    # Returns [thinking_text, clean_content] by extracting <thinking>...</thinking>
    # and <think>...</think> blocks from the content.
    def extract_thinking_and_content(content)
      return ["", content.to_s] if content.nil?

      thinking_parts = []
      clean = content.to_s.dup

      # Collect all thinking blocks and remove them from clean text
      clean.gsub!(%r{<think(?:ing)?>\s*([\s\S]*?)\s*</think(?:ing)?>}mi) do
        thinking_parts << Regexp.last_match(1).strip
        ""
      end

      clean = clean.gsub(/\n{3,}/, "\n\n").strip
      [thinking_parts.join("\n\n"), clean]
    end

    def track_tool_activity(id, label, status)
      activity = { id: id, label: label.to_s, status: status }
      @tool_activities << activity
      @tool_activities.shift while @tool_activities.length > 12
      @tool_activity_by_id[id] = activity
      refresh_sidebar_tasks
    end

    def update_tool_activity(id, status)
      activity = @tool_activity_by_id[id]
      return unless activity

      activity[:status] = status
      refresh_sidebar_tasks
    end

    def refresh_sidebar_tasks
      @shell.update_tasks(@todo_items)
      @shell.sidebar.update_work_activities(@tool_activities)
      @shell.sidebar.update_work_stats(@tasks_count, @total_cost)
    end

    def reset_task_sidebar_tracking
      @todo_items = []
      @explicit_todo_cycle = false
      @tool_activities = []
      @tool_activity_by_id = {}
      refresh_sidebar_tasks
    end

    def tool_activity_label(name, args)
      tool_name = name.to_s
      data = normalize_tool_args(args)

      case tool_name
      when "web_search"
        query = data["query"].to_s
        return tool_name if query.empty?

        %(web_search("#{escape_tool_label(truncate_tool_label(query))}"))
      when "web_fetch"
        url = data["url"].to_s
        return tool_name if url.empty?

        "web_fetch(#{truncate_tool_label(tool_url_host(url))})"
      else
        compact = compact_tool_arg(data)
        compact ? "#{tool_name}(#{compact})" : tool_name
      end
    end

    def normalize_tool_args(args)
      parsed = if args.is_a?(String)
        JSON.parse(args)
      else
        args
      end
      return {} unless parsed.is_a?(Hash)

      parsed.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value }
    rescue JSON::ParserError
      {}
    end

    def compact_tool_arg(data)
      key = %w[query url path file command pattern task].find { |candidate| data.key?(candidate) && !data[candidate].to_s.empty? }
      return nil unless key

      value = key == "url" ? tool_url_host(data[key].to_s) : data[key].to_s
      escaped = escape_tool_label(truncate_tool_label(value))
      value.match?(/\A[\w.-]+\z/) ? escaped : %("#{escaped}")
    end

    def tool_url_host(url)
      URI.parse(url).host || url
    rescue URI::InvalidURIError
      url
    end

    def truncate_tool_label(text, limit = 40)
      chars = text.to_s.each_char.to_a
      return text.to_s if chars.length <= limit

      "#{chars.first(limit - 3).join}..."
    end

    def escape_tool_label(text)
      text.to_s.gsub("\\", "\\\\\\").gsub('"', '\"')
    end

    def add_conversation_markdown(text)
      markdown = normalize_markdown_for_terminal(text)
      return @shell.add_markdown(markdown) unless stream_markdown?(markdown)

      id = @shell.add_markdown("", streaming: true)
      return @shell.add_markdown(markdown) unless id

      thread = Thread.new do
        markdown.each_char.each_slice(STREAMING_MARKDOWN_CHUNK_SIZE) do |chars|
          @shell.append_to_message(id, chars.join)
          sleep(STREAMING_MARKDOWN_DELAY)
        end
      end
      @stream_threads << thread
      @stream_threads.reject! { |item| !item.alive? }
      thread
    end

    def stream_markdown?(text)
      text.length >= STREAMING_MARKDOWN_THRESHOLD
    end

    def add_file_summary_after(stream_thread, files)
      return if Array(files).empty?

      thread = Thread.new do
        stream_thread.join
        add_file_summary(files)
      end
      @stream_threads << thread
      @stream_threads.reject! { |item| !item.alive? }
    end

    def add_plain_block(text)
      @shell.transcript.add_block(:markdown, expand_ansi_multiline_spans(text), metadata: { plain: true })
      @shell.viewport.scroll_to_bottom
    end

    def expand_ansi_multiline_spans(text)
      active = +""
      text.to_s.lines.map do |line|
        body = line.chomp
        prefix = body.start_with?("\e[") || active.empty? ? "" : active
        body.scan(/\e\[[0-9;:]*m/).each do |code|
          active = code == RubyRich::AnsiCode.reset ? +"" : code
        end
        suffix = !active.empty? && !body.end_with?(RubyRich::AnsiCode.reset) ? RubyRich::AnsiCode.reset : ""
        "#{prefix}#{body}#{suffix}"
      end.join("\n")
    end

    def normalize_markdown_for_terminal(text)
      text.to_s
        .gsub(/\r\n?/, "\n")
        .gsub(/\A[ \t]*\n+/, "")
        .gsub(/\n+[ \t]*\z/, "")
    end

    def add_file_summary(files)
      items = Array(files).filter_map do |file|
        path = file[:path] || file["path"] || file[:name] || file["name"]
        next if path.to_s.strip.empty?

        "- `#{path}`"
      end
      return if items.empty?

      @shell.add_markdown("**Files**\n\n#{items.join("\n")}")
    end

    def wire_shell_callbacks
      @shell.on_submit do |text, attachments|
        reset_task_sidebar_tracking
        @ctrl_c_warning = nil
        files = Array(attachments).map { |attachment| attachment.respond_to?(:to_h) ? attachment.to_h : attachment }
        @shell.add_user_message(text)
        run_callback_async { @input_callback&.call(text, files, display: text) }
      end

      @shell.on_interrupt do |input_was_empty:|
        @ctrl_c_warning = "Press Ctrl+C again to exit"
        @interrupt_callback&.call(input_was_empty: input_was_empty)
      end

      @shell.on_mode_toggle do |mode|
        @config[:mode] = mode.to_s
        @mode_toggle_callback&.call(mode.to_s)
      end

      @shell.on_esc do
        handle_esc
      end

      @shell.instance_variable_get(:@callbacks)[:clear_ctrlc] = -> { @ctrl_c_warning = nil }

      @shell.instance_variable_get(:@callbacks)[:model_switch] = -> {
        Thread.new do
          result = show_model_switch_dialog
          if result
            @config[:model] = result[:model]
            @latest_latency = nil
            @shell.update_status(session_status)
            @model_switch_callback&.call(result[:model], result[:persist])
          end
        rescue => e
          $stderr.puts "[model_switch] #{e.class}: #{e.message}"
        end
      }
    end

    # Esc cancellation stack (tui_design.md §2.8).
    # Called from Composer's @on_escape callback (before native escape).
    # Returns true when handled (skip native), false to fall through.
    def handle_esc
      # Layer 1: Close any open dialog or slash menu
      if @shell.layout.dialog
        dialog = @shell.layout.dialog
        dialog.finish(nil) if dialog.respond_to?(:finish)
        @shell.layout.hide_dialog
        return true
      end
      if @shell.composer.menu_open?
        @shell.composer.send(:close_menu)
        return true
      end

      # Layer 2: Interrupt running turn
      if @turn_active
        @interrupt_callback&.call(input_was_empty: false)
        return true
      end

      # Layer 3: Discard queued draft (future; return true when done)

      # Layer 4+5: Fall through to Composer's native escape —
      #   editor with text → clear, empty editor → focus/no-op
      false
    end

    def session_status
      [
        @status || "idle",
        @config[:mode],
        @config[:model],
        "#{@tasks_count} tasks",
        "$#{@total_cost.round(4)}"
      ].compact.join(" · ")
    end

    def run_callback_async(&block)
      @callback_threads.reject! { |thread| !thread.alive? }
      @callback_threads << Thread.new do
        block.call
      rescue StandardError => e
        show_error(e.message)
      end
    end

    def render_welcome_banner
      @welcome_banner.render_full(
        working_dir: @config[:working_dir].to_s,
        mode: @config[:mode].to_s,
        width: terminal_width
      )
    end

    def terminal_width
      if defined?(TTY::Screen)
        TTY::Screen.width
      else
        120
      end
    rescue StandardError
      120
    end

    def config_menu_choices(current_config)
      choices = current_config.models.each_with_index.map do |model, index|
        type_badge = case model["type"]
                     when "default" then "[default] "
                     when "lite" then "[lite] "
                     else ""
                     end
        {
          label: "#{type_badge}#{model["model"] || "unnamed"} (#{mask_api_key(model["api_key"])})",
          value: { action: :switch, model_id: model["id"] },
          current: index == current_config.current_model_index
        }
      end

      choices + [
        { label: "─" * 50, disabled: true },
        { label: "[+] Add New Model", value: { action: :add } },
        { label: "[*] Edit Current Model", value: { action: :edit } },
        (current_config.models.length > 1 ? { label: "[-] Delete Model", value: { action: :delete } } : nil),
        { label: "[X] Close", value: { action: :close } }
      ].compact
    end

    def config_initial_selection(choices)
      choices.index { |choice| choice[:current] } || choices.index { |choice| !choice[:disabled] } || 0
    end

    def show_menu_dialog(title:, choices:, selected_index: nil)
      selected_index ||= config_initial_selection(choices)
      dialog = ConfigMenuDialog.new(title: title, choices: choices, selected_index: selected_index)

      dialog.key(:up, 1_000) { dialog.move_up; true }
      dialog.key(:down, 1_000) { dialog.move_down; true }
      dialog.key(:string, 1_000) do |event, _live|
        case event[:value]
        when "k" then dialog.move_up
        when "j" then dialog.move_down
        when "q" then dialog.finish(nil)
        end
        true
      end
      dialog.key(:enter, 1_000) do
        selected = dialog.selected_choice
        dialog.finish(selected && !selected[:disabled] ? selected[:value] : nil)
      end
      dialog.key(:escape, 1_000) { dialog.finish(nil) }

      show_blocking_dialog(dialog)
    end

    def show_form_dialog(title:, fields:)
      dialog = FormDialog.new(title: title, fields: fields)
      dialog.key(:escape, 1_000) { dialog.finish(nil) }
      show_blocking_dialog(dialog)
    end

    def show_blocking_dialog(dialog)
      @shell.layout.show_dialog(dialog)
      dialog.wait
    ensure
      @shell.layout.hide_dialog if @shell.layout.dialog.equal?(dialog)
    end

    def show_model_edit_form(model, test_callback: nil)
      is_new = model.nil?
      model ||= {}
      selected_provider = nil

      if is_new
        selected_provider = show_provider_selection
        return nil if selected_provider.nil?
      end

      provider_preset = selected_provider && selected_provider != "custom" ? Clacky::Providers.get(selected_provider) : nil
      default_model = provider_preset ? provider_preset["default_model"] : model["model"]
      default_base_url = provider_preset ? provider_preset["base_url"] : model["base_url"]
      masked_key = mask_api_key(model["api_key"])

      fields = [
        {
          name: :api_key,
          label: "API Key #{is_new ? "" : "(current: #{masked_key})"}:",
          default: "",
          mask: true,
          placeholder: is_new ? "required" : "leave blank to keep current"
        },
        {
          name: :model,
          label: "Model #{is_new && default_model ? "(default: #{default_model})" : (is_new ? "" : "(current: #{model["model"]})")}:",
          default: default_model || "",
          placeholder: "model name"
        },
        {
          name: :base_url,
          label: "Base URL #{is_new && default_base_url ? "(default: #{default_base_url})" : (is_new ? "" : "(current: #{model["base_url"]})")}:",
          default: default_base_url || "",
          placeholder: "https://..."
        }
      ]

      title = if is_new && selected_provider && selected_provider != "custom"
                provider_name = Clacky::Providers.get(selected_provider)&.dig("name") || selected_provider
                "Add #{provider_name} Model"
              elsif is_new
                "Add Custom Model"
              else
                "Edit Model"
              end

      loop do
        result = show_form_dialog(title: title, fields: fields)
        return nil if result.nil?

        values = merge_model_form_values(
          result,
          model: model,
          default_model: default_model,
          default_base_url: default_base_url
        )

        validation = validate_model_form(values, is_new: is_new, existing_model: model, test_callback: test_callback)
        if validation[:success]
          return values.merge(provider: selected_provider)
        end

        show_warning(validation[:error])
        fields.each { |field| field[:default] = result[field[:name]].to_s }
      end
    end

    def show_provider_selection
      choices = Clacky::Providers.list.map { |id, name| { label: name, value: id } }
      choices << { label: "─" * 40, disabled: true }
      choices << { label: "Custom (manual configuration)", value: "custom" }
      show_menu_dialog(title: "Select Provider", choices: choices, selected_index: 0)
    end

    def merge_model_form_values(result, model:, default_model:, default_base_url:)
      {
        api_key: result[:api_key].to_s.empty? ? model["api_key"] : result[:api_key],
        model: result[:model].to_s.empty? ? (model["model"] || default_model) : result[:model],
        base_url: result[:base_url].to_s.empty? ? (model["base_url"] || default_base_url) : result[:base_url]
      }
    end

    def validate_model_form(values, is_new:, existing_model:, test_callback:)
      if is_new
        return { success: false, error: "API Key is required for new model" } if values[:api_key].to_s.empty?
        return { success: false, error: "Model name is required" } if values[:model].to_s.empty?
        return { success: false, error: "Base URL is required" } if values[:base_url].to_s.empty?
      end

      return { success: true } unless test_callback

      temp_config = Clacky::AgentConfig.new(
        models: [{
          "api_key" => values[:api_key],
          "model" => values[:model],
          "base_url" => values[:base_url],
          "anthropic_format" => existing_model["anthropic_format"]
        }],
        current_model_index: 0
      )
      test_callback.call(temp_config)
    end

    def format_args(args)
      data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args
      return data.to_s unless data.is_a?(Hash) && !data.empty?

      data.map { |k, v| "#{k}: #{format_tool_value(v)}" }.join("\n")
    end

    def format_tool_value(v)
      v.is_a?(String) ? v : JSON.generate(v)
    end

    def normalize_todo(todo)
      case todo
      when Hash
        title = todo[:content] || todo["content"] || todo[:title] || todo["title"] || todo[:task] || todo["task"]
        status = todo[:status] || todo["status"] || :pending
        { label: title.to_s, title: title.to_s, status: status.to_sym }
      else
        { label: todo.to_s, title: todo.to_s, status: :pending }
      end
    end

    def mask_api_key(api_key)
      key = api_key.to_s
      return "not set" if key.empty?

      "#{key[0..5]}...#{key[-4..]}"
    end

    private :track_tool_activity,
            :update_tool_activity,
            :refresh_sidebar_tasks,
            :reset_task_sidebar_tracking,
            :tool_activity_label,
            :normalize_tool_args,
            :compact_tool_arg,
            :tool_url_host,
            :truncate_tool_label,
            :escape_tool_label,
            :add_conversation_markdown,
            :stream_markdown?,
            :add_file_summary_after,
            :add_plain_block,
            :expand_ansi_multiline_spans,
            :extract_thinking_and_content,
            :stream_thinking_live,
            :parse_diff_stats,
            :normalize_markdown_for_terminal,
            :add_file_summary,
            :wire_shell_callbacks,
            :session_status,
            :run_callback_async,
            :render_welcome_banner,
            :terminal_width,
            :config_menu_choices,
            :config_initial_selection,
            :show_menu_dialog,
            :show_form_dialog,
            :show_blocking_dialog,
            :show_model_edit_form,
            :show_provider_selection,
            :merge_model_form_values,
            :validate_model_form,
             :format_args,
             :format_tool_value,
             :tool_output_text,
             :normalize_todo,
             :mask_api_key,
             :parse_tool_info,
             :tool_risk_level,
             :tool_category,
             :build_fingerprint,
             :show_model_switch_dialog

  end
end
