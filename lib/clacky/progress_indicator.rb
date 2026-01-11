# frozen_string_literal: true

module Clacky
  class ProgressIndicator
    def initialize(verbose: false, message: nil)
      @verbose = verbose
      @start_time = nil
      @custom_message = message
      @thinking_verb = message || THINKING_VERBS.sample
      @running = false
      @update_thread = nil
    end

    def start
      @start_time = Time.now
      @running = true
      print_status("#{@thinking_verb}… (ctrl+c to interrupt)")

      # Start background thread to update elapsed time
      @update_thread = Thread.new do
        while @running
          sleep 1
          update if @running
        end
      end
    end

    def update
      return unless @start_time

      elapsed = (Time.now - @start_time).to_i
      print_status("#{@thinking_verb}… (ctrl+c to interrupt · #{elapsed}s)")
    end

    def finish
      @running = false
      @update_thread&.join
      clear_line
    end

    private

    def print_status(text)
      print "\r\033[K#{text}" # \r moves to start of line, \033[K clears to end of line
      $stdout.flush
    end

    def clear_line
      print "\r\033[K" # Clear the entire line
      $stdout.flush
    end
  end
end
