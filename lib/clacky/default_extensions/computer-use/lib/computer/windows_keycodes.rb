# frozen_string_literal: true

module Clacky
  module Computer
    # Windows virtual-key codes (winuser.h) for the combos `key` and `hold` accept.
    #
    # Windows has no modifier bitmask like CoreGraphics: a shortcut is performed
    # by pressing each modifier's own virtual key, tapping the main key, then
    # releasing the modifiers. So this module hands back VK numbers instead of a
    # combined flag word.
    #
    # Names follow the macOS keycodes module so one SKILL.md works on both
    # platforms; `cmd` maps to the Windows key, which is where the platform's
    # system-wide shortcuts live.
    module WindowsKeycodes
      MODIFIER_ALIASES = {
        "command" => "win", "cmd" => "win", "super" => "win", "meta" => "win",
        "control" => "ctrl",
        "option" => "alt", "menu" => "alt",
        "escape" => "esc",
        "return" => "enter",
        "spacebar" => "space",
        "capslock" => "caps_lock", "caps" => "caps_lock",
        "pageup" => "page_up",
        "pagedown" => "page_down",
        "arrow_left" => "left", "arrow_right" => "right",
        "arrow_up" => "up", "arrow_down" => "down"
      }.freeze

      # Left-hand variants; `hold` presses these and keeps them down.
      MODIFIERS = {
        "ctrl" => 0x11,
        "shift" => 0x10,
        "alt" => 0x12,
        "win" => 0x5B,
        "caps_lock" => 0x14
      }.freeze

      # Order matters: modifiers must go down before and up after the main key.
      MODIFIER_ORDER = %w[ctrl shift alt win].freeze

      CODES = {}

      # [virtual key, aliases...]
      RAW = [
        [0x08, "backspace"], [0x09, "tab"], [0x0D, "enter"],
        [0x10, "shift", "left_shift"], [0x11, "ctrl", "left_ctrl"],
        [0x12, "alt", "left_alt"], [0x13, "pause"],
        [0x14, "caps_lock", "capslock", "caps"], [0x1B, "esc"],
        [0x20, "space"], [0x21, "page_up"], [0x22, "page_down"],
        [0x23, "end"], [0x24, "home"], [0x25, "left"], [0x26, "up"],
        [0x27, "right"], [0x28, "down"], [0x2C, "print_screen"],
        [0x2D, "insert"], [0x2E, "delete"], [0x5B, "win", "lwin"],
        [0x5C, "rwin"], [0x5D, "apps", "menu_key"], [0x90, "num_lock"],
        [0x91, "scroll_lock"],
        [0x30, "0"], [0x31, "1"], [0x32, "2"], [0x33, "3"], [0x34, "4"],
        [0x35, "5"], [0x36, "6"], [0x37, "7"], [0x38, "8"], [0x39, "9"],
        [0x41, "a"], [0x42, "b"], [0x43, "c"], [0x44, "d"], [0x45, "e"],
        [0x46, "f"], [0x47, "g"], [0x48, "h"], [0x49, "i"], [0x4A, "j"],
        [0x4B, "k"], [0x4C, "l"], [0x4D, "m"], [0x4E, "n"], [0x4F, "o"],
        [0x50, "p"], [0x51, "q"], [0x52, "r"], [0x53, "s"], [0x54, "t"],
        [0x55, "u"], [0x56, "v"], [0x57, "w"], [0x58, "x"], [0x59, "y"],
        [0x5A, "z"],
        [0x60, "keypad_0"], [0x61, "keypad_1"], [0x62, "keypad_2"],
        [0x63, "keypad_3"], [0x64, "keypad_4"], [0x65, "keypad_5"],
        [0x66, "keypad_6"], [0x67, "keypad_7"], [0x68, "keypad_8"],
        [0x69, "keypad_9"], [0x6A, "keypad_multiply"],
        [0x6B, "keypad_add", "keypad_plus"], [0x6C, "keypad_separator"],
        [0x6D, "keypad_subtract", "keypad_minus"], [0x6E, "keypad_decimal"],
        [0x6F, "keypad_divide"],
        [0x70, "f1"], [0x71, "f2"], [0x72, "f3"], [0x73, "f4"],
        [0x74, "f5"], [0x75, "f6"], [0x76, "f7"], [0x77, "f8"],
        [0x78, "f9"], [0x79, "f10"], [0x7A, "f11"], [0x7B, "f12"],
        [0xBA, "semicolon", ";"], [0xBB, "equal", "=", "equals"],
        [0xBC, "comma", ","], [0xBD, "minus", "-"], [0xBE, "period", "."],
        [0xBF, "slash", "/"], [0xC0, "grave", "`"],
        [0xDB, "left_bracket", "["], [0xDC, "backslash", "\\"],
        [0xDD, "right_bracket", "]"], [0xDE, "quote", "'"]
      ].freeze

      RAW.each do |code, *names|
        names.each { |n| CODES[n] = code }
      end
      CODES.freeze

      # "ctrl+shift+t" -> [["ctrl", "shift"], "t"]; a plain "t" -> [[], "t"]
      def self.parse(combo)
        parts = combo.to_s.strip.downcase.split("+").map(&:strip).reject(&:empty?)
        key = parts.pop
        [parts.map { |p| normalize(p) }, key]
      end

      def self.code_for(name)
        key = name.to_s.strip.downcase
        CODES[key] || CODES[normalize(key)]
      end

      def self.modifier?(name)
        MODIFIERS.key?(normalize(name))
      end

      def self.modifier_vk(name)
        MODIFIERS[normalize(name)]
      end

      # Modifiers in the order they must be pressed; unknown names are dropped
      # so callers never post a zero VK.
      def self.modifier_vks(modifiers)
        normalized = modifiers.map { |name| normalize(name) }
        MODIFIER_ORDER.map { |name| MODIFIERS[name] if normalized.include?(name) }.compact
      end

      def self.normalize(name)
        key = name.to_s.strip.downcase
        MODIFIER_ALIASES[key] || key
      end
    end
  end
end
