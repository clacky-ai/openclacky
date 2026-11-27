# frozen_string_literal: true

module Clacky
  # Which reasoning stops actually change the outgoing request for a model.
  #
  # The wire formats collapse many of our six stops onto far fewer provider
  # values (GLM-5.3 accepts low/high/max only, MiniMax-M3 is a thinking on/off
  # switch, ...). Offering all six everywhere means the picker shows stops that
  # produce byte-identical requests, so the UI would react while the model does
  # not. This table is the single source of truth for what each family can
  # distinguish; MessageFormat adapters stay the source of truth for *how* a
  # stop is encoded, and ReasoningLevels must never claim a stop that an adapter
  # collapses into its neighbour.
  #
  # Invariant (enforced in spec/clacky/reasoning_levels_spec.rb): for the levels
  # returned here, any two different levels produce different request fields on
  # every transport the model can use.
  module ReasoningLevels
    ALL = %w[off low medium high xhigh max].freeze

    # Matching is anchored and ordered: the first entry that matches wins, so a
    # narrow family must come before the broader one it belongs to.
    FAMILIES = [
      # GLM-5.3 always thinks and accepts low/high/max only; the adapter maps
      # off/low/medium onto "low".
      [/\Aglm-5[-.]3/i, %w[low high max]],
      # Older GLM accepts thinking on/off plus a high/max effort; low and medium
      # both collapse onto "high".
      [/\Aglm-[45]/i, %w[off high max]],
      # Kimi K3 accepts low/high/max; a disabled thinking block is ignored, so
      # "off" is indistinguishable from "low".
      [/\A(kimi-)?k3/i, %w[low high max]],
      # MiniMax-M3.1-Flash rejects "none" and maps off onto its lightest effort.
      [/\Aminimax-m3[.]1-flash\z/i, %w[low medium high xhigh max]],
      # MiniMax-M3 is a binary switch: off disables thinking, everything else is
      # "adaptive" with no intensity.
      [/\Aminimax-m3\z/i, %w[off medium]],
      # MiMo-V2 is also binary ({type: enabled|disabled}).
      [/\Amimo-v2/i, %w[off medium]],
      # DeepSeek merges xhigh into max.
      [/deepseek/i, %w[off low medium high max]],
      # Gemini 4 always thinks, so there is no "off": Argon offers
      # low/medium/high (default medium), Hydrogen adds xhigh (default high).
      # Neither documents minimal, and Argon errors out on it. Matched without
      # an anchor because platform aliases carry an "or-" prefix.
      [/gemini-4-argon/i,     %w[low medium high]],
      [/gemini-4-hydrogen/i,  %w[low medium high xhigh]]
    ].freeze

    # Levels for a model, ascending. An empty array means the model has no
    # reasoning control at all, and a host should hide the control entirely.
    def self.for_model(model)
      name = model.to_s
      _, levels = FAMILIES.find { |pattern, _| name.match?(pattern) }
      levels || ALL
    end

    # Nearest stop this model can express. Keeps a session on a meaningful
    # level after it switches to a model with coarser granularity. A blank
    # level means "never chosen, use the provider default" and is left alone
    # (nil): for some models the default is the deepest level, so turning it
    # into "off" would silently change behaviour.
    def self.clamp(model, level)
      key = level.to_s.downcase
      return nil if key.empty?

      levels = for_model(model)
      return nil if levels.empty?
      return key if levels.include?(key)

      target = ALL.index(key) || 0
      levels.min_by { |l| (ALL.index(l) - target).abs }
    end
  end
end
