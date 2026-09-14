# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::AgentRuntimeRegistry do
  let(:tmpdir) { Dir.mktmpdir("agent-runtime-registry") }

  after do
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
    if Clacky.const_defined?(:RegistrySpecLazyRuntime, false)
      Clacky.send(:remove_const, :RegistrySpecLazyRuntime)
    end
    if Clacky.const_defined?(:RegistrySpecWrongRuntime, false)
      Clacky.send(:remove_const, :RegistrySpecWrongRuntime)
    end
  end

  def runtime_unit(id, adapter:, class_name:)
    Clacky::ExtensionLoader::Unit.new(
      kind: :agent_runtime,
      id: id,
      ext_id: "test-extension",
      layer: :local,
      origin: "self",
      dir: File.dirname(adapter),
      spec: {
        "adapter_abs" => adapter,
        "class" => class_name
      }
    )
  end

  it "loads the adapter and resolves its exact class only when built" do
    adapter = File.join(tmpdir, "lazy_runtime.rb")
    File.write(adapter, <<~RUBY)
      module Clacky
        class RegistrySpecLazyRuntime
          attr_reader :options

          def initialize(**options)
            @options = options
          end
        end
      end
    RUBY
    unit = runtime_unit(
      "lazy",
      adapter: adapter,
      class_name: "Clacky::RegistrySpecLazyRuntime"
    )

    registry = described_class.new(extension_units: [unit])

    expect(Clacky.const_defined?(:RegistrySpecLazyRuntime, false)).to be(false)

    runtime = registry.build(
      "lazy",
      session_id: "session-1",
      working_dir: "/tmp/workspace"
    )

    expect(runtime).to be_a(Clacky::RegistrySpecLazyRuntime)
    expect(runtime.options).to eq(
      session_id: "session-1",
      working_dir: "/tmp/workspace"
    )
  end

  it "raises a dedicated error when the exact declared class is absent" do
    adapter = File.join(tmpdir, "wrong_runtime.rb")
    File.write(adapter, <<~RUBY)
      module Clacky
        class RegistrySpecWrongRuntime
        end
      end
    RUBY
    unit = runtime_unit(
      "wrong",
      adapter: adapter,
      class_name: "Clacky::RegistrySpecMissingRuntime"
    )
    registry = described_class.new(extension_units: [unit])

    expect { registry.build("wrong") }.to raise_error(
      Clacky::AgentRuntimeRegistry::RuntimeClassError,
      /Clacky::RegistrySpecMissingRuntime/
    )
  end

  it "raises a dedicated error for an unknown runtime ID" do
    registry = described_class.new(extension_units: [])

    expect(registry.registered?("missing")).to be(false)
    expect { registry.build("missing") }.to raise_error(
      Clacky::AgentRuntimeRegistry::UnknownRuntimeError,
      /unknown agent runtime id: missing/
    )
  end

  it "wraps adapter load failures with the runtime ID" do
    adapter = File.join(tmpdir, "missing_runtime.rb")
    unit = runtime_unit(
      "broken",
      adapter: adapter,
      class_name: "Clacky::RegistrySpecMissingRuntime"
    )
    registry = described_class.new(extension_units: [unit])

    expect { registry.build("broken") }.to raise_error(
      Clacky::AgentRuntimeRegistry::AdapterLoadError,
      /failed to load agent runtime broken/
    )
  end

  it "rejects duplicate extension runtime IDs after string normalization" do
    adapter = File.join(tmpdir, "runtime.rb")
    units = [
      runtime_unit(:duplicate, adapter: adapter, class_name: "One"),
      runtime_unit("duplicate", adapter: adapter, class_name: "Two")
    ]

    expect do
      described_class.new(extension_units: units)
    end.to raise_error(
      Clacky::AgentRuntimeRegistry::DuplicateRuntimeError,
      /duplicate agent runtime id: duplicate/
    )
  end

  it "uses an injected factory without loading the declared adapter" do
    calls = []
    factory = lambda do |**options|
      calls << options
      { "built_by" => "factory", "options" => options }
    end
    unit = runtime_unit(
      "injected",
      adapter: File.join(tmpdir, "must_not_load.rb"),
      class_name: "Clacky::MustNotLoad"
    )
    registry = described_class.new(
      extension_units: [unit],
      factories: { injected: factory }
    )

    runtime = registry.build(:injected, session_id: "session-2")

    expect(runtime).to eq(
      "built_by" => "factory",
      "options" => { session_id: "session-2" }
    )
    expect(calls).to eq([{ session_id: "session-2" }])
  end

  it "allows a factory-only runtime for isolated tests" do
    factory = lambda { |**options| options.fetch(:value) }
    registry = described_class.new(
      extension_units: [],
      factories: { "fake" => factory }
    )

    expect(registry.registered?(:fake)).to be(true)
    expect(registry.build("fake", value: "result")).to eq("result")
  end

  it "shuts down only factories that were resolved during the server run" do
    factory = Class.new do
      class << self
        attr_accessor :shutdown_calls

        def shutdown
          self.shutdown_calls = shutdown_calls.to_i + 1
        end
      end

      def initialize(**_options); end
    end
    factory.shutdown_calls = 0
    registry = described_class.new(
      extension_units: [], factories: { "fake" => factory }
    )
    registry.build("fake")

    expect { registry.shutdown }
      .to change(factory, :shutdown_calls).from(0).to(1)
  end
end
