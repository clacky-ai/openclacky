# frozen_string_literal: true

require_relative "ui_controller"
require_relative "input_collector"

module Clacky
  module UI2
    # AgentAdapter connects the Agent to UI2 EventBus
    # It handles agent events and publishes them to UI2 for rendering
    class AgentAdapter
      attr_reader :ui_controller, :event_bus, :agent

      def initialize(ui_controller)
        @ui_controller = ui_controller
        @event_bus = ui_controller.event_bus
        @agent = nil
        @input_collector = InputCollector.new(ui_controller: ui_controller)
        # Progress indicator state
        @progress_mutex = Mutex.new
        @progress_running = false
        @progress_thread = nil
        @progress_start_time = nil
        # Agent running state
        @agent_running = false

        setup_interrupt_handler
      end

      # Setup handler for interrupt events from UI
      private def setup_interrupt_handler
        @event_bus.on(:interrupt_requested) do
          if agent_running?
            interrupt_agent!
          else
            # No agent running, exit the application
            @ui_controller.stop
            exit(0)
          end
        end
      end

      # Connect an agent to this adapter
      # @param agent [Clacky::Agent] Agent instance to connect
      def connect_agent(agent)
        @agent = agent
      end

      # Run agent with UI2 integration
      # @param message [String] User message to process
      # @param images [Array<String>] Optional image paths
      # @return [Hash] Agent result
      def run_agent(message, images: [])
        @agent_running = true
        result = @agent.run(message, images: images) do |event|
          handle_agent_event(event)
        end
        result
      ensure
        @agent_running = false
      end

      # Check if agent is currently running
      def agent_running?
        @agent_running
      end

      # Interrupt the running agent
      def interrupt_agent!
        # Always stop progress indicator, even if agent is not running
        stop_progress_indicator

        # Always show interrupt message to user
        @ui_controller.append_output("[Interrupted by user]")

        if @agent_running && @agent
          @agent.interrupt!
        end
      end

      # Handle agent events and publish to UI2
      # @param event [Hash] Agent event data
      private def handle_agent_event(event)
        case event[:type]
        when :thinking
          start_progress_indicator
          @event_bus.publish(:thinking, {})

        when :assistant_message
          stop_progress_indicator
          @event_bus.publish(:assistant_message, {
            content: event[:data][:content],
            timestamp: Time.now
          })

        when :tool_call
          stop_progress_indicator
          tool_data = event[:data]
          formatted_call = format_tool_call(tool_data)
          @event_bus.publish(:tool_call, {
            tool_name: tool_data[:name],
            formatted_call: formatted_call
          })

        when :observation
          @event_bus.publish(:tool_result, {
            result: format_tool_result(event[:data])
          })

        when :answer
          stop_progress_indicator
          @event_bus.publish(:assistant_message, {
            content: event[:data][:content],
            timestamp: Time.now
          })

        when :tool_denied
          @event_bus.publish(:tool_error, {
            error: "Tool #{event[:data][:name]} was denied"
          })

        when :tool_planned
          @ui_controller.append_output(
            "Planned: #{event[:data][:name]}"
          )

        when :tool_error
          @event_bus.publish(:tool_error, {
            error: event[:data][:error].message
          })

        when :on_iteration
          iteration = event[:data][:iteration]
          cost = event[:cost]
          @event_bus.publish(:status_update, {
            iteration: iteration,
            cost: cost,
            message: "Iteration #{iteration}"
          })

        when :tool_confirmation_required
          # This will be handled separately in confirm_tool_use
          # Do nothing here

        when :on_start
          # User input is already displayed by handle_submit, no need to show again

        when :on_complete
          stop_progress_indicator
          result = event[:data]
          @ui_controller.append_output(
            "Task complete (#{result[:iterations]} iterations, $#{result[:total_cost_usd].round(4)})"
          )

        when :network_retry
          data = event[:data]
          @ui_controller.append_output(
            "Network request failed: #{data[:error]}"
          )
          @ui_controller.append_output(
            "Retry #{data[:retry_count]}/#{data[:max_retries]}, waiting #{data[:delay]} seconds..."
          )

        when :network_error
          data = event[:data]
          @ui_controller.append_output(
            "Network request failed after #{data[:retries]} retries: #{data[:error]}"
          )

        when :response_truncated
          if event[:data][:recoverable]
            @ui_controller.append_output(
              "Response truncated due to length limit. Retrying with smaller steps..."
            )
          else
            @ui_controller.append_output(
              "Response truncated multiple times. Task is too complex for a single response."
            )
          end

        when :compression_start
          data = event[:data]
          @ui_controller.append_output(
            "Compressing conversation history (#{data[:original_size]} -> ~#{data[:target_size]} messages)..."
          )

        when :compression_complete
          data = event[:data]
          @ui_controller.append_output(
            "Compressed conversation history (#{data[:original_size]} -> #{data[:final_size]} messages)"
          )

        when :debug
          # Debug events are only shown in verbose mode (handled by Agent)
          @ui_controller.append_output(
            "[DEBUG] #{event[:data][:message]}"
          )

        when :todos_updated
          # Update todos display
          @ui_controller.update_todos(event[:data][:todos])
        end
      end

      # Format tool call for display
      # @param data [Hash] Tool call data with :name and :arguments
      # @return [String] Formatted call string
      private def format_tool_call(data)
        tool_name = data[:name]
        args_json = data[:arguments]

        # Get tool instance to use its format_call method
        tool = get_tool_instance(tool_name)
        if tool
          begin
            args = JSON.parse(args_json, symbolize_names: true)
            formatted = tool.format_call(args)
            return formatted
          rescue JSON::ParserError, StandardError => e
            # Fallback to simple format
          end
        end
        
        "#{tool_name}(...)"
      end

      # Format tool result for display
      # @param data [Hash] Result data with :tool and :result
      # @return [String] Formatted result string
      private def format_tool_result(data)
        tool_name = data[:tool]
        result = data[:result]

        # Get tool instance to use its format_result method
        tool = get_tool_instance(tool_name)
        if tool
          begin
            summary = tool.format_result(result)
            return summary
          rescue StandardError => e
            # Fallback
          end
        end

        # Fallback for unknown tools
        result_str = result.to_s
        summary = result_str.length > 100 ? "#{result_str[0..100]}..." : result_str
        summary
      end

      # Get tool instance by name
      # @param tool_name [String] Tool name
      # @return [Object, nil] Tool instance or nil
      private def get_tool_instance(tool_name)
        # Convert tool_name to class name (e.g., "file_reader" -> "FileReader")
        class_name = tool_name.split('_').map(&:capitalize).join

        # Try to find the class in Clacky::Tools namespace
        if Clacky::Tools.const_defined?(class_name)
          tool_class = Clacky::Tools.const_get(class_name)
          tool_class.new
        else
          nil
        end
      rescue NameError
        nil
      end

      # Request user confirmation for tool use via UI2
      # This method blocks until user provides confirmation
      # @param call [Hash] Tool call data
      # @return [Hash] Confirmation result with :approved and :feedback keys
      def request_tool_confirmation(call)
        # Show tool preview
        preview_text = format_tool_call(call)

        # Use InputCollector for confirmation (uses InlineInput internally)
        result = @input_collector.confirm_input(preview_text, default: true)

        if result.nil?
          # Cancelled (Ctrl+C)
          { approved: false, feedback: nil }
        elsif result == true
          { approved: true, feedback: nil }
        elsif result == false
          { approved: false, feedback: nil }
        else
          # String feedback
          { approved: false, feedback: result.to_s }
        end
      end

      # Check if waiting for confirmation (for compatibility)
      # @return [Boolean] True if waiting for user confirmation
      def waiting_for_confirmation?
        @ui_controller.inline_input&.active? || false
      end

      # Start progress indicator in output area
      private def start_progress_indicator
        @progress_mutex.synchronize do
          return if @progress_running

          @progress_running = true
          @progress_start_time = Time.now
          @thinking_verb = Clacky::THINKING_VERBS.sample

          # Show initial progress in output area
          @ui_controller.append_output("[..] #{@thinking_verb}...")

          @progress_thread = Thread.new do
            while @progress_running
              elapsed = (Time.now - @progress_start_time).to_i
              @ui_controller.update_progress_line("[..] #{@thinking_verb}... (#{elapsed}s)")
              sleep 0.5
            end
          end
        end
      end

      # Stop progress indicator
      private def stop_progress_indicator
        @progress_mutex.synchronize do
          return unless @progress_running

          @progress_running = false
        end

        # Join thread outside mutex to avoid deadlock
        @progress_thread&.join(1)
        @progress_thread = nil

        # Clear the progress line
        @ui_controller.clear_progress_line
      end
    end
  end
end
