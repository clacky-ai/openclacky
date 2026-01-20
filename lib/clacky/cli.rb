# frozen_string_literal: true

require "thor"
require "tty-prompt"
require "tty-spinner"
require_relative "ui/banner"
require_relative "ui/enhanced_prompt"
require_relative "ui/statusbar"
require_relative "ui/formatter"
require_relative "ui2/agent_adapter"

module Clacky
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # Set agent as the default command
    default_task :agent

    desc "version", "Show clacky version"
    def version
      say "Clacky version #{Clacky::VERSION}"
    end

    desc "agent [MESSAGE]", "Run agent in interactive mode with autonomous tool use (default)"
    long_desc <<-LONGDESC
      Run an AI agent in interactive mode that can autonomously use tools to complete tasks.

      The agent runs in a continuous loop, allowing multiple tasks in one session.
      Each task is completed with its own React (Reason-Act-Observe) cycle.
      After completing a task, the agent waits for your next instruction.

      Permission modes:
        auto_approve    - Automatically execute all tools (use with caution)
        confirm_safes   - Auto-approve safe operations, confirm risky ones (default)
        confirm_edits   - Auto-approve read-only tools, confirm edits
        plan_only       - Generate plan without executing

      Session management:
        -c, --continue  - Continue the most recent session for this directory
        -l, --list      - List recent sessions
        -a, --attach N  - Attach to session by number (e.g., -a 2) or session ID prefix (e.g., -a b6682a87)

      Examples:
        $ clacky agent
        $ clacky agent "Create a README file"
        $ clacky agent --mode=auto_approve --path /path/to/project
        $ clacky agent --tools file_reader glob grep
        $ clacky agent -c
        $ clacky agent -l
        $ clacky agent -a 2
        $ clacky agent -a b6682a87
    LONGDESC
    option :mode, type: :string, default: "confirm_safes",
           desc: "Permission mode: auto_approve, confirm_safes, confirm_edits, plan_only"
    option :tools, type: :array, default: ["all"], desc: "Allowed tools"
    option :max_iterations, type: :numeric, desc: "Maximum iterations (default: 50)"
    option :max_cost, type: :numeric, desc: "Maximum cost in USD (default: 5.0)"
    option :verbose, type: :boolean, default: false, desc: "Show detailed output"
    option :path, type: :string, desc: "Project directory path (defaults to current directory)"
    option :continue, type: :boolean, aliases: "-c", desc: "Continue most recent session"
    option :list, type: :boolean, aliases: "-l", desc: "List recent sessions"
    option :attach, type: :string, aliases: "-a", desc: "Attach to session by number or keyword"
    option :ui2, type: :boolean, default: false, desc: "Use UI2 split-screen interface (experimental)"
    def agent(message = nil)
      config = Clacky::Config.load

      unless config.api_key
        say "Error: API key not found. Please run 'clacky config set' first.", :red
        exit 1
      end

      # Handle session listing
      if options[:list]
        list_sessions
        return
      end

      # Handle Ctrl+C gracefully - raise exception to be caught in the loop
      Signal.trap("INT") do
        Thread.main.raise(Clacky::AgentInterrupted, "Interrupted by user")
      end

      # Validate and get working directory
      working_dir = validate_working_directory(options[:path])

      # Build agent config
      agent_config = build_agent_config(config)
      client = Clacky::Client.new(config.api_key, base_url: config.base_url)

      # Handle session loading/continuation
      session_manager = Clacky::SessionManager.new
      agent = nil

      if options[:continue]
        agent = load_latest_session(client, agent_config, session_manager, working_dir)
      elsif options[:attach]
        agent = load_session_by_number(client, agent_config, session_manager, working_dir, options[:attach])
      end

      # Create new agent if no session loaded
      agent ||= Clacky::Agent.new(client, agent_config, working_dir: working_dir)

      # Change to working directory
      original_dir = Dir.pwd
      should_chdir = File.realpath(working_dir) != File.realpath(original_dir)
      Dir.chdir(working_dir) if should_chdir

      begin
        # Run in UI2 mode or traditional mode
        if options[:ui2]
          run_agent_with_ui2(agent, working_dir, agent_config, message, session_manager, client)
        else
          run_agent_interactive(agent, working_dir, agent_config, message, session_manager, client)
        end
      rescue StandardError => e
        # Save session on error
        if session_manager
          session_manager.save(agent.to_session_data(status: :error, error_message: e.message))
        end

        # Report the error
        say "\n❌ Error: #{e.message}", :red
        say e.backtrace.first(5).join("\n"), :red if options[:verbose]

        # Show session saved message
        if session_manager&.last_saved_path
          say "\n📂 Session saved: #{session_manager.last_saved_path}", :yellow
        end

        # Guide user to recover
        say "\n💡 To recover and retry, run:", :yellow
        say "   clacky agent -c", :cyan

        exit 1
      ensure
        Dir.chdir(original_dir)
      end
    end

    desc "price", "Show pricing information for AI models"
    def price
      say "\n💰 Model Pricing Information\n\n", :green
      
      say "Clacky supports three pricing modes when calculating API costs:\n\n", :white
      
      say "  1. ", :cyan
      say "API-provided cost", :bold
      say " (", :white
      say ":api", :yellow
      say ")", :white
      say "\n     The most accurate - uses actual cost data from the API response", :white
      say "\n     Supported by: OpenRouter, LiteLLM, and other compatible proxies\n\n"
      
      say "  2. ", :cyan
      say "Model-specific pricing", :bold
      say " (", :white
      say ":price", :yellow
      say ")", :white
      say "\n     Uses official pricing from model providers (Claude models)", :white
      say "\n     Includes tiered pricing and prompt caching discounts\n\n"
      
      say "  3. ", :cyan
      say "Default fallback pricing", :bold
      say " (", :white
      say ":default", :yellow
      say ")", :white
      say "\n     Conservative estimates for unknown models", :white
      say "\n     Input: $0.50/MTok, Output: $1.50/MTok\n\n"
      
      say "Priority order: API cost > Model pricing > Default pricing\n\n", :yellow
      
      say "Supported models with official pricing:\n", :green
      say "  • claude-opus-4.5\n", :cyan
      say "  • claude-sonnet-4.5\n", :cyan
      say "  • claude-haiku-4.5\n", :cyan
      say "  • claude-3-5-sonnet-20241022\n", :cyan
      say "  • claude-3-5-sonnet-20240620\n", :cyan
      say "  • claude-3-5-haiku-20241022\n\n", :cyan
      
      say "For detailed pricing information, visit:\n", :white
      say "https://www.anthropic.com/pricing\n\n", :blue
    end

    no_commands do
      def build_agent_config(config)
        AgentConfig.new(
          model: options[:model] || config.model,
          permission_mode: options[:mode].to_sym,
          allowed_tools: options[:tools],
          max_iterations: options[:max_iterations],
          max_cost_usd: options[:max_cost],
          verbose: options[:verbose]
        )
      end

      def prompt_for_input
        prompt = TTY::Prompt.new
        prompt.ask("What would you like the agent to do?", required: true)
      end

      def display_agent_event(event)
        formatter = ui_formatter

        case event[:type]
        when :thinking
          formatter.thinking
        when :assistant_message
          # Display assistant's thinking/explanation before tool calls
          formatter.assistant_message(event[:data][:content])
        when :tool_call
          display_tool_call(event[:data])
        when :observation
          display_tool_result(event[:data])
          # Auto-display TODO status if exists
          display_todo_status_if_exists
        when :answer
          formatter.assistant_message(event[:data][:content])
        when :tool_denied
          formatter.tool_denied(event[:data][:name])
        when :tool_planned
          formatter.tool_planned(event[:data][:name])
        when :tool_error
          formatter.tool_error(event[:data][:error].message)
        when :on_iteration
          formatter.iteration(event[:data][:iteration]) if options[:verbose]
        end
      end

      def display_tool_call(data)
        tool_name = data[:name]
        args_json = data[:arguments]

        # Get tool instance to use its format_call method
        tool = get_tool_instance(tool_name)
        if tool
          begin
            args = JSON.parse(args_json, symbolize_names: true)
            formatted = tool.format_call(args)
            ui_formatter.tool_call(formatted)
          rescue JSON::ParserError, StandardError => e
            say "⚠️  Warning: Failed to format tool call: #{e.message}", :yellow
            ui_formatter.tool_call("#{tool_name}(...)")
          end
        else
          say "⚠️  Warning: Tool instance not found for '#{tool_name}'", :yellow
          ui_formatter.tool_call("#{tool_name}(...)")
        end

        # Show verbose details if requested
        if options[:verbose]
          say "   Arguments: #{args_json[0..200]}", :white
        end
      end

      def display_tool_result(data)
        tool_name = data[:tool]
        result = data[:result]

        # Get tool instance to use its format_result method
        tool = get_tool_instance(tool_name)
        if tool
          begin
            summary = tool.format_result(result)
            ui_formatter.tool_result(summary)
          rescue StandardError => e
            ui_formatter.tool_result("Done")
          end
        else
          # Fallback for unknown tools
          result_str = result.to_s
          summary = result_str.length > 100 ? "#{result_str[0..100]}..." : result_str
          ui_formatter.tool_result(summary)
        end

        # Show verbose details if requested
        if options[:verbose] && result.is_a?(Hash)
          say "     #{result.inspect[0..200]}", :white
        end
      end

      def get_tool_instance(tool_name)
        # Use metaprogramming to find tool class by name
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

      def display_todo_status_if_exists
        return unless @current_agent

        todos = @current_agent.todos
        return if todos.empty?

        ui_formatter.todo_status(todos)
      end

      def validate_working_directory(path)
        working_dir = path || Dir.pwd

        # Expand path to absolute path
        working_dir = File.expand_path(working_dir)

        # Validate directory exists
        unless Dir.exist?(working_dir)
          say "Error: Directory does not exist: #{working_dir}", :red
          exit 1
        end

        # Validate it's a directory
        unless File.directory?(working_dir)
          say "Error: Path is not a directory: #{working_dir}", :red
          exit 1
        end

        working_dir
      end

      def run_in_directory(directory)
        original_dir = Dir.pwd

        begin
          Dir.chdir(directory)
          yield
        ensure
          Dir.chdir(original_dir)
        end
      end

      def run_agent_interactive(agent, working_dir, agent_config, initial_message = nil, session_manager = nil, client = nil)
        # Store agent as instance variable for access in display methods
        @current_agent = agent

        # Initialize UI components
        banner = ui_banner
        prompt = ui_prompt
        statusbar = ui_statusbar

        # Show startup banner for new session
        if agent.total_tasks == 0
          banner.display_startup
        end

        # Show session info if continuing
        if agent.total_tasks > 0
          banner.display_session_continue(
            session_id: agent.session_id[0..7],
            created_at: Time.parse(agent.created_at).strftime('%Y-%m-%d %H:%M'),
            tasks: agent.total_tasks,
            cost: agent.total_cost.round(4)
          )

          # Show recent conversation history
          display_recent_messages(agent.messages, limit: 5)
        else
          # Show welcome info for new session
          banner.display_agent_welcome(
            working_dir: working_dir,
            mode: agent_config.permission_mode,
            max_iterations: agent_config.max_iterations,
            max_cost: agent_config.max_cost_usd
          )
        end

        total_tasks = agent.total_tasks
        total_cost = agent.total_cost

        # Process initial message if provided
        current_message = initial_message
        current_images = []

        loop do
          # Get message from user if not provided
          unless current_message && !current_message.strip.empty?
            # Only show newline separator if we've completed tasks
            # (but not right after /clear since we just showed a message)
            say "\n" if total_tasks > 0

            # Show status bar before input
            statusbar.display(
              working_dir: working_dir,
              mode: agent_config.permission_mode.to_s,
              model: agent_config.model,
              tasks: total_tasks,
              cost: total_cost
            )

            # Use enhanced prompt with "❯" prefix
            result = prompt.read_input(prefix: "❯") do |display_lines|
              # Shift+Tab pressed - toggle mode and update status bar
              if agent_config.permission_mode == :confirm_safes
                agent_config.permission_mode = :auto_approve
              else
                agent_config.permission_mode = :confirm_safes
              end

              # Update status bar (it's above the input box)
              # display_lines includes the final newline, so we need display_lines moves to reach status bar
              print "\e[#{display_lines}A"  # Move up to status bar line
              print "\r\e[2K"  # Clear the status bar line

              # Redisplay status bar with new mode (puts adds newline, cursor moves to next line)
              statusbar.display(
                working_dir: working_dir,
                mode: agent_config.permission_mode.to_s,
                model: agent_config.model,
                tasks: total_tasks,
                cost: total_cost
              )

              # Move back down to original position (display_lines - 1 because puts moved us down 1)
              print "\e[#{display_lines - 1}B"
            end
            
            # EnhancedPrompt returns:
            # - { text: String, images: Array } for normal input
            # - { command: Symbol } for commands
            # - nil on EOF
            if result.nil?
              current_message = nil
              current_images = []
              break
            elsif result[:command]
              # Handle commands
              case result[:command]
              when :clear
                # Clear session by creating a new agent
                agent = Clacky::Agent.new(client, agent_config, working_dir: working_dir)
                @current_agent = agent
                total_tasks = 0
                total_cost = 0.0
                ui_formatter.info("Session cleared. Starting fresh.")
                current_message = nil
                current_images = []
                next
              when :exit
                current_message = nil
                current_images = []
                break
              end
            else
              # Normal input with text and optional images
              current_message = result[:text]
              current_images = result[:images] || []
            end

            break if current_message.nil? || %w[exit quit].include?(current_message&.downcase&.strip)
            next if current_message.strip.empty? && current_images.empty?

            # Display user's message after input
            ui_formatter.user_message(current_message)

            # Display image info if images were pasted (without extra newline)
            if current_images.any?
              current_images.each_with_index do |img_path, idx|
                filename = File.basename(img_path)
                say "  📎 Image #{idx + 1}: #{filename}", :cyan
              end
              puts  # Add newline after all images
            else
              puts  # Add newline after user message if no images
            end
          end

          total_tasks += 1

          begin
            result = agent.run(current_message, images: current_images) do |event|
              display_agent_event(event)
            end

            total_cost += result[:total_cost_usd]

            # Save session after each task with success status
            if session_manager
              session_manager.save(agent.to_session_data(status: :success))
            end

            # Show brief task completion
            banner.display_task_complete(
              iterations: result[:iterations],
              cost: result[:total_cost_usd].round(4),
              total_tasks: total_tasks,
              total_cost: total_cost.round(4),
              cost_source: result[:cost_source],
              cache_stats: result[:cache_stats]
            )
          rescue Clacky::AgentInterrupted
            # Save session on interruption
            if session_manager
              session_manager.save(agent.to_session_data(status: :interrupted))
              ui_formatter.warning("Task interrupted by user (Ctrl+C)")
              say "You can start a new task or type 'exit' to quit.\n", :yellow
            end
          rescue StandardError => e
            # Save session on error
            if session_manager
              session_manager.save(agent.to_session_data(status: :error, error_message: e.message))
            end

            # Report the error
            banner.display_error(e.message, details: options[:verbose] ? e.backtrace.first(3).join("\n") : nil)

            # Show session saved message
            if session_manager&.last_saved_path
              ui_formatter.info("Session saved: #{session_manager.last_saved_path}")
            end

            # Guide user to recover
            ui_formatter.info("To recover and retry, run: clacky agent -c")
            say "\nOr you can continue with a new task or type 'exit' to quit.", :yellow
          end

          # Clear current_message and current_images to prompt for next input
          current_message = nil
          current_images = []
        end

        # Save final session state only if there were actual tasks
        # Don't save empty sessions where user just started and exited
        if session_manager && total_tasks > 0
          session_manager.save(agent.to_session_data)
        end

        banner.display_goodbye(
          total_tasks: total_tasks,
          total_cost: total_cost.round(4)
        )
      end

      def list_sessions
        session_manager = Clacky::SessionManager.new
        working_dir = validate_working_directory(options[:path])
        sessions = session_manager.list(current_dir: working_dir, limit: 5)

        if sessions.empty?
          say "No sessions found.", :yellow
          return
        end

        say "\n📋 Recent sessions:\n", :green
        sessions.each_with_index do |session, index|
          created_at = Time.parse(session[:created_at]).strftime("%Y-%m-%d %H:%M")
          session_id = session[:session_id][0..7]
          tasks = session.dig(:stats, :total_tasks) || 0
          cost = session.dig(:stats, :total_cost_usd) || 0.0
          first_msg = session[:first_user_message] || "No message"
          is_current_dir = session[:working_dir] == working_dir

          dir_marker = is_current_dir ? "📍" : "  "
          say "#{dir_marker} #{index + 1}. [#{session_id}] #{created_at} (#{tasks} tasks, $#{cost.round(4)}) - #{first_msg}", :cyan
        end
        say ""
      end

      def load_latest_session(client, agent_config, session_manager, working_dir)
        session_data = session_manager.latest_for_directory(working_dir)

        if session_data.nil?
          say "No previous session found for this directory.", :yellow
          return nil
        end

        say "Loading latest session: #{session_data[:session_id][0..7]}", :green
        Clacky::Agent.from_session(client, agent_config, session_data)
      end

      def load_session_by_number(client, agent_config, session_manager, working_dir, identifier)
        sessions = session_manager.list(current_dir: working_dir, limit: 10)

        if sessions.empty?
          say "No sessions found.", :yellow
          return nil
        end

        session_data = nil

        # Check if identifier is a number (index-based)
        if identifier.match?(/^\d+$/)
          index = identifier.to_i - 1
          if index < 0 || index >= sessions.size
            say "Invalid session number. Use -l to list available sessions.", :red
            exit 1
          end
          session_data = sessions[index]
        else
          # Treat as session ID prefix
          matching_sessions = sessions.select { |s| s[:session_id].start_with?(identifier) }

          if matching_sessions.empty?
            say "No session found matching ID prefix: #{identifier}", :red
            say "Use -l to list available sessions.", :yellow
            exit 1
          elsif matching_sessions.size > 1
            say "Multiple sessions found matching '#{identifier}':", :yellow
            matching_sessions.each_with_index do |session, idx|
              created_at = Time.parse(session[:created_at]).strftime("%Y-%m-%d %H:%M")
              session_id = session[:session_id][0..7]
              first_msg = session[:first_user_message] || "No message"
              say "  #{idx + 1}. [#{session_id}] #{created_at} - #{first_msg}", :cyan
            end
            say "\nPlease use a more specific prefix.", :yellow
            exit 1
          else
            session_data = matching_sessions.first
          end
        end

        say "Loading session: #{session_data[:session_id][0..7]}", :green
        Clacky::Agent.from_session(client, agent_config, session_data)
      end

      def display_recent_messages(messages, limit: 5)
        # Filter out user and assistant messages (exclude system and tool messages)
        conversation_messages = messages.select { |m| m[:role] == "user" || m[:role] == "assistant" }

        # Get the last N messages
        recent = conversation_messages.last(limit * 2) # *2 to get user+assistant pairs

        if recent.empty?
          return
        end

        formatter = ui_formatter
        formatter.separator("─")
        say pastel.dim("Recent conversation history:"), :yellow
        formatter.separator("─")

        recent.each do |msg|
          case msg[:role]
          when "user"
            content = truncate_message(msg[:content], 150)
            say "  #{pastel.blue('[>>]')} You: #{content}"
          when "assistant"
            content = truncate_message(msg[:content], 200)
            say "  #{pastel.green('[<<]')} Assistant: #{content}"
          end
        end

        formatter.separator("─")
        say ""
      end

      def truncate_message(content, max_length)
        return "" if content.nil? || content.empty?

        # Remove excessive whitespace
        cleaned = content.strip.gsub(/\s+/, ' ')

        if cleaned.length > max_length
          cleaned[0...max_length] + "..."
        else
          cleaned
        end
      end

      # UI component accessors
      def ui_banner
        @ui_banner ||= UI::Banner.new
      end

      def ui_prompt
        @ui_prompt ||= UI::EnhancedPrompt.new
      end

      def ui_statusbar
        @ui_statusbar ||= UI::StatusBar.new
      end

      def ui_formatter
        @ui_formatter ||= UI::Formatter.new
      end

      def pastel
        @pastel ||= Pastel.new
      end

      # Run agent with UI2 split-screen interface
      def run_agent_with_ui2(agent, working_dir, agent_config, initial_message = nil, session_manager = nil, client = nil)
        # Create UI2 controller
        ui_controller = UI2::UIController.new
        adapter = UI2::AgentAdapter.new(ui_controller)
        adapter.connect_agent(agent)

        # Set up tool confirmation handler
        agent.tool_confirmation_handler = ->(call) do
          adapter.request_tool_confirmation(call)
        end

        # Track session state
        total_tasks = agent.total_tasks
        total_cost = agent.total_cost
        current_message = initial_message
        current_images = []

        # Set up input handler
        ui_controller.on_input do |input|
          # Check if we're waiting for tool confirmation
          if adapter.waiting_for_confirmation?
            adapter.handle_confirmation_response(input)
            next
          end

          # Handle commands
          case input.downcase.strip
          when "/clear"
            # Clear session by creating a new agent
            agent = Clacky::Agent.new(client, agent_config, working_dir: working_dir)
            adapter.connect_agent(agent)
            agent.tool_confirmation_handler = ->(call) do
              adapter.request_tool_confirmation(call)
            end
            total_tasks = 0
            total_cost = 0.0
            ui_controller.append_output("✨ Session cleared. Starting fresh.")
            next
          when "/exit", "/quit"
            ui_controller.stop
            exit(0)
          when "/help"
            show_ui2_help(ui_controller)
            next
          end

          # Process user message
          begin
            ui_controller.event_bus.publish(:user_message, {
              content: input,
              timestamp: Time.now
            })

            total_tasks += 1

            # Run agent with adapter
            result = adapter.run_agent(input, images: [])
            total_cost += result[:total_cost_usd]

            # Save session after each task
            if session_manager
              session_manager.save(agent.to_session_data(status: :success))
            end

            # Show task completion
            ui_controller.append_output(
              "✅ Task complete (#{result[:iterations]} iterations, $#{result[:total_cost_usd].round(4)}, total: $#{total_cost.round(4)})"
            )
          rescue Clacky::AgentInterrupted
            # Save session on interruption
            if session_manager
              session_manager.save(agent.to_session_data(status: :interrupted))
              ui_controller.append_output("⚠️ Task interrupted by user (Ctrl+C)")
            end
          rescue StandardError => e
            # Save session on error
            if session_manager
              session_manager.save(agent.to_session_data(status: :error, error_message: e.message))
            end

            # Report the error
            ui_controller.append_output("❌ Error: #{e.message}")
            if options[:verbose] && e.backtrace
              ui_controller.append_output(e.backtrace.first(3).join("\n"))
            end

            # Show session saved message
            if session_manager&.last_saved_path
              ui_controller.append_output("📂 Session saved: #{session_manager.last_saved_path}")
            end
          end
        end

        # Show startup message
        ui_controller.append_output("🚀 Clacky UI2 - Split-screen interface")
        ui_controller.append_output("📁 Working directory: #{working_dir}")
        ui_controller.append_output("🔧 Mode: #{agent_config.permission_mode}")
        ui_controller.append_output("Type /help for commands, /exit to quit")
        ui_controller.append_output("")

        # If there's an initial message, process it
        if initial_message && !initial_message.strip.empty?
          ui_controller.event_bus.publish(:user_message, {
            content: initial_message,
            timestamp: Time.now
          })

          begin
            result = adapter.run_agent(initial_message, images: [])
            total_cost += result[:total_cost_usd]

            if session_manager
              session_manager.save(agent.to_session_data(status: :success))
            end
          rescue StandardError => e
            ui_controller.append_output("❌ Error: #{e.message}")
          end
        end

        # Start UI controller (blocks until exit)
        ui_controller.start

        # Save final session state
        if session_manager && total_tasks > 0
          session_manager.save(agent.to_session_data)
        end

        # Show goodbye message
        say "\n👋 Goodbye! Session stats:", :green
        say "   Tasks completed: #{total_tasks}", :cyan
        say "   Total cost: $#{total_cost.round(4)}", :cyan
      end

      # Show help for UI2 mode
      def show_ui2_help(ui_controller)
        help_text = <<~HELP
          📖 UI2 Commands:
            /help     - Show this help
            /clear    - Clear session and start fresh
            /exit     - Exit UI2 mode
            
          Keyboard shortcuts:
            Ctrl+C    - Exit
            Ctrl+L    - Clear output area
            Ctrl+U    - Clear input line
            Up/Down   - Scroll output (when input empty) or history
            Left/Right - Move cursor in input
            Home/End  - Jump to start/end of input
        HELP

        ui_controller.append_output(help_text)
      end
    end
  end

  class ConfigCommand < Thor
    desc "set", "Set configuration values"
    def set
      prompt = TTY::Prompt.new

      config = Clacky::Config.load

      # API Key
      api_key = prompt.mask("Enter your Claude API key:")
      config.api_key = api_key

      # Model
      model = prompt.ask("Enter model:", default: config.model)
      config.model = model

      # Base URL
      base_url = prompt.ask("Enter base URL:", default: config.base_url)
      config.base_url = base_url

      config.save

      say "\nConfiguration saved successfully!", :green
      say "API Key: #{api_key[0..7]}#{'*' * 20}#{api_key[-4..]}", :cyan
      say "Model: #{config.model}", :cyan
      say "Base URL: #{config.base_url}", :cyan
    end

    desc "show", "Show current configuration"
    def show
      config = Clacky::Config.load

      if config.api_key
        masked_key = config.api_key[0..7] + ("*" * 20) + config.api_key[-4..]
        say "API Key: #{masked_key}", :cyan
        say "Model: #{config.model}", :cyan
        say "Base URL: #{config.base_url}", :cyan
      else
        say "No configuration found. Run 'clacky config set' to configure.", :yellow
      end
    end
  end

  # Register subcommands after all classes are defined
  CLI.register(ConfigCommand, "config", "config SUBCOMMAND", "Manage configuration")
end
