# frozen_string_literal: true

module Clacky
  module RichUI
    class LayoutAdapter
      def initialize(shell)
        @shell = shell
      end

      def clear_output
        @shell.transcript.store.entries.clear
        @shell.viewport.scroll_to_bottom
      end
    end
  end
end
