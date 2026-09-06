# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "base64"
require "clacky/media/openai_compat"

RSpec.describe Clacky::Media::OpenAICompat do
  let(:entry) do
    {
      "model"    => "or-gpt-image-1",
      "base_url" => "https://api.openclacky.com",
      "api_key"  => "clacky-test-key"
    }
  end
  let(:provider) { described_class.new(entry) }

  let(:fake_conn) { instance_double(Faraday::Connection) }
  let(:fake_response) { instance_double(Faraday::Response, success?: true, status: 200, body: response_body) }

  before do
    allow(provider).to receive(:connection).and_return(fake_conn)
    allow(fake_conn).to receive(:post).and_yield(double("req").tap do |r|
      allow(r).to receive(:headers).and_return({})
      allow(r).to receive(:body=)
    end).and_return(fake_response)
  end

  describe "#generate_image" do
    context "with a base64 response payload" do
      let(:b64) { Base64.strict_encode64("PNG_BYTES") }
      let(:response_body) { JSON.generate({ "data" => [{ "b64_json" => b64 }] }) }

      it "saves the image directly under output_dir and returns success" do
        Dir.mktmpdir do |tmp|
          result = provider.generate_image(prompt: "a cute cat", aspect_ratio: "square", output_dir: tmp)

          expect(result["success"]).to be true
          expect(result["image"]).to start_with(tmp)
          expect(File.exist?(result["image"])).to be true
          expect(File.binread(result["image"])).to eq("PNG_BYTES")
          expect(result["size"]).to eq("1024x1024")
          expect(result["aspect_ratio"]).to eq("square")
          expect(result["provider"]).to eq("openclacky")
          expect(result["model"]).to eq("or-gpt-image-1")
        end
      end

      it "defaults to landscape and 1536x1024 when aspect_ratio is omitted" do
        Dir.mktmpdir do |tmp|
          result = provider.generate_image(prompt: "x", output_dir: tmp)
          expect(result["aspect_ratio"]).to eq("landscape")
          expect(result["size"]).to eq("1536x1024")
        end
      end

      it "falls back to landscape for unknown aspect_ratio values" do
        Dir.mktmpdir do |tmp|
          result = provider.generate_image(prompt: "x", aspect_ratio: "panoramic", output_dir: tmp)
          expect(result["aspect_ratio"]).to eq("landscape")
        end
      end
    end

    context "with a url-only response payload" do
      let(:response_body) { JSON.generate({ "data" => [{ "url" => "https://cdn.example.com/img.png" }] }) }

      it "returns the url as-is without writing to disk" do
        Dir.mktmpdir do |tmp|
          result = provider.generate_image(prompt: "x", output_dir: tmp)
          expect(result["success"]).to be true
          expect(result["image"]).to eq("https://cdn.example.com/img.png")
          expect(Dir.glob(File.join(tmp, "*"))).to be_empty
        end
      end
    end

    context "validation" do
      let(:response_body) { "{}" }

      it "rejects an empty prompt without making the upstream call" do
        expect(fake_conn).not_to receive(:post)
        result = provider.generate_image(prompt: "   ", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_argument")
      end

      it "rejects a missing api_key without making the upstream call" do
        provider_no_key = described_class.new(entry.merge("api_key" => ""))
        allow(provider_no_key).to receive(:connection).and_return(fake_conn)
        expect(fake_conn).not_to receive(:post)
        result = provider_no_key.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("auth_required")
      end
    end

    context "upstream failures" do
      context "non-2xx response" do
        let(:fake_response) { instance_double(Faraday::Response, success?: false, status: 401, body: '{"error":"bad key"}') }
        let(:response_body) { '{"error":"bad key"}' }

        it "returns api_error with the upstream status" do
          result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
          expect(result["success"]).to be false
          expect(result["error_type"]).to eq("api_error")
          expect(result["error"]).to include("401")
        end
      end

      context "network error" do
        let(:response_body) { "{}" }

        it "returns network_error" do
          allow(fake_conn).to receive(:post).and_raise(Faraday::ConnectionFailed.new("boom"))
          result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
          expect(result["success"]).to be false
          expect(result["error_type"]).to eq("network_error")
        end
      end

      context "empty data array" do
        let(:response_body) { JSON.generate({ "data" => [] }) }

        it "returns empty_response" do
          result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
          expect(result["success"]).to be false
          expect(result["error_type"]).to eq("empty_response")
        end
      end

      context "malformed JSON body" do
        let(:response_body) { "<html>500</html>" }

        it "returns invalid_response" do
          result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
          expect(result["success"]).to be false
          expect(result["error_type"]).to eq("invalid_response")
        end
      end

      context "data entry has neither b64_json nor url" do
        let(:response_body) { JSON.generate({ "data" => [{ "revised_prompt" => "..." }] }) }

        it "returns empty_response" do
          result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
          expect(result["success"]).to be false
          expect(result["error_type"]).to eq("empty_response")
        end
      end
    end

    context "request shape" do
      let(:response_body) { JSON.generate({ "data" => [{ "url" => "https://x/y.png" }] }) }

      it "sends the expected payload, auth header, and aspect-mapped size to /images/generations" do
        captured_body = nil
        captured_headers = {}
        req_double = double("req")
        allow(req_double).to receive(:headers).and_return(captured_headers)
        allow(req_double).to receive(:body=) { |b| captured_body = b }

        expect(fake_conn).to receive(:post).with("images/generations").and_yield(req_double).and_return(fake_response)

        provider.generate_image(prompt: "hello world", aspect_ratio: "portrait", output_dir: Dir.pwd)

        expect(captured_headers["Authorization"]).to eq("Bearer clacky-test-key")
        expect(captured_headers["Content-Type"]).to eq("application/json")
        body = JSON.parse(captured_body)
        expect(body).to include(
          "model"  => "or-gpt-image-1",
          "prompt" => "hello world",
          "size"   => "1024x1536",
          "n"      => 1
        )
        expect(body).not_to have_key("images")
      end
    end

    context "image editing (input image)" do
      let(:gemini_entry) do
        {
          "model"    => "or-gemini-3-1-flash-image",
          "base_url" => "https://api.openclacky.com",
          "api_key"  => "clacky-test-key"
        }
      end
      let(:editor) { described_class.new(gemini_entry) }
      let(:response_body) { JSON.generate({ "data" => [{ "b64_json" => Base64.strict_encode64("EDITED") }] }) }

      before do
        allow(editor).to receive(:connection).and_return(fake_conn)
      end

      it "reads a file path input and forwards it as a base64 data URL under `images`" do
        Dir.mktmpdir do |tmp|
          input_path = File.join(tmp, "input.png")
          File.binwrite(input_path, "ORIGINAL_PNG")

          captured_body = nil
          req_double = double("req")
          allow(req_double).to receive(:headers).and_return({})
          allow(req_double).to receive(:body=) { |b| captured_body = b }
          expect(fake_conn).to receive(:post).with("images/generations").and_yield(req_double).and_return(fake_response)

          result = editor.generate_image(prompt: "make it blue", image: input_path, output_dir: tmp)

          expect(result["success"]).to be true
          body = JSON.parse(captured_body)
          expected_b64 = Base64.strict_encode64("ORIGINAL_PNG")
          expect(body["images"]).to eq(["data:image/png;base64,#{expected_b64}"])
        end
      end

      it "passes through a data URL unchanged and supports multiple images" do
        Dir.mktmpdir do |tmp|
          data_url = "data:image/jpeg;base64,#{Base64.strict_encode64('A')}"
          bare_b64 = Base64.strict_encode64("B")

          captured_body = nil
          req_double = double("req")
          allow(req_double).to receive(:headers).and_return({})
          allow(req_double).to receive(:body=) { |b| captured_body = b }
          expect(fake_conn).to receive(:post).with("images/generations").and_yield(req_double).and_return(fake_response)

          editor.generate_image(prompt: "combine", images: [data_url, bare_b64], output_dir: tmp)

          body = JSON.parse(captured_body)
          expect(body["images"]).to eq([data_url, "data:image/png;base64,#{bare_b64}"])
        end
      end

      it "rejects an input that is neither a file nor valid base64" do
        result = editor.generate_image(prompt: "x", image: "@@@not-base64@@@", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_argument")
      end
    end
  end

  describe "#generate_transcription" do
    let(:response_body) { JSON.generate({ "text" => "hello world", "usage" => { "cost" => 0.0001 } }) }
    let(:fake_conn) { instance_double(Faraday::Connection) }
    let(:fake_response) { instance_double(Faraday::Response, success?: true, status: 200, body: response_body) }

    def stub_transcription(captured_holder, conn = fake_conn)
      req_double = double("req")
      allow(req_double).to receive(:headers).and_return({})
      allow(req_double).to receive(:body=) { |b| captured_holder[:body] = b }
      allow(conn).to receive(:post).with("audio/transcriptions").and_yield(req_double).and_return(fake_response)
      req_double
    end

    context "on the openclacky gateway (multipart only — JSON unsupported upstream)" do
      let(:entry) do
        { "model" => "or-stt-whisper", "base_url" => "https://api.openclacky.com", "api_key" => "clacky-k" }
      end

      it "falls back to multipart form-data until the gateway supports input_audio" do
        captured = {}
        req_double = stub_transcription(captured)
        allow(provider).to receive(:stt_connection).and_return(fake_conn)

        result = provider.generate_transcription(
          audio_base64: Base64.strict_encode64("RIFF....WAVE"),
          mime_type: "audio/wav"
        )

        expect(result["success"]).to be true
        expect(result["provider"]).to eq("openclacky")
        expect(req_double.headers["Content-Type"]).to start_with("multipart/form-data; boundary=")
        expect(captured[:body]).to include('name="file"; filename="chunk.wav"')
        expect(captured[:body]).to include("RIFF....WAVE")
      end

      it "passes through prompt in multipart form" do
        allow(provider).to receive(:stt_connection).and_return(fake_conn)
        captured = {}
        stub_transcription(captured)

        provider.generate_transcription(
          audio_base64: Base64.strict_encode64("RIFF"),
          mime_type: "audio/wav",
          prompt: "punctuation please"
        )
        expect(captured[:body]).to include('name="prompt"')
        expect(captured[:body]).to include("punctuation please")
      end
    end

    context "on OpenRouter" do
      let(:entry) do
        { "model" => "openai/whisper-large-v3-turbo", "base_url" => "https://openrouter.ai/api/v1", "api_key" => "or-k" }
      end

      it "uses base64 JSON so large files bypass the 25 MB multipart cap" do
        captured = {}
        allow(provider).to receive(:stt_json_connection).and_return(fake_conn)
        stub_transcription(captured)

        result = provider.generate_transcription(
          audio_base64: Base64.strict_encode64("RIFF....WAVE"),
          mime_type: "audio/wav"
        )

        expect(result["success"]).to be true
        body = JSON.parse(captured[:body])
        expect(body["model"]).to eq("openai/whisper-large-v3-turbo")
        expect(body.dig("input_audio", "data")).to eq(Base64.strict_encode64("RIFF....WAVE"))
        expect(body.dig("input_audio", "format")).to eq("wav")
      end

      it "maps audio/mp4 container to the m4a audio format" do
        captured = {}
        allow(provider).to receive(:stt_json_connection).and_return(fake_conn)
        stub_transcription(captured)

        provider.generate_transcription(audio_base64: Base64.strict_encode64("M4A"), mime_type: "audio/mp4")
        expect(JSON.parse(captured[:body]).dig("input_audio", "format")).to eq("m4a")
      end
    end

    context "on a generic OpenAI-style provider" do
      let(:entry) do
        { "model" => "whisper-1", "base_url" => "https://api.openai.com/v1", "api_key" => "sk-oai" }
      end

      it "falls back to multipart form-data" do
        allow(provider).to receive(:stt_connection).and_return(fake_conn)
        captured = {}
        req_double = stub_transcription(captured)

        result = provider.generate_transcription(
          audio_base64: Base64.strict_encode64("RIFF....WAVE"),
          mime_type: "audio/wav"
        )

        expect(result["success"]).to be true
        expect(req_double.headers["Content-Type"]).to start_with("multipart/form-data; boundary=")
        expect(captured[:body]).to include('name="file"; filename="chunk.wav"')
        expect(captured[:body]).to include("RIFF....WAVE")
        expect(captured[:body]).to include('name="model"')
      end
    end
  end

  describe "base_url normalization" do
    let(:response_body) { JSON.generate({ "data" => [{ "url" => "https://x/y.png" }] }) }

    it "uses the base_url verbatim when no /v1 suffix is present" do
      p = described_class.new(entry.merge("base_url" => "https://api.example.com"))
      conn = p.send(:connection)
      expect(conn.url_prefix.to_s).to eq("https://api.example.com/")
    end

    it "leaves an existing /v1 alone" do
      p = described_class.new(entry.merge("base_url" => "https://api.openai.com/v1"))
      conn = p.send(:connection)
      expect(conn.url_prefix.to_s).to eq("https://api.openai.com/v1/")
    end

    it "tolerates a trailing slash" do
      p = described_class.new(entry.merge("base_url" => "https://api.example.com/"))
      conn = p.send(:connection)
      expect(conn.url_prefix.to_s).to eq("https://api.example.com/")
    end
  end
end
