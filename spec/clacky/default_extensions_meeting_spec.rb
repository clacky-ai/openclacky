# frozen_string_literal: true

require "spec_helper"

MEETING_EXT_DIR = File.expand_path("../../lib/clacky/default_extensions/meeting", __dir__)
require File.join(MEETING_EXT_DIR, "api/handler.rb")

RSpec.describe "Meeting extension API" do
  let(:root) { Dir.mktmpdir }
  let(:sid) { "sess-c5902" }
  let(:mid) { "mtg-20261124-175516-f55146dc" }
  let(:dir) { File.join(root, sid, mid) }
  let(:transcript_path) { File.join(dir, "transcript.jsonl") }
  let(:spoken) { "今天先过一下季度目标" }

  before do
    stub_const("MeetingExt::MEETINGS_ROOT", root)
    stub_const("MeetingExt::VOCABULARY_PATH", File.join(root, "vocabulary.txt"))
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "meta.json"), JSON.generate(session_id: sid, meeting_id: mid))
    File.write(transcript_path, "")
  end

  after { FileUtils.remove_entry(root) if Dir.exist?(root) }

  def call(method, pattern, body: nil)
    route = MeetingExt.routes.find { |r| r.method == method && r.pattern == pattern }
    req = double("request", body: body && JSON.generate(body), query: {})
    MeetingExt.new(req: req, res: nil, route: route, params: {}, http_server: nil).invoke
    raise "handler did not respond"
  rescue Clacky::ApiExtension::Halt => halt
    [halt.status, JSON.parse(halt.payload)]
  end

  def transcribe
    call(:post, "/transcribe",
         body: { session_id: sid, meeting_id: mid, audio_base64: "AAAA", mime_type: "audio/webm" })
  end

  def transcript_lines
    File.readlines(transcript_path).map { |line| JSON.parse(line) }
  end

  describe "POST /transcribe" do
    before { allow_any_instance_of(MeetingExt).to receive(:call_stt).and_return("success" => true, "text" => spoken) }

    it "appends the recognized text to the transcript" do
      status, data = transcribe
      expect(status).to eq(200)
      expect(data["text"]).to eq(spoken)
      expect(transcript_lines.map { |line| line["text"] }).to eq([spoken])
    end

    it "answers 404 instead of 500 when the meeting is cancelled while STT is running" do
      allow_any_instance_of(MeetingExt).to receive(:call_stt) do
        FileUtils.remove_entry(dir)
        { "success" => true, "text" => spoken }
      end

      status, data = transcribe
      expect(status).to eq(404)
      expect(data["error"]).to eq("meeting not found")
    end

    it "rejects a meeting that is already gone" do
      FileUtils.remove_entry(dir)
      status, data = transcribe
      expect(status).to eq(404)
      expect(data["error"]).to eq("meeting not found")
    end
  end

  describe "POST /transcribe billing" do
    let(:billing_dir) { Dir.mktmpdir }

    around do |example|
      original = ENV["CLACKY_BILLING_DIR"]
      ENV["CLACKY_BILLING_DIR"] = billing_dir
      example.run
    ensure
      ENV["CLACKY_BILLING_DIR"] = original
      FileUtils.remove_entry(billing_dir) if Dir.exist?(billing_dir)
    end

    def billing_rows
      Dir.glob(File.join(billing_dir, "*.jsonl")).flat_map do |file|
        File.readlines(file).map { |line| JSON.parse(line) }
      end
    end

    it "books the upstream cost of the chunk" do
      allow_any_instance_of(MeetingExt).to receive(:call_stt).and_return(
        "success" => true,
        "text" => spoken,
        "model" => "dsk-deepseek-asr",
        "provider" => "openclacky",
        "usage" => { "audio_seconds" => 12.5, "duration_ms" => 12_500 },
        "cost_usd" => 0.000395
      )

      transcribe

      expect(billing_rows.size).to eq(1)
      row = billing_rows.first
      expect(row["model"]).to eq("dsk-deepseek-asr")
      expect(row["provider"]).to eq("openclacky")
      expect(row["session_id"]).to eq(sid)
      expect(row["cost_usd"]).to be_within(1e-9).of(0.000395)
      expect(row["cost_source"]).to eq("api")
    end

    it "still books the cost when the text is dropped as a hallucination" do
      allow_any_instance_of(MeetingExt).to receive(:call_stt).and_return(
        "success" => true,
        "text" => "谢谢观看",
        "model" => "dsk-deepseek-asr",
        "provider" => "openclacky",
        "usage" => { "audio_seconds" => 2.0 },
        "cost_usd" => 0.0000632
      )

      status, data = transcribe

      expect(status).to eq(200)
      expect(data["text"]).to eq("")
      expect(transcript_lines).to be_empty
      expect(billing_rows.size).to eq(1)
    end

    it "writes no row when the provider reports no usage or cost" do
      allow_any_instance_of(MeetingExt).to receive(:call_stt).and_return(
        "success" => true, "text" => spoken
      )

      transcribe

      expect(billing_rows).to be_empty
    end
  end

  describe "POST /transcribe without a speech-to-text model" do
    it "reports a settings gap the panel can link to" do
      allow_any_instance_of(MeetingExt).to receive(:call_stt).and_return(
        "success" => false,
        "text" => nil,
        "error" => "No STT model configured. Add a model with type=stt in settings.",
        "error_type" => "not_configured"
      )

      status, data = transcribe
      expect(status).to eq(422)
      expect(data["error_type"]).to eq("stt_not_configured")
      expect(data["error"]).not_to include("type=stt")
      expect(transcript_lines).to be_empty
    end

    it "keeps real STT failures as upstream errors" do
      allow_any_instance_of(MeetingExt).to receive(:call_stt).and_return(
        "success" => false, "text" => nil, "error" => "upstream 503", "error_type" => "http_error"
      )

      status, data = transcribe
      expect(status).to eq(502)
      expect(data).not_to have_key("error_type")
      expect(data["error"]).to eq("upstream 503")
    end
  end
end
