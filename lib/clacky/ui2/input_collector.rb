# frozen_string_literal: true

require "tty-prompt"

module Clacky
  module UI2
    # InputCollector provides a unified interface for collecting user input
    # Can work with UI2 system or fallback to traditional prompts
    class InputCollector
      def initialize(ui_controller: nil)
        @ui_controller = ui_controller
        @prompt = TTY::Prompt.new
      end

      # Collect text input from user
      # @param message [String] Prompt message
      # @param default [String, nil] Default value
      # @return [String] User input
      def text_input(message, default: nil)
        if @ui_controller
          # Use UI2 system
          collect_via_ui(message, default: default)
        else
          # Fallback to TTY::Prompt
          @prompt.ask(message, default: default)
        end
      end

      # Collect confirmation (yes/no) from user
      # @param message [String] Prompt message
      # @param default [Boolean] Default value
      # @return [Boolean] User confirmation
      def confirm_input(message, default: false)
        if @ui_controller
          # Use UI2 system
          collect_confirmation_via_ui(message, default: default)
        else
          # Fallback to TTY::Prompt
          @prompt.yes?(message, default: default)
        end
      end

      # Collect selection from a list
      # @param message [String] Prompt message
      # @param choices [Array] Array of choices
      # @param default [Object, nil] Default selection
      # @return [Object] Selected choice
      def select_input(message, choices, default: nil)
        if @ui_controller
          # Use UI2 system
          collect_selection_via_ui(message, choices, default: default)
        else
          # Fallback to TTY::Prompt
          @prompt.select(message, choices, default: default)
        end
      end

      # Collect multi-selection from a list
      # @param message [String] Prompt message
      # @param choices [Array] Array of choices
      # @return [Array] Selected choices
      def multi_select_input(message, choices)
        if @ui_controller
          # Use UI2 system
          collect_multi_selection_via_ui(message, choices)
        else
          # Fallback to TTY::Prompt
          @prompt.multi_select(message, choices)
        end
      end

      # Collect masked input (password)
      # @param message [String] Prompt message
      # @return [String] User input
      def masked_input(message)
        if @ui_controller
          # Use UI2 system (without echo)
          collect_masked_via_ui(message)
        else
          # Fallback to TTY::Prompt
          @prompt.mask(message)
        end
      end

      private

      # Collect text input via UI2 controller
      # @param message [String] Prompt message
      # @param default [String, nil] Default value
      # @return [String] User input
      def collect_via_ui(message, default: nil)
        # Show prompt in output area
        @ui_controller.append_output(message)
        
        # Set input prompt
        prompt_text = default ? "[>>] (#{default}): " : "[>>] "
        @ui_controller.layout.input_area.set_prompt(prompt_text)
        @ui_controller.layout.render_input
        
        # Wait for input
        result = nil
        @ui_controller.on_input do |input|
          result = input.empty? && default ? default : input
        end
        
        # Block until input received
        sleep 0.1 until result
        
        result
      end

      # Collect confirmation via UI2 controller
      # @param message [String] Prompt message
      # @param default [Boolean] Default value
      # @return [Boolean] User confirmation
      def collect_confirmation_via_ui(message, default: false)
        default_hint = default ? "(Y/n)" : "(y/N)"
        full_message = "#{message} #{default_hint}"
        
        @ui_controller.append_output(full_message)
        @ui_controller.layout.input_area.set_prompt("[??] ")
        @ui_controller.layout.render_input
        
        result = nil
        @ui_controller.on_input do |input|
          response = input.strip.downcase
          result = case response
                   when "y", "yes" then true
                   when "n", "no" then false
                   when "" then default
                   else default
                   end
        end
        
        sleep 0.1 until result
        
        result
      end

      # Collect selection via UI2 controller
      # @param message [String] Prompt message
      # @param choices [Array] Array of choices
      # @param default [Object, nil] Default selection
      # @return [Object] Selected choice
      def collect_selection_via_ui(message, choices, default: nil)
        # Show choices in output
        @ui_controller.append_output(message)
        choices.each_with_index do |choice, idx|
          marker = (choice == default) ? "*" : " "
          @ui_controller.append_output("  #{marker} #{idx + 1}. #{choice}")
        end
        
        @ui_controller.layout.input_area.set_prompt("[>>] Select number: ")
        @ui_controller.layout.render_input
        
        result = nil
        @ui_controller.on_input do |input|
          index = input.to_i - 1
          result = if index >= 0 && index < choices.size
                     choices[index]
                   elsif input.empty? && default
                     default
                   else
                     default || choices.first
                   end
        end
        
        sleep 0.1 until result
        
        result
      end

      # Collect multi-selection via UI2 controller
      # @param message [String] Prompt message
      # @param choices [Array] Array of choices
      # @return [Array] Selected choices
      def collect_multi_selection_via_ui(message, choices)
        @ui_controller.append_output(message)
        @ui_controller.append_output("Enter numbers separated by commas (e.g., 1,3,5)")
        
        choices.each_with_index do |choice, idx|
          @ui_controller.append_output("  #{idx + 1}. #{choice}")
        end
        
        @ui_controller.layout.input_area.set_prompt("[>>] Select: ")
        @ui_controller.layout.render_input
        
        result = nil
        @ui_controller.on_input do |input|
          indices = input.split(",").map(&:strip).map(&:to_i).map { |i| i - 1 }
          result = indices.select { |i| i >= 0 && i < choices.size }.map { |i| choices[i] }
        end
        
        sleep 0.1 until result
        
        result
      end

      # Collect masked input via UI2 controller
      # @param message [String] Prompt message
      # @return [String] User input
      def collect_masked_via_ui(message)
        @ui_controller.append_output(message)
        @ui_controller.layout.input_area.set_prompt("[>>] (hidden): ")
        @ui_controller.layout.render_input
        
        # TODO: Implement actual masking in InputArea
        # For now, use regular input
        result = nil
        @ui_controller.on_input do |input|
          result = input
        end
        
        sleep 0.1 until result
        
        result
      end
    end
  end
end
