# frozen_string_literal: true

module Clacky
  # Resolves extension-provided agent runtime classes only when they are used.
  class AgentRuntimeRegistry
    class Error < StandardError; end
    class DuplicateRuntimeError < Error; end
    class UnknownRuntimeError < Error; end
    class AdapterLoadError < Error; end
    class RuntimeClassError < Error; end
    class InvalidFactoryError < Error; end

    Entry = Struct.new(
      :id,
      :adapter_abs,
      :class_name,
      :factory,
      keyword_init: true
    )

    def initialize(extension_units: nil, factories: {})
      @entries = {}
      @load_mutex = Mutex.new

      units = extension_units.nil? ? default_extension_units : Array(extension_units)
      units.each { |unit| register_unit(unit) }
      register_factories(factories)
    end

    def registered?(runtime_id)
      @entries.key?(runtime_id.to_s)
    end

    def build(runtime_id, **kwargs)
      id = runtime_id.to_s
      entry = @entries[id]
      raise UnknownRuntimeError, "unknown agent runtime id: #{id}" unless entry

      factory = resolve_factory(entry)
      instantiate(factory, id, kwargs)
    end

    # Shut down process-lifetime resources for factories that were actually
    # resolved during this server run. Unused extension classes remain lazy.
    def shutdown
      factories = @load_mutex.synchronize do
        @entries.values.map(&:factory).compact.uniq
      end
      factories.each do |factory|
        factory.shutdown if factory.respond_to?(:shutdown)
      rescue StandardError => e
        Clacky::Logger.warn(
          "[AgentRuntimeRegistry] shutdown failed: #{e.class}: #{e.message}"
        ) if defined?(Clacky::Logger)
      end
      nil
    end

    private def register_unit(unit)
      id = unit.id.to_s
      raise DuplicateRuntimeError, "duplicate agent runtime id: #{id}" if @entries.key?(id)

      spec = unit.spec
      raise ArgumentError, "agent runtime descriptor must be a hash" unless spec.is_a?(Hash)

      @entries[id] = Entry.new(
        id: id,
        adapter_abs: copied_string(spec["adapter_abs"] || spec[:adapter_abs]),
        class_name: copied_string(spec["class"] || spec[:class]),
        factory: nil
      )
    end

    private def register_factories(factories)
      normalized = {}
      factories.each do |runtime_id, factory|
        id = runtime_id.to_s
        if normalized.key?(id)
          raise DuplicateRuntimeError, "duplicate agent runtime id: #{id}"
        end
        normalized[id] = factory
      end

      normalized.each do |id, factory|
        entry = @entries[id]
        if entry
          entry.factory = factory
        else
          @entries[id] = Entry.new(id: id, factory: factory)
        end
      end
    end

    private def resolve_factory(entry)
      return entry.factory if entry.factory

      @load_mutex.synchronize do
        entry.factory ||= load_runtime_class(entry)
      end
    end

    private def load_runtime_class(entry)
      begin
        unless entry.adapter_abs && !entry.adapter_abs.empty?
          raise LoadError, "adapter path is missing"
        end
        require entry.adapter_abs
      rescue ScriptError, StandardError => e
        raise AdapterLoadError,
              "failed to load agent runtime #{entry.id}: #{e.class}: #{e.message}"
      end

      resolve_runtime_class(entry)
    end

    private def resolve_runtime_class(entry)
      class_name = entry.class_name.to_s
      names = class_name.split("::").reject(&:empty?)
      unless !names.empty? && names.all? { |name| name.match?(/\A[A-Z]\w*\z/) }
        raise RuntimeClassError,
              "invalid agent runtime class for #{entry.id}: #{class_name.inspect}"
      end

      constant = names.inject(Object) do |namespace, name|
        namespace.const_get(name, false)
      end
      unless constant.is_a?(Class)
        raise RuntimeClassError,
              "agent runtime class is not a Class for #{entry.id}: #{class_name}"
      end

      constant
    rescue NameError, NoMethodError => e
      raise RuntimeClassError,
            "failed to resolve agent runtime class for #{entry.id}: #{class_name}: #{e.message}"
    end

    private def instantiate(factory, runtime_id, kwargs)
      if factory.is_a?(Class) || factory.respond_to?(:new)
        factory.new(**kwargs)
      elsif factory.respond_to?(:call)
        factory.call(**kwargs)
      else
        raise InvalidFactoryError, "invalid factory for agent runtime #{runtime_id}"
      end
    end

    private def default_extension_units
      result = Clacky::ExtensionLoader.last_result
      result.respond_to?(:agent_runtimes) ? Array(result.agent_runtimes) : []
    end

    private def copied_string(value)
      value && value.to_s.dup
    end
  end
end
