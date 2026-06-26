# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "clacky/media/dashscope"

RSpec.describe Clacky::Media::DashScope do
  let(:entry) do
    {
      "model"    => "qwen-image-2.0-pro",
      "base_url" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "api_key"  => "sk-test-key"
    }
  end
  let(:provider) { described_class.new(entry) }

  let(:fake_conn) { instance_double(Faraday::Connection) }

  before do
    allow(provider).to receive(:connection).and_return(fake_conn)
    allow(provider).to receive(:download_url).and_return("RAW_BYTES")
  end

  describe "#generate_image" do
    let(:response_body) do
      JSON.generate({
        "output" => {
          "choices" => [
            { "finish_reason" => "stop",
              "message" => { "role" => "assistant",
                             "content" => [{ "image" => "https://oss.example.com/x.png?Expires=1" }] } }
          ]
        },
        "usage"      => { "width" => 2048, "height" => 2048, "image_count" => 1 },
        "request_id" => "req-123"
      })
    end

    before do
      allow(fake_conn).to receive(:post).with("/api/v1/services/aigc/multimodal-generation/generation") do |&blk|
        req = double("req")
        allow(req).to receive(:headers).and_return({})
        expect(req).to receive(:body=) do |body|
          @captured_body = body
        end
        blk.call(req)
        instance_double(Faraday::Response, success?: true, status: 200, body: response_body)
      end
    end

    it "posts the DashScope generation envelope and saves the downloaded image" do
      Dir.mktmpdir do |tmp|
        result = provider.generate_image(prompt: "a cute cat", aspect_ratio: "square", output_dir: tmp)

        # request envelope
        sent = JSON.parse(@captured_body)
        expect(sent["model"]).to eq("qwen-image-2.0-pro")
        expect(sent.dig("input", "messages", 0, "role")).to eq("user")
        expect(sent.dig("input", "messages", 0, "content", 0, "text")).to eq("a cute cat")
        expect(sent.dig("parameters", "size")).to eq("2048*2048")
        expect(sent.dig("parameters", "n")).to eq(1)

        # response
        expect(result["success"]).to be true
        expect(result["image"]).to start_with(File.join(tmp, "assets", "generated"))
        expect(File.binread(result["image"])).to eq("RAW_BYTES")
        expect(result["provider"]).to eq("qwen")
        expect(result["model"]).to eq("qwen-image-2.0-pro")
        expect(result["size"]).to eq("2048*2048")
        expect(result["request_id"]).to eq("req-123")
      end
    end

    it "maps landscape/portrait to qwen-image-2.0 recommended sizes" do
      Dir.mktmpdir do |tmp|
        expect(provider.generate_image(prompt: "x", aspect_ratio: "landscape", output_dir: tmp)["size"]).to eq("2688*1536")
        expect(provider.generate_image(prompt: "x", aspect_ratio: "portrait", output_dir: tmp)["size"]).to eq("1536*2688")
      end
    end

    it "uses the fixed resolution set for qwen-image-max models" do
      max_provider = described_class.new(entry.merge("model" => "qwen-image-max"))
      allow(max_provider).to receive(:connection).and_return(fake_conn)
      allow(max_provider).to receive(:download_url).and_return("RAW_BYTES")

      allow(fake_conn).to receive(:post).with("/api/v1/services/aigc/multimodal-generation/generation") do |&blk|
        req = double("req")
        allow(req).to receive(:headers).and_return({})
        expect(req).to receive(:body=) do |body|
          @captured_body = body
        end
        blk.call(req)
        instance_double(Faraday::Response, success?: true, status: 200, body: response_body)
      end

      Dir.mktmpdir do |tmp|
        result = max_provider.generate_image(prompt: "x", aspect_ratio: "landscape", output_dir: tmp)
        expect(result["size"]).to eq("1664*928")
        expect(JSON.parse(@captured_body).dig("parameters", "size")).to eq("1664*928")
      end
    end
  end

  describe "#generate_speech" do
    let(:speech_entry) do
      entry.merge("model" => "cosyvoice-v3-flash")
    end
    let(:speech_provider) { described_class.new(speech_entry) }

    before do
      allow(speech_provider).to receive(:connection).and_return(fake_conn)
      allow(speech_provider).to receive(:download_url).and_return("AUDIO_BYTES")
    end

    context "with valid input" do
      let(:response_body) do
        JSON.generate({
          "output" => {
            "audio" => {
              "url" => "https://oss.example.com/speech.wav"
            }
          },
          "request_id" => "req-speech-123"
        })
      end

      it "calls the cosyvoice tts endpoint and saves the generated audio" do
        expect(fake_conn).to receive(:post).with("/api/v1/services/audio/tts/SpeechSynthesizer") do |&blk|
          req = double("req")
          headers = {}
          allow(req).to receive(:headers).and_return(headers)
          expect(req).to receive(:body=) do |body|
            @captured_body = body
          end
          blk.call(req)
          expect(headers["Content-Type"]).to eq("application/json")
          expect(headers["Authorization"]).to eq("Bearer sk-test-key")
          instance_double(Faraday::Response, success?: true, status: 200, body: response_body)
        end

        Dir.mktmpdir do |tmp|
          result = speech_provider.generate_speech(input: "hello world", voice: "longanyang", output_dir: tmp)

          expect(result["success"]).to be true
          expect(result["audio"]).to start_with(File.join(tmp, "assets", "generated"))
          expect(File.binread(result["audio"])).to eq("AUDIO_BYTES")
          expect(result["provider"]).to eq("qwen")
          expect(result["model"]).to eq("cosyvoice-v3-flash")
          expect(result["voice"]).to eq("longanyang")
          expect(result["request_id"]).to eq("req-speech-123")

          sent = JSON.parse(@captured_body)
          expect(sent["model"]).to eq("cosyvoice-v3-flash")
          expect(sent.dig("input", "text")).to eq("hello world")
          expect(sent.dig("input", "voice")).to eq("longanyang")
          expect(sent.dig("input", "format")).to eq("wav")
        end
      end
    end

    context "with a Qwen3-TTS model" do
      let(:qwen_entry) { entry.merge("model" => "qwen3-tts-flash") }
      let(:qwen_provider) { described_class.new(qwen_entry) }

      before do
        allow(qwen_provider).to receive(:connection).and_return(fake_conn)
        allow(qwen_provider).to receive(:download_url).and_return("AUDIO_BYTES")
      end

      let(:response_body) do
        JSON.generate({
          "output" => {
            "audio" => {
              "url" => "https://oss.example.com/speech.wav"
            }
          },
          "request_id" => "req-qwen-tts-1"
        })
      end

      it "routes to the multimodal-generation endpoint and builds the Qwen3-TTS payload" do
        expect(fake_conn).to receive(:post).with("/api/v1/services/aigc/multimodal-generation/generation") do |&blk|
          req = double("req")
          headers = {}
          allow(req).to receive(:headers).and_return(headers)
          expect(req).to receive(:body=) do |body|
            @captured_body = body
          end
          blk.call(req)
          instance_double(Faraday::Response, success?: true, status: 200, body: response_body)
        end

        Dir.mktmpdir do |tmp|
          result = qwen_provider.generate_speech(input: "你好", output_dir: tmp)

          expect(result["success"]).to be true
          expect(result["voice"]).to eq("Cherry") # default for Qwen3-TTS

          sent = JSON.parse(@captured_body)
          expect(sent["model"]).to eq("qwen3-tts-flash")
          expect(sent.dig("input", "text")).to eq("你好")
          expect(sent.dig("input", "voice")).to eq("Cherry")
          expect(sent.dig("input", "language_type")).to eq("Chinese")
          # Qwen3-TTS must NOT send format/sample_rate (those are CosyVoice-only)
          expect(sent.dig("input", "format")).to be_nil
          expect(sent.dig("input", "sample_rate")).to be_nil
        end
      end

      it "honors an explicit voice and language_type" do
        expect(fake_conn).to receive(:post).with("/api/v1/services/aigc/multimodal-generation/generation") do |&blk|
          req = double("req")
          allow(req).to receive(:headers).and_return({})
          expect(req).to receive(:body=) do |body|
            @captured_body = body
          end
          blk.call(req)
          instance_double(Faraday::Response, success?: true, status: 200, body: response_body)
        end

        Dir.mktmpdir do |tmp|
          qwen_provider.generate_speech(input: "hello", voice: "Ethan", language_type: "English", output_dir: tmp)

          sent = JSON.parse(@captured_body)
          expect(sent.dig("input", "voice")).to eq("Ethan")
          expect(sent.dig("input", "language_type")).to eq("English")
        end
      end
    end

    context "validation and errors" do
      it "rejects empty input" do
        result = speech_provider.generate_speech(input: "  ")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_argument")
      end

      it "rejects empty api_key" do
        no_key = described_class.new(speech_entry.merge("api_key" => ""))
        result = no_key.generate_speech(input: "hello")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("auth_required")
      end

      it "surfaces business error payloads" do
        err_body = JSON.generate({ "code" => "Forbidden", "message" => "Access denied" })
        expect(fake_conn).to receive(:post).and_return(instance_double(Faraday::Response, success?: true, status: 200, body: err_body))

        result = speech_provider.generate_speech(input: "hello")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("api_error")
        expect(result["error"]).to include("Forbidden")
      end
    end
  end

  describe "#generate_video" do
    let(:video_entry) do
      entry.merge("model" => "happyhorse-1.1-t2v")
    end
    let(:video_provider) { described_class.new(video_entry) }

    before do
      allow(video_provider).to receive(:connection).and_return(fake_conn)
      allow(video_provider).to receive(:download_url).and_return("VIDEO_BYTES")
      allow(video_provider).to receive(:sleep) # avoid real sleeping during tests
    end

    context "with successful asynchronous polling" do
      let(:submit_response) do
        JSON.generate({
          "output" => {
            "task_id" => "task-999",
            "task_status" => "PENDING"
          },
          "request_id" => "req-vid-1"
        })
      end

      let(:poll_response_running) do
        JSON.generate({
          "output" => {
            "task_id" => "task-999",
            "task_status" => "RUNNING"
          }
        })
      end

      let(:poll_response_succeeded) do
        JSON.generate({
          "output" => {
            "task_id" => "task-999",
            "task_status" => "SUCCEEDED",
            "video_url" => "https://oss.example.com/result.mp4"
          }
        })
      end

      it "submits task with async header and polls until SUCCEEDED" do
        expect(fake_conn).to receive(:post).with("/api/v1/services/aigc/video-generation/video-synthesis") do |&blk|
          req = double("req")
          headers = {}
          allow(req).to receive(:headers).and_return(headers)
          expect(req).to receive(:body=) do |body|
            @captured_body = body
          end
          blk.call(req)
          expect(headers["X-DashScope-Async"]).to eq("enable")
          instance_double(Faraday::Response, success?: true, status: 200, body: submit_response)
        end

        expect(fake_conn).to receive(:get).with("/api/v1/tasks/task-999").twice.and_return(
          instance_double(Faraday::Response, success?: true, body: poll_response_running),
          instance_double(Faraday::Response, success?: true, body: poll_response_succeeded)
        )

        Dir.mktmpdir do |tmp|
          result = video_provider.generate_video(prompt: "a horse running", aspect_ratio: "landscape", output_dir: tmp)

          expect(result["success"]).to be true
          expect(result["video"]).to start_with(File.join(tmp, "assets", "generated"))
          expect(File.binread(result["video"])).to eq("VIDEO_BYTES")
          expect(result["provider"]).to eq("qwen")
          expect(result["model"]).to eq("happyhorse-1.1-t2v")
          expect(result["request_id"]).to eq("req-vid-1")

          sent = JSON.parse(@captured_body)
          expect(sent.dig("parameters", "ratio")).to eq("16:9")
        end
      end
    end

    context "when polling fails or errors out" do
      let(:submit_response) do
        JSON.generate({ "output" => { "task_id" => "task-999" } })
      end

      let(:poll_response_failed) do
        JSON.generate({
          "output" => {
            "task_status" => "FAILED",
            "message" => "Inappropriate content"
          }
        })
      end

      it "surfaces task failure during polling" do
        allow(fake_conn).to receive(:post).and_return(instance_double(Faraday::Response, success?: true, status: 200, body: submit_response))
        expect(fake_conn).to receive(:get).with("/api/v1/tasks/task-999").and_return(
          instance_double(Faraday::Response, success?: true, body: poll_response_failed)
        )

        result = video_provider.generate_video(prompt: "abc")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("polling_failed")
        expect(result["error"]).to include("Inappropriate content")
      end
    end
  end

  describe "validation" do
    before do
      # Mock post for standard error validation paths
      allow(fake_conn).to receive(:post).and_return(instance_double(Faraday::Response, success?: true, status: 200, body: "{}"))
    end

    it "rejects an empty prompt without calling upstream" do
      expect(fake_conn).not_to receive(:post)
      result = provider.generate_image(prompt: "   ", output_dir: Dir.pwd)
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("invalid_argument")
    end

    it "rejects a missing api_key without calling upstream" do
      no_key = described_class.new(entry.merge("api_key" => ""))
      allow(no_key).to receive(:connection).and_return(fake_conn)
      expect(fake_conn).not_to receive(:post)
      result = no_key.generate_image(prompt: "x", output_dir: Dir.pwd)
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("auth_required")
    end
  end

  describe "error handling" do
    context "with a DashScope business error payload" do
      let(:response_body) { JSON.generate({ "code" => "InvalidParameter", "message" => "num_images_per_prompt must be 1", "request_id" => "r1" }) }

      before do
        allow(fake_conn).to receive(:post).and_return(instance_double(Faraday::Response, success?: true, status: 200, body: response_body))
      end

      it "surfaces code and message as an api_error" do
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("api_error")
        expect(result["error"]).to include("InvalidParameter")
        expect(result["error"]).to include("num_images_per_prompt")
      end
    end

    context "with an empty choices payload" do
      let(:response_body) { JSON.generate({ "output" => { "choices" => [] } }) }

      before do
        allow(fake_conn).to receive(:post).and_return(instance_double(Faraday::Response, success?: true, status: 200, body: response_body))
      end

      it "returns empty_response" do
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("empty_response")
      end
    end

    context "when the image download fails" do
      let(:response_body) do
        JSON.generate({ "output" => { "choices" => [{ "message" => { "content" => [{ "image" => "https://oss.example.com/x.png" }] } }] } })
      end

      before do
        allow(fake_conn).to receive(:post).and_return(instance_double(Faraday::Response, success?: true, status: 200, body: response_body))
      end

      it "returns download_failed" do
        allow(provider).to receive(:download_url).and_return(nil)
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("download_failed")
      end
    end

    context "with invalid JSON" do
      let(:response_body) { "<html>500</html>" }

      before do
        allow(fake_conn).to receive(:post).and_return(instance_double(Faraday::Response, success?: true, status: 200, body: response_body))
      end

      it "returns invalid_response" do
        result = provider.generate_image(prompt: "x", output_dir: Dir.pwd)
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_response")
      end
    end
  end

  describe "#endpoint_base" do
    it "derives scheme+host, discarding the pasted compatible-mode path" do
      expect(provider.send(:endpoint_base)).to eq("https://dashscope.aliyuncs.com")
    end

    it "handles the intl host" do
      p = described_class.new(entry.merge("base_url" => "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"))
      expect(p.send(:endpoint_base)).to eq("https://dashscope-intl.aliyuncs.com")
    end
  end
end
