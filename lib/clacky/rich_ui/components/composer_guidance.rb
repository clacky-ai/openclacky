# frozen_string_literal: true

require "unicode/display_width"

module Clacky
  module RichUI
    # Extend the composer's attachment area rather than adding a layout sibling.
    # Keep pending entries out of @attachments so submitting/deleting a draft
    # cannot accidentally upload or consume queued messages.
    module ComposerGuidance
      attr_accessor :guidance_lines_provider

      def desired_height
        super + pending_guidance_lines.size
      end

      def native_cursor_position
        return nil unless focused?

        editor_row, editor_col = @editor.cursor_visual_position(width: [inner_width - 2, 1].max)
        attachments = render_attachments
        raw_row = attachments.size + editor_row
        lines = attachments + render_input_lines
        lines.concat(render_menu_lines) if menu_open?
        height = [@height.to_i, 1].max
        visible_row = raw_row - [lines.size - height, 0].max
        return nil if visible_row.negative? || visible_row >= height

        [visible_row, 2 + editor_col]
      end

      private def pending_guidance_lines
        @guidance_lines_provider&.call || []
      end

      private def render_attachments
        super + pending_guidance_lines.map do |line|
          used = 0
          clipped = line.each_char.take_while do |char|
            used += Unicode::DisplayWidth.of(char)
            used <= [inner_width - 1, 0].max
          end.join
          clipped += "…" if clipped.length < line.length && inner_width.positive?
          clipped
        end
      end
    end
  end
end
