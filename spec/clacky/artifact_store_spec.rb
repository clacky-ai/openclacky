# frozen_string_literal: true

RSpec.describe Clacky::ArtifactStore do
  let(:root) { Dir.mktmpdir("clacky_artifacts_spec") }
  let(:store) { described_class.new(root: root) }

  after { FileUtils.rm_rf(root) }

  it "stores HTML by content hash and reuses identical content" do
    html = "<button>Click</button>"

    first = store.write(html)
    second = store.write(html)

    expect(first).to eq(second)
    expect(first[:id]).to match(/\A[0-9a-f]{64}\z/)
    expect(store.read(first[:id])).to eq(html)
    expect(Dir.children(root).grep(/\.html\z/).size).to eq(1)
  end

  it "rejects empty, invalid, and oversized content" do
    expect { store.write("  ") }.to raise_error(described_class::Error, /empty/)
    invalid_utf8 = "\xFF".dup.force_encoding(Encoding::UTF_8)
    expect { store.write(invalid_utf8) }.to raise_error(described_class::Error, /UTF-8/)
    expect { store.write("x" * (described_class::MAX_BYTES + 1)) }.to raise_error(described_class::Error, /exceeds/)
  end

  it "rejects path-like artifact identifiers" do
    expect(store.read("../secret")).to be_nil
    expect(store.read("a" * 63)).to be_nil
  end
end
