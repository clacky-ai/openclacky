# frozen_string_literal: true

module Clacky
  # Combines built-in provider presets with enabled extension contributions.
  class ProviderRegistry
    class Error < StandardError; end
    class DuplicateProviderError < Error; end
    class UnknownProviderError < Error; end

    def initialize(presets: Providers::PRESETS, extension_units: nil)
      @providers = {}

      presets.each do |id, descriptor|
        add(id, descriptor)
      end

      units = extension_units.nil? ? default_extension_units : Array(extension_units)
      units.each do |unit|
        add(unit.id, unit.spec, extension_id: unit.ext_id)
      end
    end

    def all
      deep_copy(@providers)
    end

    def [](provider_id)
      descriptor = @providers[provider_id.to_s]
      descriptor && deep_copy(descriptor)
    end

    def fetch(provider_id)
      self[provider_id] || raise(
        UnknownProviderError,
        "unknown provider id: #{provider_id}"
      )
    end

    def runtime_id_for(provider_id)
      descriptor = @providers[provider_id.to_s]
      runtime_id = descriptor && descriptor["runtime_id"]
      runtime_id && deep_copy(runtime_id)
    end

    private def add(id, descriptor, extension_id: nil)
      provider_id = id.to_s
      if @providers.key?(provider_id)
        raise DuplicateProviderError, "duplicate provider id: #{provider_id}"
      end

      normalized = normalize_descriptor(descriptor)
      # Extension HTTP routes are namespaced by the contributing extension,
      # which is not required to match the provider or runtime id. Derive this
      # server-side instead of trusting a manifest-supplied routing field.
      normalized["extension_id"] = extension_id.to_s unless extension_id.nil?
      @providers[provider_id] = normalized
    end

    private def normalize_descriptor(descriptor)
      unless descriptor.is_a?(Hash)
        raise ArgumentError, "provider descriptor must be a hash"
      end

      descriptor.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_s] = deep_copy(value)
      end
    end

    private def default_extension_units
      result = Clacky::ExtensionLoader.last_result
      result.respond_to?(:providers) ? Array(result.providers) : []
    end

    private def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          copy[deep_copy(key)] = deep_copy(item)
        end
      when Array
        value.map { |item| deep_copy(item) }
      else
        begin
          value.dup
        rescue TypeError
          value
        end
      end
    end
  end
end
