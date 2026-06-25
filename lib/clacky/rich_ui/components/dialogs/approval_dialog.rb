# frozen_string_literal: true

require "ruby_rich"
require_relative "../base_component"

module Clacky
    module RichUI
      class ApprovalDialog
      include Clacky::RichUI::Components::BaseComponent

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

      private def wire_keys
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
    end
  end
end