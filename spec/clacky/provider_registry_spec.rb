# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ProviderRegistry do
  def provider_unit(id, spec)
    Clacky::ExtensionLoader::Unit.new(
      kind: :provider,
      id: id,
      ext_id: "test-extension",
      layer: :local,
      origin: "self",
      dir: "/tmp/test-extension",
      spec: spec
    )
  end

  it "preserves every built-in provider preset and its manifest order" do
    registry = described_class.new(extension_units: [])

    expect(registry.all).to eq(Clacky::Providers::PRESETS)
    expect(registry.all.keys).to eq(Clacky::Providers::PRESETS.keys)
  end

  it "appends extension providers in unit order with string descriptor keys" do
    presets = {
      "legacy" => {
        name: "Legacy",
        default_model: "legacy-model"
      }
    }
    units = [
      provider_unit("zeta", name: "Zeta", runtime_id: "zeta-runtime"),
      provider_unit(:alpha, "name" => "Alpha", "runtime_id" => "alpha-runtime")
    ]

    registry = described_class.new(presets: presets, extension_units: units)

    expect(registry.all.keys).to eq(%w[legacy zeta alpha])
    expect(registry["legacy"]).to eq(
      "name" => "Legacy",
      "default_model" => "legacy-model"
    )
    expect(registry["zeta"]).to eq(
      "name" => "Zeta",
      "runtime_id" => "zeta-runtime",
      "extension_id" => "test-extension"
    )
  end

  it "returns defensive copies from all, lookup, and fetch" do
    presets = {
      "legacy" => {
        "name" => "Legacy",
        "models" => ["legacy-model"]
      }
    }
    extension_spec = {
      "name" => "Runtime",
      "runtime_id" => "runtime",
      "capabilities" => { "vision" => true }
    }
    registry = described_class.new(
      presets: presets,
      extension_units: [provider_unit("runtime", extension_spec)]
    )

    registry.all["legacy"]["models"] << "mutated"
    registry["runtime"]["capabilities"]["vision"] = false
    registry.fetch("runtime")["name"].replace("Changed")
    presets["legacy"]["models"] << "changed-after-init"
    extension_spec["capabilities"]["vision"] = false

    expect(registry["legacy"]["models"]).to eq(["legacy-model"])
    expect(registry["runtime"]).to eq(
      "name" => "Runtime",
      "runtime_id" => "runtime",
      "capabilities" => { "vision" => true },
      "extension_id" => "test-extension"
    )
  end

  it "derives the extension route owner instead of trusting provider metadata" do
    registry = described_class.new(
      presets: {},
      extension_units: [
        provider_unit(
          "runtime-provider",
          "runtime_id" => "runtime-adapter",
          "extension_id" => "spoofed-extension"
        )
      ]
    )

    expect(registry["runtime-provider"]["extension_id"]).to eq("test-extension")
  end

  it "rejects an extension provider that collides with a built-in ID" do
    units = [provider_unit("legacy", "name" => "Replacement")]

    expect do
      described_class.new(
        presets: { "legacy" => { "name" => "Legacy" } },
        extension_units: units
      )
    end.to raise_error(
      Clacky::ProviderRegistry::DuplicateProviderError,
      /duplicate provider id: legacy/
    )
  end

  it "rejects duplicate extension provider IDs after string normalization" do
    units = [
      provider_unit(:runtime, "name" => "First"),
      provider_unit("runtime", "name" => "Second")
    ]

    expect do
      described_class.new(presets: {}, extension_units: units)
    end.to raise_error(
      Clacky::ProviderRegistry::DuplicateProviderError,
      /duplicate provider id: runtime/
    )
  end

  it "resolves a runtime ID from a provider ID" do
    units = [
      provider_unit("runtime", "name" => "Runtime", "runtime_id" => "agent-runtime"),
      provider_unit("api", "name" => "API")
    ]
    registry = described_class.new(presets: {}, extension_units: units)

    expect(registry.runtime_id_for("runtime")).to eq("agent-runtime")
    expect(registry.runtime_id_for(:runtime)).to eq("agent-runtime")
    expect(registry.runtime_id_for("api")).to be_nil
    expect(registry.runtime_id_for("missing")).to be_nil
  end

  it "distinguishes optional lookup from required fetch" do
    registry = described_class.new(presets: {}, extension_units: [])

    expect(registry["missing"]).to be_nil
    expect { registry.fetch("missing") }.to raise_error(
      Clacky::ProviderRegistry::UnknownProviderError,
      /unknown provider id: missing/
    )
  end
end
