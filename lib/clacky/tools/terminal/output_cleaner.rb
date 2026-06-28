# frozen_string_literal: true

module Clacky
  module Tools
    class Terminal < Base
      # Output cleaning for raw PTY bytes.
      #
      # A PTY emits whatever the child writes plus terminal control codes.
      # Since the Terminal tool is targeted at LINE-BASED interactive shells
      # (not full-screen TUIs like vim/top), we aggressively strip visual
      # control sequences rather than maintain a screen model.
      #
      # Cleaning steps (in order):
      #   1. Strip CSI sequences       (ESC[...letter)   — colors, cursor, SGR
      #   2. Strip OSC sequences       (ESC]...BEL/ST)   — window title, etc.
      #   3. Strip simple 2-byte esc   (ESC= / ESC>)     — keypad modes
      #   4. Collapse \r-overwrites    (spinner/progress)
      #   5. Drop backspace erase      (char + \x08)
      #   6. Normalize CRLF → LF
      #
      # This is lossy for full-screen apps (you'll see a pile of text without
      # cursor positioning), but for line-based commands it yields clean,
      # diff-friendly output.
      module OutputCleaner
        CSI_REGEX        = /\e\[[\d;?]*[a-zA-Z@]/.freeze
        OSC_REGEX        = /\e\].*?(\a|\e\\)/m.freeze
        SIMPLE_ESC_REGEX = /\e[=>\(\)].?/.freeze
        BACKSPACE_REGEX  = /[^\x08]\x08/.freeze

        module_function

        # Clean raw PTY bytes for LLM consumption.
        # @param raw [String] raw PTY bytes
        # @return [String] cleaned, UTF-8-safe text
        def clean(raw)
          return "" if raw.nil? || raw.empty?

          s = Clacky::Utils::Encoding.pty_to_utf8(raw)

          s = s.gsub(CSI_REGEX, "")
          s = s.gsub(OSC_REGEX, "")
          s = s.gsub(SIMPLE_ESC_REGEX, "")

          # Handle \r overwrites within each line. "50%\r100%" → "100%".
          # Split on \n KEEPING the terminators (-1 preserves trailing empty),
          # then for each segment keep only the portion after the last \r
          # (which is what would actually be visible).
          s = s.split("\n", -1).map { |line| line.split("\r").last || "" }.join("\n")

          # Erase "X\b" pairs repeatedly (readline rubout).
          s = s.gsub(BACKSPACE_REGEX, "") while s =~ BACKSPACE_REGEX

          # Normalize any leftover isolated \r.
          s = s.gsub(/\r/, "")

          s
        end
      end
    end
  end
end
