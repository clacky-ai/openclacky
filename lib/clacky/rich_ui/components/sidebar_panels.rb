# frozen_string_literal: true

require "ruby_rich"
require_relative "base_component"

module Clacky
  module RichUI
    class RichWorkPanel
      include Components::BaseComponent

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
    end

    class RichTasksPanel
      include Components::BaseComponent

      attr_accessor :width, :height

      def initialize
        @tasks = []
      end

      def set_tasks(tasks)
        @tasks = Array(tasks)
      end

      def has_tasks?
        !@tasks.empty?
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

      private def task_label(task)
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
    end

    class RichContextPanel
      include Components::BaseComponent

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
    end
  end
end
