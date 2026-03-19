# frozen_string_literal: true

require "pastel"
require_relative "version"
require_relative "brand_config"
require_relative "block_font"

module Clacky
  # Banner provides logo and branding for CLI and Web UI startup.
  # Lightweight — no terminal UI dependencies.
  class Banner
    DEFAULT_CLI_LOGO = <<~'LOGO'
   ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗  ██████╗██╗  ██╗██╗   ██╗
  ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██╔════╝██║ ██╔╝╚██╗ ██╔╝
  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║     █████╔╝  ╚████╔╝
  ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║     ██╔═██╗   ╚██╔╝
  ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚██████╗██║  ██╗   ██║
   ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝
    LOGO

    TAGLINE = "[>] Your personal Assistant & Technical Co-founder"

    def initialize
      @pastel = Pastel.new
      @brand  = BrandConfig.load
    end

    # Returns the CLI logo text.
    # If branded, renders package_name using BlockFont (big Unicode art).
    # Falls back to default OPENCLACKY logo when not branded.
    def cli_logo
      if @brand.branded?
        render_key = @brand.package_name.to_s.strip
        render_key = "clacky" if render_key.empty?
        Clacky::BlockFont.render(render_key)
      else
        DEFAULT_CLI_LOGO
      end
    end

    # Returns the tagline string.
    def tagline
      if @brand.branded?
        @brand.product_name.to_s
      else
        TAGLINE
      end
    end

    # Renders the CLI logo as colored text
    def colored_cli_logo
      @pastel.bright_green(cli_logo)
    end

    # Renders the tagline as colored text
    def colored_tagline
      @pastel.bright_cyan(tagline)
    end

    # Renders a URL with bold + underline for emphasis
    def highlight(url)
      @pastel.bold.underline(url)
    end
  end
end
