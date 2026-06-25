# frozen_string_literal: true

require "ruby_rich"

module Clacky
  module RichUI
    class ThinkingLiveView
      SPINNER = ['|', '/', '-', '\\'].freeze

      attr_accessor :width, :height
      attr_reader :start_time

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
  end
end
