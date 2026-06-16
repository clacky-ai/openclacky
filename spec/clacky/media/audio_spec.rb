# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "base64"
require "clacky/media/openai_compat"

RSpec.describe Clacky::Media::OpenAICompat, "#generate_speech" do
  let(:entry) do
    {
      "model"    => "or-tts-gemini-2-5-flash",
      "base_url" => "https://api.openclacky.com",
      "api_key"  => "clacky-test-key"
    }
  end
  let(:provider) { described_class.new(entry) }

  let(:fake_conn) { instance_double(Faraday::Connection) }
  let(:fake_response) { instance_double(Faraday::Response, success?: success, status: status, body: response_body) }
  let(:success) { true }
  let(:status) { 200 }

  before do
    allow(provider).to receive(:audio_connection).and_return(fake_conn)
    allow(fake_conn).to receive(:post).and_yield(double("req").tap do |r|
      allow(r).to receive(:headers).and_return({})
      allow(r).to receive(:body=)
    end).and_return(fake_response)
  end

  context "with a base64 wav payload" do
    let(:b64) { Base64.strict_encode64("WAV_BYTES") }
    let(:response_body) do
      JSON.generate({
        "data"     => [{ "b64_json" => b64, "mime_type" => "audio/wav" }],
        "voice"    => "Kore",
        "usage"    => { "prompt_tokens" => 12, "completion_tokens" => 480, "total_tokens" => 492 },
        "cost_usd" => 0.001260
      })
    end

    it "saves the wav under assets/generated and returns success" do
      Dir.mktmpdir do |tmp|
        result = provider.generate_speech(input: "hello world", output_dir: tmp)

        expect(result["success"]).to be true
        expect(result["audio"]).to start_with(File.join(tmp, "assets", "generated"))
        expect(result["audio"]).to end_with(".wav")
        expect(File.binread(result["audio"])).to eq("WAV_BYTES")
        expect(result["mime_type"]).to eq("audio/wav")
        expect(result["voice"]).to eq("Kore")
        expect(result["cost_usd"]).to eq(0.001260)
        expect(result["provider"]).to eq("openclacky")
        expect(result["model"]).to eq("or-tts-gemini-2-5-flash")
      end
    end

    it "passes the voice through to the upstream payload when provided" do
      expect(fake_conn).to receive(:post) do |&blk|
        req = double("req", headers: {})
        captured = nil
        allow(req).to receive(:body=) { |b| captured = b }
        blk.call(req)
        payload = JSON.parse(captured)
        expect(payload["voice"]).to eq("Puck")
        fake_response
      end
      Dir.mktmpdir { |tmp| provider.generate_speech(input: "x", voice: "Puck", output_dir: tmp) }
    end
  end

  context "validation and errors" do
    let(:response_body) { "{}" }

    it "rejects an empty input" do
      result = provider.generate_speech(input: "  ")
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("invalid_argument")
    end

    it "returns auth_required when api_key is blank" do
      provider = described_class.new(entry.merge("api_key" => ""))
      allow(provider).to receive(:audio_connection).and_return(fake_conn)
      result = provider.generate_speech(input: "x")
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("auth_required")
    end

    context "when upstream returns non-2xx" do
      let(:success) { false }
      let(:status) { 502 }
      let(:response_body) { "upstream boom" }

      it "surfaces an api_error" do
        result = provider.generate_speech(input: "x")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("api_error")
        expect(result["error"]).to include("502")
      end
    end

    context "when upstream returns no audio" do
      let(:response_body) { JSON.generate({ "data" => [] }) }

      it "returns empty_response" do
        result = provider.generate_speech(input: "x")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("empty_response")
      end
    end
  end
end
