# frozen_string_literal: true

require_relative "themes/base_theme"
require_relative "themes/hacker_theme"
require_relative "themes/minimal_theme"

module Clacky
  module UI2
    # ThemeManager handles theme registration and switching
    class ThemeManager
      class << self
        def instance
          @instance ||= new
        end

        # Delegate methods to instance
        def current_theme
          instance.current_theme
        end

        def set_theme(name)
          instance.set_theme(name)
        end

        def available_themes
          instance.available_themes
        end

        def register_theme(name, theme_class)
          instance.register_theme(name, theme_class)
        end
      end

      def initialize
        @themes = {}
        @current_theme = nil
        register_default_themes
        set_theme(:hacker)
      end

      def current_theme
        @current_theme
      end

      def set_theme(name)
        name = name.to_sym
        raise ArgumentError, "Unknown theme: #{name}" unless @themes.key?(name)

        @current_theme = @themes[name].new
      end

      def available_themes
        @themes.keys
      end

      def register_theme(name, theme_class)
        @themes[name.to_sym] = theme_class
      end

      private

      def register_default_themes
        register_theme(:hacker, Themes::HackerTheme)
        register_theme(:minimal, Themes::MinimalTheme)
      end
    end
  end
end
