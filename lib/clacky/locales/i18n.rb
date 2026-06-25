# frozen_string_literal: true

require_relative "en"
require_relative "zh"

module Clacky
  module I18n
    LOCALES = {
      "zh" => Clacky::Locales::ZH,
      "en" => Clacky::Locales::EN
    }.freeze

    def self.t(key, **vars)
      table = LOCALES[locale] || LOCALES["en"]
      msg   = table[key] || LOCALES["en"][key] || key
      vars.empty? ? msg : format(msg, **vars)
    end

    def self.locale
      return Thread.current[:lang] if Thread.current[:lang]

      lang = ENV["LC_ALL"] || ENV["LC_MESSAGES"] || ENV["LANG"] || ""
      lang.match?(/\Azh/i) ? "zh" : "en"
    end
  end
end
