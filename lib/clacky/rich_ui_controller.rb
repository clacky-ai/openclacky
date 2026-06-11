# frozen_string_literal: true

require "json"
require "uri"
require "base64"
require "set"
require_relative "ui_interface"
require_relative "providers"
require_relative "ui2/components/welcome_banner"

begin
  require "ruby_rich"
rescue LoadError
  require_relative "../../../ruby_rich/lib/ruby_rich"
end

module RubyRich
  class Viewport
    unless method_defined?(:clacky_handle_event_without_text_selection)
      alias_method :clacky_handle_event_without_text_selection, :handle_event

      def handle_event(event_data, layout = nil)
        return false if keyboard_event?(event_data) && !@focused

        case event_data[:name]
        when :mouse_down
          return copy_selection if event_data[:button] == :right

          start_scrollbar_drag(event_data, layout) || start_selection(event_data, layout)
        when :mouse_drag
          drag_scrollbar(event_data, layout) || drag_selection(event_data, layout)
        when :mouse_up
          stop_scrollbar_drag || clacky_stop_selection_without_copy
        else
          clacky_handle_event_without_text_selection(event_data, layout)
        end
      end

      def clacky_stop_selection_without_copy
        return false unless @selecting

        @selecting = false
        @selected_text = extract_selected_text
        true
      end

      def copy_to_clipboard(text)
        text = text.to_s
        return false if text.empty?
        return true if RubyRich::Terminal.windows? && clacky_try_windows_clipboard(text)

        clacky_clipboard_commands.each do |command|
          return true if clacky_write_clipboard_command(command, text)
        end

        clacky_copy_to_terminal_clipboard(text)
      end

      def copy_selection
        text = @selected_text.to_s
        return false if text.empty?

        copied = copy_to_clipboard(text)
        clacky_clear_selection if copied
        copied
      end

      def clacky_clear_selection
        @selecting = false
        @selection_start = nil
        @selection_end = nil
        @selected_text = ""
      end

      def apply_selection(line, absolute_line)
        range = normalized_selection
        return line unless range

        start_pos, end_pos = range
        return line if absolute_line < start_pos[:line] || absolute_line > end_pos[:line]

        start_col = absolute_line == start_pos[:line] ? start_pos[:col] : 0
        end_col = absolute_line == end_pos[:line] ? end_pos[:col] : display_width(strip_ansi(line).rstrip)
        end_col = [end_col, display_width(strip_ansi(line).rstrip)].min
        clacky_highlight_display_range(line, start_col, end_col)
      end

      def clacky_highlight_display_range(line, start_col, end_col)
        return line if end_col <= start_col

        result = +""
        width = 0
        active = false
        in_escape = false
        escape = +""

        line.each_char do |char|
          if in_escape
            escape << char
            if char == "m"
              result << escape
              result << AnsiCode.inverse if active
              escape = +""
              in_escape = false
            end
            next
          elsif char.ord == 27
            escape << char
            in_escape = true
            next
          end

          char_width = Unicode::DisplayWidth.of(char)
          should_highlight = width < end_col && width + char_width > start_col
          if should_highlight && !active
            result << AnsiCode.inverse
            active = true
          elsif !should_highlight && active
            result << AnsiCode.reset
            active = false
          end
          result << char
          width += char_width
        end
        result << AnsiCode.reset if active
        result
      end

      def clacky_clipboard_commands
        commands = []
        commands << ["wl-copy"] if ENV["WAYLAND_DISPLAY"]
        if ENV["DISPLAY"]
          commands << ["xclip", "-selection", "clipboard"]
          commands << ["xsel", "--clipboard", "--input"]
        end
        commands << ["pbcopy"] if RUBY_PLATFORM.match?(/darwin/)
        commands
      end

      def clacky_write_clipboard_command(command, text)
        IO.popen(command, "w") { |io| io.write(text) }
        $?&.success? == true
      rescue IOError, SystemCallError
        false
      end

      def clacky_try_windows_clipboard(text)
        copy_to_windows_clipboard(text)
        true
      rescue IOError, SystemCallError
        false
      end

      def clacky_copy_to_terminal_clipboard(text)
        encoded = Base64.strict_encode64(text.encode(Encoding::UTF_8))
        $stdout.print("\e]52;c;#{encoded}\a")
        $stdout.flush
        true
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError, IOError, SystemCallError
        false
      end

      private :clacky_stop_selection_without_copy,
              :copy_to_clipboard,
              :copy_selection,
              :clacky_clear_selection,
              :apply_selection,
              :clacky_highlight_display_range,
              :clacky_clipboard_commands,
              :clacky_write_clipboard_command,
              :clacky_try_windows_clipboard,
              :clacky_copy_to_terminal_clipboard
    end
  end

  class Transcript
    unless private_method_defined?(:clacky_render_entry_without_plain)
      alias_method :clacky_render_entry_without_plain, :render_entry

      def render_entry(entry, index)
        if entry.metadata[:plain]
          entry.content.to_s.split("\n", -1)
        else
          clacky_render_entry_without_plain(entry, index)
        end
      end

      private :render_entry
    end
  end

  class Markdown
    class TerminalRenderer
      unless method_defined?(:clacky_fit_table_rows)
        def table(header, body)
          all_rows = @table_state[:all_rows]
          reset_table_state
          return "" if all_rows.empty?

          header_line_count = [header.to_s.strip.split("\n").size, 1].max
          header_rows = all_rows[0...header_line_count]
          body_rows = all_rows[header_line_count..] || []

          return "" if header_rows.empty? || body_rows.empty?

          headers, fitted_body_rows = clacky_fit_table_rows(header_rows.last, body_rows)
          begin
            tbl = RubyRich::Table.new(headers: headers, border_style: @options[:table_border_style] || :simple)
            fitted_body_rows.each do |row|
              padded = row + Array.new([0, headers.length - row.length].max, "")
              tbl.add_row(padded[0...headers.length])
            end
            return "#{tbl.render}\n\n"
          rescue
            # fall through to the original plain fallback shape
          end

          result = "\n"
          result += "#{header.strip}\n"
          result += "#{"-" * [header.strip.length, 20].min}\n"
          result += "#{body.strip}\n" if body && !body.strip.empty?
          "#{result}\n"
        end

        def clacky_fit_table_rows(header_row, body_rows)
          column_count = [header_row.length, *body_rows.map(&:length)].max.to_i
          normalized_header = header_row + Array.new([0, column_count - header_row.length].max, "")
          normalized_body = body_rows.map { |row| row + Array.new([0, column_count - row.length].max, "") }
          natural_widths = clacky_table_natural_widths(normalized_header, normalized_body)
          column_widths = clacky_constrain_table_widths(natural_widths)

          headers = normalized_header.each_with_index.map { |cell, index| clacky_wrap_table_cell(clacky_table_cell_text(cell), column_widths[index]) }
          rows = normalized_body.map do |row|
            row.each_with_index.map { |cell, index| clacky_wrap_table_cell(clacky_table_cell_text(cell), column_widths[index]) }
          end

          [headers, rows]
        end

        def clacky_table_natural_widths(header_row, body_rows)
          rows = [header_row] + body_rows
          rows.transpose.map do |cells|
            cells.map { |cell| clacky_visible_width(clacky_table_cell_text(cell)) }.max.to_i
          end
        end

        def clacky_table_cell_text(cell)
          process_inline(cell).to_s.gsub(/\e\[[0-9;:]*m/, "")
        end

        def clacky_constrain_table_widths(natural_widths)
          return natural_widths if natural_widths.empty?

          border_overhead = (natural_widths.length * 3) + 1
          max_table_width = [[@options[:width].to_i - 1, 20].max, border_overhead + natural_widths.length].max
          available_content_width = [max_table_width - border_overhead, natural_widths.length].max
          widths = natural_widths.map { |width| [width, 1].max }
          return widths if widths.sum <= available_content_width

          min_width = available_content_width < natural_widths.length * 3 ? 1 : 3
          while widths.sum > available_content_width
            index = widths.each_with_index.select { |width, _| width > min_width }.max_by(&:first)&.last
            break unless index

            widths[index] -= 1
          end
          widths
        end

        def clacky_wrap_table_cell(text, width)
          width = [width.to_i, 1].max
          text.to_s.split("\n", -1).flat_map do |line|
            clacky_wrap_table_line(line, width)
          end.join("\n")
        end

        def clacky_wrap_table_line(line, width)
          return [""] if line.empty?

          lines = []
          current = +""
          current_width = 0
          in_escape = false
          escape = +""

          line.each_char do |char|
            if in_escape
              escape << char
              if char == "m"
                current << escape
                escape = +""
                in_escape = false
              end
              next
            elsif char.ord == 27
              escape << char
              in_escape = true
              next
            end

            char_width = Unicode::DisplayWidth.of(char)
            if current_width.positive? && current_width + char_width > width
              lines << current
              current = +""
              current_width = 0
            end
            current << char
            current_width += char_width
          end

          lines << current unless current.empty?
          lines.empty? ? [""] : lines
        end

        def clacky_visible_width(text)
          text.to_s.gsub(/\e\[[0-9;:]*m/, "").split("\n").map(&:display_width).max.to_i
        end
      end
    end
  end

end

module Clacky
  # ── Sidebar panels ──────────────────────────────────────────

  class RichWorkPanel
    attr_accessor :width, :height

    def initialize
      @plan = ""
      @activities = []
      @tasks = 0
      @cost = 0.0
    end

    def update_plan(text)
      @plan = text.to_s
    end

    def update_activities(activities)
      @activities = Array(activities).last(8)
    end

    def update_stats(tasks, cost)
      @tasks = tasks.to_i
      @cost = cost.to_f
    end

    def render
      lines = []
      lines << @plan unless @plan.empty?
      unless @activities.empty?
        lines << "" unless lines.empty?
        @activities.each do |a|
          marker = status_marker(a[:status] || :pending)
          lines << "#{marker} #{a[:label]}"
        end
      end
      lines << "" unless lines.empty?
      lines << muted("#{@tasks} tasks · $#{@cost.round(4)}")
      lines.join("\n")
    end

    private

    def status_marker(status)
      case status
      when :done, :completed
        "#{RubyRich::AnsiCode.color(:green, true)}✓#{RubyRich::AnsiCode.reset}"
      when :running, :in_progress, :active
        "#{RubyRich::AnsiCode.color(:blue, true)}●#{RubyRich::AnsiCode.reset}"
      when :failed, :error
        "#{RubyRich::AnsiCode.color(:red, true)}!#{RubyRich::AnsiCode.reset}"
      else
        "#{RubyRich::AnsiCode.color(:black, true)}○#{RubyRich::AnsiCode.reset}"
      end
    end

    def muted(text)
      "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
    end
  end

  class RichTasksPanel
    attr_accessor :width, :height

    def initialize
      @tasks = []
    end

    def set_tasks(tasks)
      @tasks = Array(tasks)
    end

    def render
      return muted("No active tasks") if @tasks.empty?

      lines = []
      done_count = 0
      total = @tasks.length
      @tasks.each do |task|
        label = task_label(task)
        status = task_status(task)
        done_count += 1 if %i[done completed].include?(status)
        lines << "#{status_marker(status)} #{label}"
      end
      lines << "" unless lines.empty?
      lines << muted("#{done_count}/#{total} done")
      lines.join("\n")
    end

    private

    def task_label(task)
      case task
      when Hash
        (task[:label] || task["label"] || task[:title] || task["title"] ||
         task[:content] || task["content"] || task[:task] || task["task"]).to_s
      else
        task.to_s
      end
    end

    def task_status(task)
      case task
      when Hash then (task[:status] || task["status"] || :pending).to_sym
      else :pending
      end
    end

    def status_marker(status)
      case status
      when :done, :completed
        "#{RubyRich::AnsiCode.color(:green, true)}✓#{RubyRich::AnsiCode.reset}"
      when :running, :in_progress
        "#{RubyRich::AnsiCode.color(:blue, true)}●#{RubyRich::AnsiCode.reset}"
      when :failed, :error
        "#{RubyRich::AnsiCode.color(:red, true)}!#{RubyRich::AnsiCode.reset}"
      else
        "#{RubyRich::AnsiCode.color(:black, true)}○#{RubyRich::AnsiCode.reset}"
      end
    end

    def muted(text)
      "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
    end
  end

  class RichContextPanel
    attr_accessor :width, :height

    def initialize
      @token_usage = nil
    end

    def update_tokens(data)
      @token_usage = data
    end

    def render
      return muted("No token data") unless @token_usage

      input  = @token_usage[:prompt_tokens] || @token_usage[:input]  || 0
      output = @token_usage[:completion_tokens] || @token_usage[:output] || 0
      total  = @token_usage[:total_tokens] || @token_usage[:total] || (input + output)
      cost   = @token_usage[:cost]

      lines = []
      lines << "#{muted("prompt:")}   #{input} tok"
      lines << "#{muted("output:")}  #{output} tok"
      lines << "#{muted("total:")}   #{total} tok"
      if cost
        lines << ""
        lines << "#{muted("cost:")}    $#{cost.round(4)}"
      end
      lines.join("\n")
    end

    private

    def muted(text)
      "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
    end
  end

  # ── RichSidebar ─────────────────────────────────────────────

  class RichSidebar
    MODES = %i[work tasks context auto hidden].freeze
    PANEL_HEIGHT_RATIOS = { 1 => [1.0], 2 => [0.5, 0.5], 3 => [0.34, 0.33, 0.33] }.freeze
    PANEL_NAMES = { work: "Work", tasks: "Tasks", context: "Context" }.freeze

    attr_accessor :width, :height
    attr_reader :mode

    def initialize
      @mode = :auto
      @panels = {
        work: RichWorkPanel.new,
        tasks: RichTasksPanel.new,
        context: RichContextPanel.new
      }
      @width = 0
      @height = 0
    end

    def update_plan(text)
      @panels[:work].update_plan(text)
      self
    end

    def set_tasks(tasks)
      @panels[:tasks].set_tasks(tasks)
      self
    end

    def update_context(token_data)
      @panels[:context].update_tokens(token_data)
      self
    end

    def update_work_activities(activities)
      @panels[:work].update_activities(activities)
      self
    end

    def update_work_stats(tasks, cost)
      @panels[:work].update_stats(tasks, cost)
    end

    def set_mode(mode)
      @mode = MODES.include?(mode) ? mode : :auto
    end

    def render
      visible = visible_panels
      return [""] if visible.empty?

      heights = panel_heights(visible)
      panel_lines = visible.each_with_index.flat_map do |key, i|
        panel = @panels[key]
        panel.width = [@width - 2, 1].max
        panel.height = heights[i]
        p = RubyRich::Panel.new(panel.render, title: PANEL_NAMES[key], border_style: :blue, title_align: :left)
        p.width = @width
        p.height = heights[i]
        p.render
      end
      panel_lines.first(@height)
    end

    private

    def visible_panels
      case @mode
      when :work then [:work]
      when :tasks then [:tasks]
      when :context then [:context]
      when :hidden then []
      when :auto
        @panels.select { |_key, panel| panel_has_content?(panel) }.keys
      else
        []
      end
    end

    def panel_heights(visible)
      max_h = [@height, 1].max
      # Context panel gets exactly 6 lines; remaining space split among others
      ctx_idx = visible.index(:context)
      if ctx_idx
        ctx_h = [6, max_h / [visible.length, 1].max].min
        other_count = visible.length - 1
        other_h = other_count > 0 ? (max_h - ctx_h) / other_count : 0
        visible.each_with_index.map { |_, i| i == ctx_idx ? ctx_h : [other_h, 1].max }
      else
        h = max_h / visible.length
        visible.map { [h, 1].max }
      end
    end

    def panel_has_content?(panel)
      case panel
      when RichWorkPanel
        true  # Always show — shows "0 tasks · $0.0000" when empty
      when RichTasksPanel
        !panel.instance_variable_get(:@tasks).empty?
      when RichContextPanel
        true  # Always show — shows "No token data" when empty
      else
        false
      end
    end
  end

  # Fixed 6-line thinking area between transcript and composer.
  # Shows a spinner + elapsed time during thinking, streams content live.
  class ThinkingLiveView
    SPINNER = ['|', '/', '-', '\\'].freeze

    attr_accessor :width, :height

    def initialize(shell)
      @shell = shell
      @status = :idle     # :idle, :thinking, :done
      @text = +""
      @start_time = nil
      @spinner_index = 0
      @width = 0
      @height = 0
    end

    def desired_height
      @status == :idle ? 0 : 6
    end

    def start_thinking
      @status = :thinking
      @start_time = Time.now
      @text = +""
      @shell.live&.refresh
    end

    def append_text(delta)
      @text << delta.to_s
      @shell.live&.refresh
    end

    def finish_thinking
      @status = :done
      @shell.live&.refresh
    end

    def idle!
      @status = :idle
      @text = +""
      @start_time = nil
      @shell.live&.refresh
    end

    def render
      theme = @shell.theme
      case @status
      when :idle
        [""]
      when :thinking
        elapsed = @start_time ? (Time.now - @start_time).round(1) : 0.0
        @spinner_index = (@spinner_index + 1) % SPINNER.length
        spinner = theme.style(SPINNER[@spinner_index], :thinking)
        time_str = theme.style("#{elapsed}s", :accent)
        header = " #{spinner} #{theme.style("Thinking", :thinking)}  #{time_str}"
        lines = [header]
        visible = @text.to_s.split("\n").last(5)
        visible.each { |l| lines << "  #{theme.style(l, :thinking)}" }
        (5 - visible.length).times { lines << "" }
        lines
      when :done
        elapsed = @start_time ? (Time.now - @start_time).round(1) : 0.0
        header = " #{theme.style("Thinking done", :thinking)}  #{theme.style("#{elapsed}s", :accent)}"
        lines = [header]
        visible = @text.to_s.split("\n").last(4)
        visible.each { |l| lines << "  #{theme.style(l, :muted)}" }
        (4 - visible.length).times { lines << "" }
        lines
      end
    end
  end

  # Enhanced status bar with spinner, work labels, and Ctrl+C hint.
  class RichStatusView
    SPINNER = ['|', '/', '-', '\\'].freeze

    attr_accessor :width, :height

    def initialize(shell)
      @shell = shell
      @spinner_index = 0
      @width = 0
      @height = 1
    end

    def render
      theme = @shell.theme
      clacky = @shell.instance_variable_get(:@clacky_controller)
      return [""] unless clacky

      status = clacky.instance_variable_get(:@status) || "idle"
      tasks = clacky.instance_variable_get(:@tasks_count) || 0
      cost  = clacky.instance_variable_get(:@total_cost) || 0.0
      turn  = clacky.instance_variable_get(:@turn_active)
      ctrlc = clacky.instance_variable_get(:@ctrl_c_warning)

      mode    = clacky.instance_variable_get(:@config)&.dig(:mode) || "agent"
      model   = clacky.instance_variable_get(:@config)&.dig(:model) || "—"
      latency = clacky.instance_variable_get(:@latest_latency)
      model_str = latency ? "#{model} (#{latency})" : model
      meta_right = "#{mode} · #{model_str}"

      if ctrlc
        line = "#{theme.style("⏎", :error)} #{theme.style(ctrlc, :error)}"
      elsif turn
        @spinner_index = (@spinner_index + 1) % SPINNER.length
        spinner = theme.style(SPINNER[@spinner_index], :accent)
        label  = clacky.instance_variable_get(:@work_label) || "working…"
        right  = "#{meta_right} · #{tasks} tasks · $#{cost.round(4)}"
        left   = "#{spinner} #{theme.style(label, :body)}"
      else
        right = "#{meta_right} · #{tasks} tasks · $#{cost.round(4)} · Ctrl+C quit"
        left  = theme.style(status || "idle", :accent)
      end
      space = [@width - visible_len(left) - visible_len(right) - 2, 1].max
      line  = "#{left}#{" " * space}#{theme.style(right, :muted)}"
      [line]
    end

    private

    def visible_len(text)
      text.to_s.gsub(/\e\[[0-9;:]*m/, "").length
    end
  end

  class RichAgentShell < RubyRich::AgentShell
    attr_reader :thinking_live, :sidebar

    def build_layout
      @sidebar = RichSidebar.new
      @thinking_live = ThinkingLiveView.new(self)
      @viewport.instance_variable_set(:@scrollbar, false)
      root = RubyRich::Layout.new(name: :root)
      root.split_column(
        RubyRich::Layout.new(name: :header, size: 1),
        RubyRich::Layout.new(name: :body, ratio: 1),
        RubyRich::Layout.new(name: :composer, size: 6),
        RubyRich::Layout.new(name: :status, size: 1)
      )

      main_area = RubyRich::Layout.new(name: :main, ratio: 1)
      main_area.split_column(
        RubyRich::Layout.new(name: :transcript, ratio: 1),
        RubyRich::Layout.new(name: :thinking_live, size: 0)
      )

      root[:body].split_row(
        main_area,
        RubyRich::Layout.new(name: :todos, size: 36)
      )

      root[:header].content = RubyRich::AppShell::HeaderView.new(self)
      root[:transcript].content = @viewport
      root[:todos].content = @sidebar
      root[:thinking_live].content = @thinking_live
      root[:composer].content = RubyRich::AppShell::FramedView.new(@composer, title: "Composer", theme: @theme) { @composer.focused? }
      root[:status].content = RichStatusView.new(self)
      root
    end

    def attach_components
      @viewport.attach(@layout[:transcript])
      @transcript.attach(@layout[:transcript])
      @composer.focus.attach(@layout[:composer])

      @focus_manager
        .register(:transcript, @layout[:transcript], RubyRich::AppShell::FocusTarget.new(@transcript, @viewport))
        .register(:composer, @layout[:composer], @composer)
        .attach(@layout)
      @focus_manager.focus(:composer)

      @layout.key(:ctrl_c, 1_000) do |_event, live|
        live.stop if @stop_on_ctrl_c != false
        false
      end
    end

    def attach_agent_controls
      @composer.instance_variable_set(:@on_interrupt, nil)
      # Register /model command
      shell_ref = self
      @composer.register_command(name: "/model", description: "Switch LLM model",
        handler: -> { shell_ref.instance_variable_get(:@callbacks)[:model_switch]&.call })
      # Wire vim scroll callback: j/k in single-line normal mode scrolls transcript
      @composer.instance_variable_set(:@on_vim_scroll, ->(delta) { @viewport.scroll_by(delta) })
      # Inject Esc cancellation stack via singleton method on the Composer instance.
      # This avoids both the Layout @event_intercepted bug and monkey-patch complexity.
      native_escape = @composer.method(:escape)
      shell = self
      @composer.define_singleton_method(:escape) do
        handled = shell.instance_variable_get(:@callbacks)[:esc]&.call || false
        handled ? nil : native_escape.call
      end
      # Clear Ctrl+C warning as soon as the user starts typing
      native_insert = @composer.method(:insert_text)
      @composer.define_singleton_method(:insert_text) do |text|
        shell.instance_variable_get(:@callbacks)[:clear_ctrlc]&.call
        native_insert.call(text)
      end

      @layout.key(:ctrl_c, 2_000) do |_event, live|
        handle_interrupt(live, self)
        false
      end

      @layout.key(:ctrl_m, 2_000) do |_event, _live|
        toggle_permission_mode
        false
      end

      # Tab toggles permission mode (overrides FocusManager's focus cycling)
      @layout.key(:tab, 600) do |_event, _live|
        toggle_permission_mode
        false
      end
      # Re-focus composer AFTER FocusManager (priority 500) has cycled focus.
      # Also suppress Composer's own tab handler (priority 200) which would
      # otherwise fire open_menu_if_available.
      @layout.key(:tab, 100) do |_event, _live|
        @composer.instance_variable_set(:@ignore_next_tab, true)
        @focus_manager.focus(:composer)
        false
      end

      # Sidebar panel shortcuts (F1-F4)
      @layout.key(:f1, 1_500) do |_event, _live|
        @sidebar.set_mode(:work)
        false
      end
      @layout.key(:f2, 1_500) do |_event, _live|
        @sidebar.set_mode(:tasks)
        false
      end
      @layout.key(:f3, 1_500) do |_event, _live|
        @sidebar.set_mode(:auto)
        false
      end
      @layout.key(:f4, 1_500) do |_event, _live|
        @sidebar.set_mode(:context)
        false
      end
    end

    def handle_interrupt(_live = nil, _source = nil)
      input_was_empty = @composer.value.to_s.empty?
      @callbacks[:interrupt]&.call(input_was_empty: input_was_empty)
      false
    end

    def toggle_permission_mode
      current = @callbacks[:mode_toggle] ? @mode : :confirm_safes
      # Toggle between confirm_safes and confirm_all
      new_mode = current.to_s == "confirm_all" ? "confirm_safes" : "confirm_all"
      @mode = new_mode.to_sym
      @callbacks[:mode_toggle]&.call(@mode)
      @status = "mode · #{@mode}"
      @focus_manager.focus(:composer)
    end

    def on_esc(&block)
      @callbacks[:esc] = block
      self
    end

    private :build_layout,
            :attach_components,
            :attach_agent_controls,
            :handle_interrupt
  end

  # Experimental RubyRich-backed TUI controller.
  #
  # This intentionally implements the same surface as UI2::UIController so the
  # CLI/Agent loop can switch implementations without knowing which TUI is
  # underneath. It is not the default UI yet.
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
        theme: RubyRich::Theme.whale_dark,
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

    class LayoutAdapter
      def initialize(shell)
        @shell = shell
      end

      def clear_output
        @shell.transcript.store.entries.clear
        @shell.viewport.scroll_to_bottom
      end
    end

    class ProgressHandleAdapter
      def initialize(handle)
        @handle = handle
      end

      def update(message: nil, metadata: nil)
        _ = metadata
        @handle.update(message.to_s) if message
      end

      def finish(final_message: nil)
        final_message ? @handle.finish(final_message.to_s) : @handle.finish
      end

      def cancel
        @handle.cancel
      end
    end

    class ConfigMenuDialog
      attr_accessor :width, :height

      def initialize(choices:, selected_index: 0, title: "Model Configuration", width: 86)
        @choices = choices
        @selected_index = selected_index
        @width = width
        @height = [choices.length + 7, 12].max
        @event_listeners = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @finished = false
        @result = nil
        @panel = RubyRich::Panel.new("", title: title, border_style: :cyan, title_align: :center)
        @layout = RubyRich::Layout.new(name: :config_dialog, width: @width, height: @height)
        @layout.update_content(@panel)
        @layout.calculate_dimensions(@width, @height)
      end

      def selected_choice
        @choices[@selected_index]
      end

      def move_up
        move(-1)
      end

      def move_down
        move(1)
      end

      def finish(value)
        @mutex.synchronize do
          @result = value
          @finished = true
          @condition.signal
        end
        true
      end

      def wait
        @mutex.synchronize { @condition.wait(@mutex) until @finished }
        @result
      end

      def key(event_name, priority = 0, &block)
        @event_listeners[event_name] ||= []
        @event_listeners[event_name] << { priority: priority, block: block }
        @event_listeners[event_name].sort_by! { |listener| -listener[:priority] }
      end

      def notify_listeners(event_data)
        Array(@event_listeners[event_data[:name]]).each { |listener| listener[:block].call(event_data, nil) }
      end

      def render_to_buffer
        @panel.content = render_content
        @layout.calculate_dimensions(@width, @height)
        @layout.render_to_buffer
      end

      def move(delta)
        return if @choices.empty?

        index = @selected_index
        loop do
          index = (index + delta) % @choices.length
          break unless @choices[index][:disabled]
          break if index == @selected_index
        end
        @selected_index = index
      end

      def render_content
        lines = [""]
        @choices.each_with_index do |choice, index|
          lines << choice_line(choice, selected: index == @selected_index)
        end
        lines << ""
        lines << "#{muted("↑↓/jk: Navigate")} • #{muted("Enter: Select")} • #{muted("Esc/q: Cancel")}"
        lines.join("\n")
      end

      def choice_line(choice, selected:)
        return "  #{muted(choice[:label])}" if choice[:disabled]

        prefix = selected ? "#{RubyRich::AnsiCode.color(:cyan, true)}➜#{RubyRich::AnsiCode.reset} " : "  "
        label = selected ? RubyRich::AnsiCode.color(:white, true) + choice[:label] + RubyRich::AnsiCode.reset : choice[:label]
        "#{prefix}#{label}"
      end

      def muted(text)
        "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end

      private :move,
              :render_content,
              :choice_line,
              :muted
    end

    class FormDialog
      attr_accessor :width, :height

      def initialize(title:, fields:, width: 92)
        @title = title
        @fields = fields
        @field_index = 0
        @editors = fields.map do |field|
          RubyRich::LineEditor.new.tap { |editor| editor.value = field[:default].to_s }
        end
        @width = width
        @height = [fields.length * 3 + 8, 16].max
        @event_listeners = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @finished = false
        @result = nil
        @panel = RubyRich::Panel.new("", title: title, border_style: :cyan, title_align: :center)
        @layout = RubyRich::Layout.new(name: :form_dialog, width: @width, height: @height)
        @layout.update_content(@panel)
        @layout.calculate_dimensions(@width, @height)
        wire_default_keys
      end

      def finish(value)
        @mutex.synchronize do
          @result = value
          @finished = true
          @condition.signal
        end
        true
      end

      def wait
        @mutex.synchronize { @condition.wait(@mutex) until @finished }
        @result
      end

      def key(event_name, priority = 0, &block)
        @event_listeners[event_name] ||= []
        @event_listeners[event_name] << { priority: priority, block: block }
        @event_listeners[event_name].sort_by! { |listener| -listener[:priority] }
      end

      def notify_listeners(event_data)
        listeners = Array(@event_listeners[event_data[:name]])
        listeners.each { |listener| listener[:block].call(event_data, nil) }
      end

      def render_to_buffer
        @panel.content = render_content
        @layout.calculate_dimensions(@width, @height)
        @layout.render_to_buffer
      end

      def wire_default_keys
        key(:string, 100) { |event, _live| current_editor.insert(event[:value]); true }
        key(:paste, 100) { |event, _live| current_editor.insert(event[:value]); true }
        key(:backspace, 100) { current_editor.backspace; true }
        key(:delete, 100) { current_editor.delete; true }
        key(:left, 100) { current_editor.move_left; true }
        key(:right, 100) { current_editor.move_right; true }
        key(:ctrl_a, 100) { current_editor.buffer_start; true }
        key(:ctrl_e, 100) { current_editor.buffer_end; true }
        key(:up, 100) { move_field(-1); true }
        key(:down, 100) { move_field(1); true }
        key(:tab, 100) { move_field(1); true }
        key(:shift_tab, 100) { move_field(-1); true }
        key(:enter, 100) { finish(values); true }
      end

      def current_editor
        @editors[@field_index]
      end

      def move_field(delta)
        @field_index = (@field_index + delta) % @fields.length
      end

      def values
        @fields.each_with_index.to_h { |field, index| [field[:name].to_sym, @editors[index].value] }
      end

      def render_content
        lines = [""]
        @fields.each_with_index do |field, index|
          focused = index == @field_index
          marker = focused ? "#{RubyRich::AnsiCode.color(:cyan, true)}➜#{RubyRich::AnsiCode.reset}" : " "
          label = focused ? "#{RubyRich::AnsiCode.color(:white, true)}#{field[:label]}#{RubyRich::AnsiCode.reset}" : field[:label]
          lines << "#{marker} #{label}"
          lines << "  #{render_field_value(field, @editors[index], focused: focused)}"
          lines << ""
        end
        lines << "#{muted("Tab/↑↓: Field")} • #{muted("Enter: Save")} • #{muted("Esc: Cancel")}"
        lines.join("\n")
      end

      def render_field_value(field, editor, focused:)
        raw = editor.value
        text = if field[:mask] && !raw.empty?
                 "*" * raw.length
               elsif raw.empty?
                 field[:placeholder].to_s
               else
                 raw
               end
        color = raw.empty? ? :black : (focused ? :cyan : :white)
        "#{RubyRich::AnsiCode.color(color, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end

      def muted(text)
        "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end

      private :wire_default_keys,
              :current_editor,
              :move_field,
              :values,
              :render_content,
              :render_field_value,
              :muted
    end

    class ApprovalDialog
      RISK_LEVELS = {
        low:      { label: "Low",      color: :green,  bar: "●○○○" },
        medium:   { label: "Medium",   color: :yellow, bar: "●●○○" },
        high:     { label: "High",     color: :yellow, bar: "●●●○" },
        critical: { label: "Critical", color: :red,    bar: "●●●●" }
      }.freeze

      CATEGORY_COLORS = {
        file: :blue, shell: :yellow, network: :cyan, paid: :magenta
      }.freeze

      CHOICES = [
        { key: :approve,       label: "Approve",       color: :green  },
        { key: :deny,          label: "Deny",           color: :red    },
        { key: :always_allow,  label: "Always allow",   color: :cyan   }
      ].freeze

      attr_accessor :width, :height

      def initialize(tool_name:, message:, params: {}, risk: :medium, category: :file)
        @tool_name = tool_name
        @message = message
        @params = params
        @risk = RISK_LEVELS[risk] || RISK_LEVELS[:medium]
        @category = category
        @category_color = CATEGORY_COLORS[category] || :blue
        @selected_index = 0
        @width = 72
        @height = [params.length + 10, 12].max
        @event_listeners = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @finished = false
        @result = nil
        @panel = RubyRich::Panel.new("", title: "Approval", border_style: @risk[:color], title_align: :center)
        @layout = RubyRich::Layout.new(name: :approval_dialog, width: @width, height: @height)
        @layout.update_content(@panel)
        @layout.calculate_dimensions(@width, @height)
        wire_keys
      end

      def finish(value)
        @mutex.synchronize do
          @result = value
          @finished = true
          @condition.signal
        end
        true
      end

      def wait
        @mutex.synchronize { @condition.wait(@mutex) until @finished }
        @result
      end

      def key(event_name, priority = 0, &block)
        @event_listeners[event_name] ||= []
        @event_listeners[event_name] << { priority: priority, block: block }
        @event_listeners[event_name].sort_by! { |l| -l[:priority] }
      end

      def notify_listeners(event_data)
        Array(@event_listeners[event_data[:name]]).each { |l| l[:block].call(event_data, nil) }
      end

      def render_to_buffer
        @panel.content = render_content
        @layout.calculate_dimensions(@width, @height)
        @layout.render_to_buffer
      end

      private

      def wire_keys
        key(:left,  100) { move_selection(-1); true }
        key(:right, 100) { move_selection(1);  true }
        key(:string, 100) do |event, _live|
          case event[:value]
          when "h" then move_selection(-1)
          when "l" then move_selection(1)
          end
          true
        end
        key(:enter, 100) do
          sel = CHOICES[@selected_index]
          finish(sel ? sel[:key] : :deny)
        end
        key(:escape, 100) { finish(:deny) }
        key(:ctrl_c, 100) { finish(:deny) }
      end

      def move_selection(delta)
        @selected_index = (@selected_index + delta) % CHOICES.length
      end

      def render_content
        risk = @risk
        lines = []
        lines << ""
        lines << "  #{colored("Tool:",  :body)}  #{colored(@tool_name, :accent)}  #{category_badge}"
        lines << "  #{colored("Risk:",  :body)}  #{colored(risk[:label], risk[:color])} #{colored(risk[:bar], risk[:color])}"
        lines << "  #{colored("Info:",  :body)}  #{colored(@message, :body)}"

        unless @params.empty?
          lines << ""
          @params.each do |key, value|
            val = value.to_s
            val = "#{val[0..50]}..." if val.length > 54
            lines << "  #{muted("#{key}:")}  #{colored(val, :body)}"
          end
        end

        lines << ""
        lines << render_choices
        lines << ""
        lines.join("\n")
      end

      def render_choices
        CHOICES.each_with_index.map do |choice, i|
          selected = i == @selected_index
          prefix = selected ? "#{RubyRich::AnsiCode.color(:cyan, true)}➜#{RubyRich::AnsiCode.reset}" : " "
          label = selected ? colored(choice[:label], choice[:color]) : muted(choice[:label])
          "#{prefix} [#{label}]"
        end.join("  ")
      end

      def category_badge
        label = @category.to_s.capitalize
        colored("[#{label}]", @category_color)
      end

      def colored(text, color)
        "#{RubyRich::AnsiCode.color(color, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end

      def muted(text)
        "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end
    end
  end
end
