# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Clacky::Billing::MediaUsage do
  let(:billing_dir) { Dir.mktmpdir }

  around do |example|
    original = ENV["CLACKY_BILLING_DIR"]
    ENV["CLACKY_BILLING_DIR"] = billing_dir
    example.run
  ensure
    ENV["CLACKY_BILLING_DIR"] = original
    FileUtils.remove_entry(billing_dir) if Dir.exist?(billing_dir)
  end

  def rows
    Dir.glob(File.join(billing_dir, "*.jsonl")).flat_map do |file|
      File.readlines(file).map { |line| JSON.parse(line) }
    end
  end

  it "books an STT chunk with its audio duration and API-reported cost" do
    described_class.record(
      { "model" => "dsk-deepseek-asr", "provider" => "openclacky",
        "usage" => { "audio_seconds" => 12.5, "duration_ms" => 12_500 },
        "cost_usd" => 0.000395 },
      session_id: "sess-1", kind: "stt"
    )

    expect(rows.size).to eq(1)
    expect(rows.first).to include(
      "model" => "dsk-deepseek-asr",
      "provider" => "openclacky",
      "session_id" => "sess-1",
      "cost_source" => "api"
    )
    expect(rows.first["cost_usd"]).to be_within(1e-9).of(0.000395)
  end

  it "keeps a locally estimated cost marked as estimated" do
    described_class.record(
      { "model" => "deepseek-asr", "provider" => "deepseekv4",
        "usage" => { "audio_seconds" => 60 }, "cost_usd" => 0.0001,
        "cost_source" => "estimated" },
      kind: "stt"
    )

    expect(rows.first["cost_source"]).to eq("estimated")
  end

  it "writes nothing when the provider reports neither usage nor cost" do
    described_class.record({ "model" => "or-stt-gemini-3-8-flash", "provider" => "openclacky",
                             "text" => "hi" }, kind: "stt")

    expect(rows).to be_empty
  end

  it "infers the media kind from the result shape" do
    expect(described_class.infer_kind({ "audio" => "/tmp/a.wav" })).to eq("audio")
    expect(described_class.infer_kind({ "video" => "/tmp/a.mp4" })).to eq("video")
    expect(described_class.infer_kind({ "text" => "hi" })).to eq("stt")
    expect(described_class.infer_kind({ "image" => "/tmp/a.png" })).to eq("image")
  end
end
