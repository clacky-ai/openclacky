# frozen_string_literal: true

require "pastel"

module Clacky
  module UI
    # ASCII art banner and startup screen with Matrix/hacker aesthetic
    class Banner
      LOGO = <<~'LOGO'
         ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗  ██████╗██╗  ██╗██╗   ██╗
        ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██╔════╝██║ ██╔╝╚██╗ ██╔╝
        ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║     █████╔╝  ╚████╔╝ 
        ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║     ██╔═██╗   ╚██╔╝  
        ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚██████╗██║  ██╗   ██║   
         ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   
      LOGO

      TAGLINE = "[>] AI Coding Assistant & Technical Co-founder"

      TIPS = [
        "[*] Ask questions, edit files, or run commands",
        "[*] Be specific for the best results",
        "[*] Create .clackyrules to customize interactions",
        "[*] Type /help for more commands"
      ]

      def initialize
        @pastel = Pastel.new
      end

      # Display full startup banner
      def display_startup
        puts
        puts @pastel.bright_green(LOGO)
        puts
        puts @pastel.bright_cyan(TAGLINE)
        puts
        display_tips
        puts
      end

      # Display welcome message for agent mode
      def display_agent_welcome(working_dir:, mode:, max_iterations:, max_cost:)
        puts
        puts separator("=")
        puts @pastel.bright_green("[+] AGENT MODE INITIALIZED")
        puts separator("=")
        puts
        puts info_line("Working Directory", working_dir)
        puts info_line("Permission Mode", mode)
        puts info_line("Max Iterations", max_iterations)
        puts info_line("Max Cost", "$#{max_cost}")
        puts
        puts @pastel.dim("[!] Type 'exit' or 'quit' to terminate session")
        puts separator("-")
        puts
      end

      # Display session continuation info
      def display_session_continue(session_id:, created_at:, tasks:, cost:)
        puts
        puts separator("=")
        puts @pastel.bright_yellow("[~] RESUMING SESSION")
        puts separator("=")
        puts
        puts info_line("Session ID", session_id)
        puts info_line("Started", created_at)
        puts info_line("Tasks Completed", tasks)
        puts info_line("Total Cost", "$#{cost}")
        puts separator("-")
        puts
      end

      # Display task completion summary
      def display_task_complete(iterations:, cost:, total_tasks:, total_cost:, cache_stats: {})
        puts
        puts separator("-")
        puts @pastel.bright_green("[✓] TASK COMPLETED")
        puts info_line("Iterations", iterations)
        puts info_line("Cost", "$#{cost}")
        puts info_line("Session Total", "#{total_tasks} tasks, $#{total_cost}")
        
        # Display cache statistics if available
        if cache_stats[:total_requests] && cache_stats[:total_requests] > 0
          puts
          puts @pastel.cyan("    [Prompt Caching]")
          puts info_line("  Cache Writes", "#{cache_stats[:cache_creation_input_tokens]} tokens")
          puts info_line("  Cache Reads", "#{cache_stats[:cache_read_input_tokens]} tokens")
          
          hit_rate = (cache_stats[:cache_hit_requests].to_f / cache_stats[:total_requests] * 100).round(1)
          puts info_line("  Cache Hit Rate", "#{hit_rate}% (#{cache_stats[:cache_hit_requests]}/#{cache_stats[:total_requests]} requests)")
        end
        
        puts separator("-")
        puts
      end

      # Display error message
      def display_error(message, details: nil)
        puts
        puts separator("-")
        puts @pastel.bright_red("[✗] ERROR")
        puts @pastel.red("    #{message}")
        if details
          puts @pastel.dim("    #{details}")
        end
        puts separator("-")
        puts
      end

      # Display session end
      def display_goodbye(total_tasks:, total_cost:)
        puts
        puts separator("=")
        puts @pastel.bright_cyan("[#] SESSION TERMINATED")
        puts separator("=")
        puts
        puts info_line("Total Tasks", total_tasks)
        puts info_line("Total Cost", "$#{total_cost}")
        puts
        puts @pastel.dim("[*] All session data has been saved")
        puts
      end

      private

      def display_tips
        TIPS.each do |tip|
          puts @pastel.dim(tip)
        end
      end

      def info_line(label, value)
        label_text = @pastel.cyan("[#{label}]")
        value_text = @pastel.white(value)
        "    #{label_text} #{value_text}"
      end

      def separator(char = "-")
        @pastel.dim(char * 80)
      end
    end
  end
end
