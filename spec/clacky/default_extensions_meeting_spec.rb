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
end
