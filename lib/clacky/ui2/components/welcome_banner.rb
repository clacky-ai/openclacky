# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # WelcomeBanner displays the startup screen with ASCII logo, tagline, tips, and agent info
      class WelcomeBanner
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
        ].freeze

        def initialize
          @pastel = Pastel.new
        end

        # Render startup banner
        # @return [String] Formatted startup banner
        def render_startup
          lines = []
          lines << ""
          lines << @pastel.bright_green(LOGO)
          lines << ""
          lines << @pastel.bright_cyan(TAGLINE)
          lines << ""
          TIPS.each do |tip|
            lines << @pastel.dim(tip)
          end
          lines << ""
          lines.join("\n")
        end

        # Render agent welcome section
        # @param working_dir [String] Working directory
        # @param mode [String] Permission mode
        # @param max_iterations [Integer] Maximum iterations
        # @param max_cost [Float] Maximum cost
        # @return [String] Formatted agent welcome section
        def render_agent_welcome(working_dir:, mode:, max_iterations:, max_cost:)
          lines = []
          lines << ""
          lines << separator("=")
          lines << @pastel.bright_green("[+] AGENT MODE INITIALIZED")
          lines << separator("=")
          lines << ""
          lines << info_line("Working Directory", working_dir)
          lines << info_line("Permission Mode", mode)
          lines << info_line("Max Iterations", max_iterations.to_s)
          lines << info_line("Max Cost", "$#{max_cost}")
          lines << ""
          lines << @pastel.dim("[!] Type 'exit' or 'quit' to terminate session")
          lines << separator("-")
          lines << ""
          lines.join("\n")
        end

        # Render full welcome (startup + agent info)
        # @param working_dir [String] Working directory
        # @param mode [String] Permission mode
        # @param max_iterations [Integer] Maximum iterations
        # @param max_cost [Float] Maximum cost
        # @return [String] Full welcome content
        def render_full(working_dir:, mode:, max_iterations:, max_cost:)
          render_startup + render_agent_welcome(
            working_dir: working_dir,
            mode: mode,
            max_iterations: max_iterations,
            max_cost: max_cost
          )
        end

        private

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
end
