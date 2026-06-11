# frozen_string_literal: true

require "ruby_rich"
require_relative "../components/sidebar"
require_relative "../components/thinking_live_view"
require_relative "../components/status_view"

module Clacky
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
end
