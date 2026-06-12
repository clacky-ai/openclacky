# frozen_string_literal: true

require "ruby_rich"
require_relative "../base_component"

module Clacky
    module RichUI
      class FormDialog
      include Clacky::RichUI::Components::BaseComponent

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

      private :wire_default_keys,
              :current_editor,
              :move_field,
              :values,
              :render_content,
              :render_field_value
    end
  end
end