# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "time"
require "json"

RSpec.describe "Chunk MD attachment badge (display_files) round-trip" do
  let(:sessions_dir) { Dir.mktmpdir }
  let(:session_id) { "abc12345-0000-0000-0000-000000000000" }

  before { stub_const("Clacky::SessionManager::SESSIONS_DIR", sessions_dir) }
  after { FileUtils.rm_rf(sessions_dir) }

  # Agent stub that can both build and parse chunk MD.
  let(:agent) do
    klass = Class.new do
      include Clacky::Agent::MessageCompressorHelper
      include Clacky::Agent::SessionSerializer

      attr_accessor :session_id

      def initialize
        @skill_loader = Object.new.tap { |sl| sl.define_singleton_method(:load_all) {} }
      end
    end
    obj = klass.new
    obj.session_id = session_id
    obj
  end

  def write_and_parse(messages)
    md = agent.send(:build_chunk_md, messages, chunk_index: 1, compression_level: 1)
    path = File.join(sessions_dir, "2026-01-01-00-00-00-abc12345-chunk-1.md")
    File.write(path, md)
    agent.send(:parse_chunk_md_to_rounds, path)
  end

  it "preserves display_files across build → parse" do
    files = [{ name: "report.xlsx", type: "file", path: "/tmp/report.xlsx", preview_path: "/tmp/report.preview" }]
    rounds = write_and_parse([{ role: "user", content: "check this", display_files: files }])

    df = rounds.first[:user_msg][:display_files]
    expect(df).to be_an(Array)
    expect(df.first["name"]).to eq("report.xlsx")
    expect(df.first["type"]).to eq("file")
    expect(df.first["path"]).to eq("/tmp/report.xlsx")
    expect(df.first["preview_path"]).to eq("/tmp/report.preview")
  end

  it "strips the display_files comment from the visible user text" do
    files = [{ name: "a.xlsx", type: "file", path: "/tmp/a.xlsx" }]
    rounds = write_and_parse([{ role: "user", content: "look here", display_files: files }])

    expect(rounds.first[:user_msg][:content]).to eq("look here")
    expect(rounds.first[:user_msg][:content]).not_to include("clacky:display_files")
  end

  it "handles user messages without attachments (backward compatible)" do
    rounds = write_and_parse([{ role: "user", content: "no files here" }])

    expect(rounds.first[:user_msg]).not_to have_key(:display_files)
    expect(rounds.first[:user_msg][:content]).to eq("no files here")
  end

  it "does not write a comment line when display_files is empty" do
    md = agent.send(:build_chunk_md, [{ role: "user", content: "hi", display_files: [] }],
                    chunk_index: 1, compression_level: 1)
    expect(md).not_to include("clacky:display_files")
  end

  it "preserves non-ASCII (CJK) file names via JSON escaping" do
    files = [{ name: "季度报表.xlsx", type: "file", path: "/tmp/季度报表.xlsx" }]
    rounds = write_and_parse([{ role: "user", content: "报表", display_files: files }])

    expect(rounds.first[:user_msg][:display_files].first["name"]).to eq("季度报表.xlsx")
  end

  it "tolerates a corrupt display_files comment without breaking replay" do
    md = <<~MD
      ---
      session_id: #{session_id}
      chunk: 1
      archived_at: 2026-01-01T00:00:00+08:00
      ---
      # Session Chunk 1

      ## User

      broken attachment
      <!-- clacky:display_files {not valid json -->

      ## Assistant

      ok
    MD
    path = File.join(sessions_dir, "2026-01-01-00-00-00-abc12345-chunk-1.md")
    File.write(path, md)

    rounds = agent.send(:parse_chunk_md_to_rounds, path)
    expect(rounds.first[:user_msg]).not_to have_key(:display_files)
    expect(rounds.first[:user_msg][:content]).to include("broken attachment")
  end
end
