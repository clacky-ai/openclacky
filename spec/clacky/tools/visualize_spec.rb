# frozen_string_literal: true

RSpec.describe Clacky::Tools::Visualize do
  let(:store) { instance_double(Clacky::ArtifactStore) }
  let(:tool) { described_class.new(store: store) }

  it "stores a self-contained HTML fragment and exposes an artifact UI payload" do
    allow(store).to receive(:write).with("<button>Go</button>").and_return(
      id: "a" * 64,
      bytes: 19
    )

    result = tool.execute(title: "Demo", html: "<button>Go</button>", height: 500)

    expect(result).to include(artifact_id: "a" * 64, title: "Demo", height: 500, bytes: 19, error: nil)
    expect(tool.ui_result(result)).to eq(
      type: "artifact",
      kind: "html",
      artifact_id: "a" * 64,
      title: "Demo",
      height: 500
    )
  end

  it "clamps requested height to the supported range" do
    allow(store).to receive(:write).and_return(id: "b" * 64, bytes: 1)

    expect(tool.execute(title: "Small", html: "x", height: 10)[:height]).to eq(240)
    expect(tool.execute(title: "Large", html: "x", height: 5_000)[:height]).to eq(720)
  end

  it "does not expose a UI payload when storage fails" do
    allow(store).to receive(:write).and_raise(Clacky::ArtifactStore::Error, "too large")

    result = tool.execute(title: "Demo", html: "x")

    expect(result).to eq(error: "too large")
    expect(tool.ui_result(result)).to be_nil
  end

  it "describes the no-network, text-fallback contract to the model" do
    description = tool.description

    expect(description).to match(/include the key conclusion in your text\s+response/)
    expect(description).to include("must not depend on external")
  end
end
