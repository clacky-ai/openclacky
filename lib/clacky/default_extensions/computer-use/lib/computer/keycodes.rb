# frozen_string_literal: true

module Clacky
  module Computer
    # macOS virtual keycodes (US layout, HIToolbox Events.h) plus the modifier
    # flag masks needed to turn "cmd+shift+t" into a real keystroke.
    module Keycodes
      FLAGS = {
        "caps_lock" => 1 << 16,
        "shift" => 1 << 17,
        "ctrl" => 1 << 18,
        "opt" => 1 << 19,
        "cmd" => 1 << 20,
        "fn" => 1 << 23
      }.freeze

      MODIFIER_ALIASES = {
        "command" => "cmd", "super" => "cmd", "meta" => "cmd",
        "control" => "ctrl",
        "option" => "opt", "alt" => "opt",
        "capslock" => "caps_lock", "caps" => "caps_lock"
      }.freeze

      # modifier name -> keycode of the left-hand variant (used by hold_key)
      MODIFIER_KEYCODES = {
        "cmd" => 55, "shift" => 56, "ctrl" => 59, "opt" => 58, "fn" => 63,
        "caps_lock" => 57
      }.freeze

      CODES = {}

      # [keycode, aliases...]
      RAW = [
        [0, "a"], [1, "s"], [2, "d"], [3, "f"], [4, "h"], [5, "g"], [6, "z"],
        [7, "x"], [8, "c"], [9, "v"], [11, "b"], [12, "q"], [13, "w"], [14, "e"],
        [15, "r"], [16, "y"], [17, "t"],
        [18, "1"], [19, "2"], [20, "3"], [21, "4"], [22, "6"], [23, "5"],
        [24, "equal", "=", "equals"], [25, "9"], [26, "7"], [27, "minus", "-"],
        [28, "8"], [29, "0"], [30, "right_bracket", "]"], [31, "o"], [32, "u"],
        [33, "left_bracket", "["], [34, "i"], [35, "p"],
        [36, "return", "enter"], [37, "l"], [38, "j"], [39, "quote", "'"],
        [40, "k"], [41, "semicolon", ";"], [42, "backslash", "\\"],
        [43, "comma", ","], [44, "slash", "/"], [45, "n"], [46, "m"],
        [47, "period", "."], [48, "tab"], [49, "space", "spacebar"],
        [50, "grave", "`"],
        [51, "delete", "backspace"], [53, "escape", "esc"],
        [54, "right_command", "right_cmd"], [55, "cmd", "command", "left_command", "left_cmd"],
        [56, "shift", "left_shift"], [57, "caps_lock", "capslock", "caps"],
        [58, "opt", "option", "alt", "left_option"], [59, "ctrl", "control", "left_control"],
        [60, "right_shift"], [61, "right_option"], [62, "right_control"], [63, "fn"],
        [65, "keypad_decimal"], [67, "keypad_multiply"], [69, "keypad_plus"],
        [71, "keypad_clear"], [75, "keypad_divide"], [76, "keypad_enter"],
        [78, "keypad_minus"], [81, "keypad_equals"],
        [82, "keypad_0"], [83, "keypad_1"], [84, "keypad_2"], [85, "keypad_3"],
        [86, "keypad_4"], [87, "keypad_5"], [88, "keypad_6"], [89, "keypad_7"],
        [91, "keypad_8"], [92, "keypad_9"],
        [96, "f5"], [97, "f6"], [98, "f7"], [99, "f3"], [100, "f8"], [101, "f9"],
        [103, "f11"], [105, "f13"], [106, "f16"], [107, "f14"], [109, "f10"],
        [111, "f12"], [113, "f15"], [114, "help"], [115, "home"], [116, "page_up", "pageup"],
        [117, "forward_delete"], [118, "f4"], [119, "end"], [120, "f2"],
        [121, "page_down", "pagedown"], [122, "f1"],
        [123, "left", "arrow_left"], [124, "right", "arrow_right"],
        [125, "down", "arrow_down"], [126, "up", "arrow_up"],
        [64, "f17"], [79, "f18"], [80, "f19"], [90, "f20"]
      ].freeze

      RAW.each do |code, *names|
        names.each { |n| CODES[n] = code }
      end

      # "cmd+shift+t" -> [["cmd", "shift"], "t"]; a plain "t" -> [[], "t"]
      def self.parse(combo)
        parts = combo.to_s.strip.downcase.split("+").map(&:strip).reject(&:empty?)
        key = parts.pop
        [parts.map { |p| normalize(p) }, key]
      end

      def self.code_for(name)
        CODES[name.to_s.strip.downcase]
      end

      def self.modifier?(name)
        FLAGS.key?(normalize(name))
      end

      def self.modifier_keycode(name)
        MODIFIER_KEYCODES[normalize(name)]
      end

      def self.flags_for(modifiers)
        Array(modifiers).map { |m| FLAGS[normalize(m)] || 0 }.inject(0) { |acc, f| acc | f }
      end

      def self.normalize(name)
        key = name.to_s.strip.downcase
        MODIFIER_ALIASES[key] || key
      end
    end
  end
end
