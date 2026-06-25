# frozen_string_literal: true

require "ruby_rich"
require_relative "sidebar_panels"

module Clacky
  module RichUI
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

      # Returns the tasks list from the tasks panel (for tests/assertions)
      def tasks
        @panels[:tasks].instance_variable_get(:@tasks)
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

      private def visible_panels
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
          panel.has_tasks?
        when RichContextPanel
          true  # Always show — shows "No token data" when empty
        else
          false
        end
      end
    end
  end
end
