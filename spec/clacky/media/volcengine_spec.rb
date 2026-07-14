# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "base64"
require "clacky/media/volcengine"

RSpec.describe Clacky::Media::Volcengine do
  let(:entry) do
    {
      "model"    => "doubao-seedance-2-0-260128",
      "base_url" => "https://ark.cn-beijing.volces.com/api/v3",
      "api_key"  => "ark-test-key"
    }
  end
  let(:provider) { described_class.new(entry) }
  let(:fake_conn) { instance_double(Faraday::Connection) }

  let(:submit_response) { JSON.generate({ "id" => "cgt-123" }) }
  let(:status_running)    { JSON.generate({ "id" => "cgt-123", "status" => "running" }) }
  let(:status_succeeded) do
    JSON.generate({
      "id"      => "cgt-123",
      "status"  => "succeeded",
      "content" => { "video_url" => "https://tos.example.com/result.mp4" }
    })
  end

  before do
    allow(provider).to receive(:connection).and_return(fake_conn)
    allow(provider).to receive(:download_url).and_return("VIDEO_BYTES")
  end

  # Capture the submitted POST body; the task id is returned immediately.
  def stub_submit
    allow(fake_conn).to receive(:post).with("/api/v3/contents/generations/tasks") do |&blk|
      req = double("req")
      allow(req).to receive(:headers).and_return({})
      allow(req).to receive(:body=) { |body| @captured_body = body }
      blk.call(req)
      instance_double(Faraday::Response, success?: true, status: 200, body: submit_response)
    end
  end

  # Drive the single status GET.
  def stub_status(body)
    allow(fake_conn).to receive(:get).with("/api/v3/contents/generations/tasks/cgt-123")
      .and_return(instance_double(Faraday::Response, success?: true, status: 200, body: body))
  end

  describe "#generate_video" do
    context "text-to-video" do
      before { stub_submit }

      it "submits the Ark task envelope and returns the task id without blocking" do
        result = provider.generate_video(prompt: "a cat surfing", aspect_ratio: "portrait", duration_seconds: 8)

        sent = JSON.parse(@captured_body)
        expect(sent["model"]).to eq("doubao-seedance-2-0-260128")
        expect(sent["ratio"]).to eq("9:16")
        expect(sent["duration"]).to eq(8)
        expect(sent["content"]).to eq([{ "type" => "text", "text" => "a cat surfing" }])

        expect(result["success"]).to be true
        expect(result["status"]).to eq("submitted")
        expect(result["task_id"]).to eq("cgt-123")
        expect(result["provider"]).to eq("volcengine")
        expect(result).not_to have_key("video")
      end

      it "does not poll or download during submission" do
        expect(fake_conn).not_to receive(:get)
        provider.generate_video(prompt: "x")
      end
    end

    context "aspect ratio handling" do
      before { stub_submit }

      it "maps landscape/portrait/square to Ark ratios" do
        provider.generate_video(prompt: "x", aspect_ratio: "landscape")
        expect(JSON.parse(@captured_body)["ratio"]).to eq("16:9")
      end

      it "passes a raw Ark ratio through unchanged" do
        provider.generate_video(prompt: "x", aspect_ratio: "adaptive")
        expect(JSON.parse(@captured_body)["ratio"]).to eq("adaptive")

        provider.generate_video(prompt: "x", aspect_ratio: "21:9")
        expect(JSON.parse(@captured_body)["ratio"]).to eq("21:9")
      end

      it "forwards optional Seedance params" do
        provider.generate_video(prompt: "x", resolution: "1080p", generate_audio: true, watermark: false, seed: 42)
        sent = JSON.parse(@captured_body)
        expect(sent["resolution"]).to eq("1080p")
        expect(sent["generate_audio"]).to be true
        expect(sent["watermark"]).to be false
        expect(sent["seed"]).to eq(42)
      end

      it "pins resolution to 720p when omitted" do
        provider.generate_video(prompt: "x")
        expect(JSON.parse(@captured_body)["resolution"]).to eq("720p")
      end
    end

    context "multimodal content" do
      before { stub_submit }

      it "attaches first/last frame images with roles" do
        provider.generate_video(
          prompt: "morph",
          first_frame: "https://img.example.com/a.jpg",
          last_frame: "https://img.example.com/b.jpg"
        )
        content = JSON.parse(@captured_body)["content"]
        expect(content).to include(
          { "type" => "image_url", "image_url" => { "url" => "https://img.example.com/a.jpg" }, "role" => "first_frame" },
          { "type" => "image_url", "image_url" => { "url" => "https://img.example.com/b.jpg" }, "role" => "last_frame" }
        )
      end

      it "attaches reference images, videos and audios with roles" do
        provider.generate_video(
          prompt: "ad",
          reference_images: ["https://img.example.com/1.jpg", "https://img.example.com/2.jpg"],
          reference_videos: ["https://vid.example.com/v.mp4"],
          reference_audios: ["https://aud.example.com/a.mp3"]
        )
        content = JSON.parse(@captured_body)["content"]
        roles = content.map { |c| c["role"] }
        expect(roles.count("reference_image")).to eq(2)
        expect(content).to include(
          { "type" => "video_url", "video_url" => { "url" => "https://vid.example.com/v.mp4" }, "role" => "reference_video" },
          { "type" => "audio_url", "audio_url" => { "url" => "https://aud.example.com/a.mp3" }, "role" => "reference_audio" }
        )
      end

      it "encodes a local file path into a data URL" do
        Dir.mktmpdir do |tmp|
          path = File.join(tmp, "frame.png")
          File.binwrite(path, "PNGDATA")
          provider.generate_video(prompt: "x", first_frame: path)
          url = JSON.parse(@captured_body)["content"].find { |c| c["role"] == "first_frame" }["image_url"]["url"]
          expect(url).to eq("data:image/png;base64,#{Base64.strict_encode64("PNGDATA")}")
        end
      end

      it "accepts a b64_json hash for the legacy image field" do
        provider.generate_video(prompt: "x", image: { "b64_json" => "QUJD", "mime_type" => "image/jpeg" })
        url = JSON.parse(@captured_body)["content"].find { |c| c["role"] == "first_frame" }["image_url"]["url"]
        expect(url).to eq("data:image/jpeg;base64,QUJD")
      end

      it "rejects a media reference that is neither a URL, file, nor hash" do
        result = provider.generate_video(prompt: "x", reference_videos: ["/no/such/file.mp4"])
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_argument")
      end
    end

    context "validation" do
      it "requires a prompt or at least one media input" do
        result = provider.generate_video(prompt: "  ")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_argument")
      end

      it "rejects mixing first_frame/last_frame with reference_* without submitting" do
        expect(fake_conn).not_to receive(:post)
        result = provider.generate_video(
          prompt: "edit this",
          first_frame: "https://img.example.com/a.jpg",
          reference_videos: ["https://vid.example.com/v.mp4"]
        )
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("invalid_argument")
        expect(result["error"]).to match(/cannot be combined/)
      end

      it "allows an empty prompt when a reference image is provided" do
        stub_submit
        result = provider.generate_video(prompt: "", first_frame: "https://img.example.com/a.jpg")
        expect(result["success"]).to be true
        expect(result["status"]).to eq("submitted")
      end

      it "fails when api_key is missing" do
        no_key = described_class.new(entry.merge("api_key" => ""))
        result = no_key.generate_video(prompt: "x")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("auth_required")
      end

      it "fails when upstream returns no task id" do
        allow(fake_conn).to receive(:post).and_return(
          instance_double(Faraday::Response, success?: true, status: 200, body: JSON.generate({}))
        )
        result = provider.generate_video(prompt: "x")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("empty_response")
      end
    end

    context "submission errors" do
      it "surfaces a nested Ark error object" do
        allow(fake_conn).to receive(:post).and_return(
          instance_double(Faraday::Response, success?: false, status: 400,
                          body: JSON.generate({ "error" => { "code" => "InvalidParameter", "message" => "bad model" } }))
        )
        result = provider.generate_video(prompt: "x")
        expect(result["success"]).to be false
        expect(result["error_type"]).to eq("api_error")
        expect(result["error"]).to include("bad model")
      end
    end
  end

  describe "#video_status" do
    it "requires a task id" do
      result = provider.video_status(task_id: "  ")
      expect(result["success"]).to be false
      expect(result["error_type"]).to eq("invalid_argument")
    end

    it "reports a still-running task without downloading" do
      stub_status(status_running)
      expect(provider).not_to receive(:download_url)
      result = provider.video_status(task_id: "cgt-123")
      expect(result["success"]).to be true
      expect(result["status"]).to eq("running")
      expect(result["task_id"]).to eq("cgt-123")
    end

    it "downloads and returns a local path on success" do
      stub_status(status_succeeded)
      Dir.mktmpdir do |tmp|
        result = provider.video_status(task_id: "cgt-123", output_dir: tmp)
        expect(result["success"]).to be true
        expect(result["status"]).to eq("succeeded")
        expect(result["video"]).to start_with(File.join(tmp, "assets", "generated"))
        expect(File.binread(result["video"])).to eq("VIDEO_BYTES")
        expect(result["task_id"]).to eq("cgt-123")
      end
    end

    it "treats a queued task as still running" do
      stub_status(JSON.generate({ "id" => "cgt-123", "status" => "queued" }))
      result = provider.video_status(task_id: "cgt-123")
      expect(result["success"]).to be true
      expect(result["status"]).to eq("running")
    end

    it "surfaces a failed task" do
      stub_status(JSON.generate({ "status" => "failed", "error" => { "message" => "content blocked" } }))
      result = provider.video_status(task_id: "cgt-123")
      expect(result["success"]).to be false
      expect(result["status"]).to eq("failed")
      expect(result["error"]).to include("content blocked")
    end

    it "surfaces an expired task as failed" do
      stub_status(JSON.generate({ "status" => "expired" }))
      result = provider.video_status(task_id: "cgt-123")
      expect(result["success"]).to be false
      expect(result["error"]).to include("expired")
    end
  end
end
