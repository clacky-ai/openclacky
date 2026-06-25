# frozen_string_literal: true

require "ruby_rich"
require_relative "../base_component"

module Clacky
    module RichUI
      class ConfigMenuDialog
      include Clacky::RichUI::Components::BaseComponent

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

      private :move,
              :render_content,
              :choice_line
    end
  end
end