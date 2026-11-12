# frozen_string_literal: true

require_relative "en"
require_relative "zh"

module Clacky
  module I18n
    LOCALES = {
      "zh" => Clacky::Locales::ZH,
      "en" => Clacky::Locales::EN
    }.freeze
    DEFAULT_LOCALE = "en"

    def self.t(key, **vars)
      translate(locale, key, **vars)
    end

    def self.translate(code, key, **vars)
      table = LOCALES[code] || LOCALES[DEFAULT_LOCALE]
      msg   = table[key] || LOCALES[DEFAULT_LOCALE][key] || key
      vars.empty? ? msg : format(msg, **vars)
    end

    # Builds { locale_code => value } for every supported locale.
    def self.localized
      LOCALES.keys.map { |code| [code, yield(code)] }.to_h
    end

    def self.translations(key, **vars)
      localized { |code| translate(code, key, **vars) }
    end

    def self.supported?(code)
      LOCALES.key?(code.to_s)
    end

    # Collapses every regional variant onto its base code ("zh-CN" -> "zh",
    # "en_US.UTF-8" -> "en"). Returns nil for anything we have no table for.
    # This is the single place that decides what a language tag means.
    def self.normalize(code)
      code = code.to_s.strip.downcase
      return nil if code.empty?
      return code if supported?(code)

      base = code.split(/[-_.]/).first
      supported?(base) ? base : nil
    end

    def self.locale
      normalize(Thread.current[:lang]) || env_locale
    end

    # The first non-empty POSIX variable wins, so an empty LC_ALL must not
    # mask LANG. An unsupported value (fr_FR) falls back to the default
    # rather than letting a lower-priority variable decide.
    def self.env_locale
      raw = %w[LC_ALL LC_MESSAGES LANG].map { |key| ENV[key].to_s }
                                       .find { |value| !value.strip.empty? }
      normalize(raw) || DEFAULT_LOCALE
    end
  end
end
