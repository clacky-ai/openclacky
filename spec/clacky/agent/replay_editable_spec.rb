# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# replay_history must flag each user message with whether it can be edited:
#   - Messages still living in the active in-memory @history  → editable: true
#   - Messages already archived into a compressed chunk MD     → editable: false
#
# The distinction matters because the backend edit path keys off
# MessageHistory#truncate_from_created_at, which can only truncate messages
# present in @history. Archived messages would silently no-op, so their edit
# affordance must be hidden in the UI.
RSpec.describe "replay_history editable flag" do
  let(:sessions_dir) { Dir.mktmpdir }
  let(:session_id)   { "abcd1234-0000-0000-0000-000000000000" }
  let(:created_at)   { "2026-03-08T10:00:00+08:00" }

  # Collects every show_user_message call as { text:, editable: }
  let(:ui) do
    Class.new do
      attr_reader :user_messages

      def initialize
        @user_messages = []
      end

      def show_user_message(content, created_at: nil, files: [], editable: true)
        @user_messages << { text: content, editable: editable }
      end

      # Swallow all other UI callbacks used by _replay_single_message
      def method_missing(_name, *_args, **_kwargs); end

      def respond_to_missing?(_name, _include_private = false)
        true
      end
    end.new
  end

  let(:host_class) do
    Class.new do
      include Clacky::Agent::SessionSerializer

      attr_accessor :history

      def initialize(history)
        @history = history
      end
    end
  end

  before { stub_const("Clacky::SessionManager::SESSIONS_DIR", sessions_dir) }
  after  { FileUtils.rm_rf(sessions_dir) }

  def write_chunk(index, body)
    datetime = "2026-03-08-10-00-00"
    short_id = session_id[0..7]
    path = File.join(sessions_dir, "#{datetime}-#{short_id}-chunk-#{index}.md")
    md = +"---\nsession_id: #{session_id}\nchunk: #{index}\narchived_at: #{created_at}\n---\n\n"
    md << body
    File.write(path, md)
    path
  end

  it "flags active in-memory user messages as editable" do
    history = Clacky::MessageHistory.new([
      { role: "system", content: "sys" },
      { role: "user", content: "active question", created_at: created_at },
      { role: "assistant", content: "active answer" }
    ])
    host = host_class.new(history)

    host.replay_history(ui)

    msg = ui.user_messages.find { |m| m[:text] == "active question" }
    expect(msg).not_to be_nil
    expect(msg[:editable]).to be true
  end

  it "flags user messages expanded from a compressed chunk as NOT editable" do
    chunk_path = write_chunk(1, "## User\n\narchived question\n\n## Assistant\n\narchived answer\n")

    history = Clacky::MessageHistory.new([
      { role: "system", content: "sys" },
      { role: "user", content: "summary anchor", compressed_summary: true,
        system_injected: true, chunk_path: chunk_path },
      { role: "user", content: "active question", created_at: created_at },
      { role: "assistant", content: "active answer" }
    ])
    host = host_class.new(history)

    host.replay_history(ui)

    archived = ui.user_messages.find { |m| m[:text].include?("archived question") }
    active   = ui.user_messages.find { |m| m[:text] == "active question" }

    expect(archived).not_to be_nil
    expect(archived[:editable]).to be false

    expect(active).not_to be_nil
    expect(active[:editable]).to be true
  end
end
