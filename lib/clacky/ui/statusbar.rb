# frozen_string_literal: true

require "pastel"
require "tty-screen"

module Clacky
  module UI
    # Status bar showing session information
    class StatusBar
      def initialize
        @pastel = Pastel.new
      end

      # Display session status bar
      # @param working_dir [String] Current working directory
      # @param mode [String] Permission mode
      # @param model [String] AI model name
      # @param tasks [Integer] Number of completed tasks (optional)
      # @param cost [Float] Total cost (optional)
      def display(working_dir:, mode:, model:, tasks: nil, cost: nil)
        parts = []
        
        # Working directory (shortened if too long)
        dir_display = shorten_path(working_dir)
        parts << @pastel.bright_cyan(dir_display)
        
        # Permission mode
        mode_color = mode_color_for(mode)
        parts << @pastel.public_send(mode_color, mode)
        
        # Model
        parts << @pastel.bright_white(model)
        
        # Optional: tasks and cost
        if tasks
          parts << @pastel.yellow("#{tasks} tasks")
        end
        
        if cost
          parts << @pastel.yellow("$#{cost.round(4)}")
        end
        
        # Join with separator
        separator = @pastel.dim(" │ ")
        status_line = " " + parts.join(separator)
        
        puts status_line
      end

      # Display minimal status for non-interactive mode
      def display_minimal(working_dir:, mode:)
        dir_display = shorten_path(working_dir)
        puts " #{@pastel.bright_cyan(dir_display)} #{@pastel.dim('│')} #{@pastel.yellow(mode)}"
      end

      private

      def shorten_path(path)
        return path if path.length <= 40
        
        # Replace home directory with ~
        home = ENV['HOME']
        if home && path.start_with?(home)
          path = path.sub(home, '~')
        end
        
        # If still too long, show last parts
        if path.length > 40
          parts = path.split('/')
          if parts.length > 3
            ".../" + parts[-3..-1].join('/')
          else
            path[0..40] + "..."
          end
        else
          path
        end
      end

      def mode_color_for(mode)
        case mode.to_s
        when /auto_approve/
          :bright_red
        when /confirm_safes/
          :bright_yellow
        when /confirm_edits/
          :bright_green
        when /plan_only/
          :bright_blue
        else
          :white
        end
      end
    end
  end
end
