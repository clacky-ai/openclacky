# frozen_string_literal: true

require "ruby_rich"

module Clacky
  module RichUI
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
        clacky = @shell.clacky_controller
        return [""] unless clacky

        status = clacky.status || "idle"
        tasks = clacky.tasks_count || 0
        cost  = clacky.total_cost || 0.0
        turn  = clacky.turn_active
        ctrlc = clacky.ctrl_c_warning

        mode    = clacky.config&.dig(:mode) || "agent"
        model   = clacky.config&.dig(:model) || "—"
        latency = clacky.latest_latency
        model_str = latency ? "#{model} (#{latency})" : model
        meta_right = "#{mode} · #{model_str}"

        if ctrlc
          line = "#{theme.style("⏎", :error)} #{theme.style(ctrlc, :error)}"
        elsif turn
          @spinner_index = (@spinner_index + 1) % SPINNER.length
          spinner = theme.style(SPINNER[@spinner_index], :accent)
          label  = clacky.work_label || "working…"
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

      private def visible_len(text)
        text.to_s.gsub(/\e\[[0-9;:]*m/, "").length
      end
    end
  end
end
