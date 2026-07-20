# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "chunk index injection and topics" do
  let(:sessions_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(sessions_dir) }

  # ── Helper: write a minimal chunk MD with optional topics ──────────────────

  def write_chunk(path, topics: nil, message_count: 8)
    lines = ["---", "session_id: aabbccdd", "chunk: 1", "compression_level: 1",
             "archived_at: 2026-04-16T01:00:00+08:00", "message_count: #{message_count}"]
    lines << "topics: #{topics}" if topics
    lines << "---"
    lines << ""
    lines << "## User\n\nHello\n\n## Assistant\n\nHi\n"
    File.write(path, lines.join("\n"))
  end

  # ── Shared agent builder (includes all relevant modules) ───────────────────

  def build_agent(messages)
    history = Clacky::MessageHistory.new(messages)

    agent_class = Class.new do
      include Clacky::Agent::SessionSerializer

      attr_reader :history

      def initialize(history, working_dir)
        @history     = history
        @working_dir = working_dir
        @skill_loader = Object.new.tap { |sl| sl.define_singleton_method(:load_all) {} }
      end

      def build_system_prompt; "system prompt"; end
      def current_model;       "test-model";    end
    end

    agent_class.new(history, sessions_dir)
  end

  # ── Section 1: Bug A fix — compressed_summary excluded from chunk archive ──

  describe "save_compressed_chunk excludes compressed_summary messages" do
    let(:agent_class) do
      Class.new do
        include Clacky::Agent::MessageCompressorHelper

        attr_accessor :session_id, :created_at, :compressed_summaries, :compression_level

        def initialize(sessions_dir)
          @sessions_dir_override = sessions_dir
          @session_id            = "abc12345-0000-0000-0000-000000000000"
          @created_at            = "2026-04-16T01:00:00+08:00"
          @compressed_summaries  = []
          @compression_level     = 0
        end

        def ui; nil; end
        def config; double("config", enable_compression: true); end
      end
    end

    before { stub_const("Clacky::SessionManager::SESSIONS_DIR", sessions_dir) }

    subject(:agent) { agent_class.new(sessions_dir) }

    it "does NOT write previous compressed_summary messages into the new chunk file" do
      prev_summary = {
        role: "assistant",
        content: "Old summary text pointing to chunk-1",
        compressed_summary: true,
        chunk_path: "/path/to/chunk-1.md"
      }
      real_user = { role: "user",      content: "A real user question" }
      real_asst = { role: "assistant", content: "A real assistant answer" }

      original_messages = [prev_summary, real_user, real_asst]

      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 2, compression_level: 1)

      content = File.read(path)
      # The compressed_summary from chunk-1 must NOT appear in chunk-2
      expect(content).not_to include("Old summary text pointing to chunk-1")
      expect(content).not_to include("chunk-1.md")
      # Real messages must still be present
      expect(content).to include("A real user question")
      expect(content).to include("A real assistant answer")
    end

    it "writes topics into front matter when provided" do
      original_messages = [
        { role: "user",      content: "Rails setup question" },
        { role: "assistant", content: "Here is how to set up Rails" }
      ]

      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1,
                        topics: "Rails setup, database config")

      content = File.read(path)
      expect(content).to include("topics: Rails setup, database config")
    end

    it "omits topics line in front matter when topics is nil" do
      original_messages = [
        { role: "user",      content: "Hello" },
        { role: "assistant", content: "Hi" }
      ]

      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1,
                        topics: nil)

      front_matter_lines = File.read(path).lines.take_while { |l| !l.strip.match?(/\A---\z/) || $. == 1 }
      expect(front_matter_lines.join).not_to include("topics:")
    end
  end

  # ── Section 2: parse_topics and <topics> stripping ─────────────────────────

  describe Clacky::MessageCompressor do
    subject(:compressor) { described_class.new(nil) }

    describe "#parse_topics" do
      it "extracts topics string from <topics> tag" do
        content = "<topics>Rails setup, database config, deploy</topics>\n<summary>Full summary here.</summary>"
        expect(compressor.parse_topics(content)).to eq("Rails setup, database config, deploy")
      end

      it "returns nil when no <topics> tag present" do
        content = "<summary>Just a summary, no topics tag.</summary>"
        expect(compressor.parse_topics(content)).to be_nil
      end

      it "strips surrounding whitespace from the topics value" do
        content = "<topics>  auth setup, user model  </topics>"
        expect(compressor.parse_topics(content)).to eq("auth setup, user model")
      end

      it "handles multiline topics (edge case)" do
        content = "<topics>\nRails setup\ndeploy\n</topics>"
        expect(compressor.parse_topics(content)).to eq("Rails setup\ndeploy")
      end
    end

    describe "#parse_compressed_result" do
      it "strips <topics> block from the assistant message content" do
        raw = "<topics>Rails setup, database config</topics>\n<summary>The conversation covered Rails setup.</summary>"
        result = compressor.send(:parse_compressed_result, raw, chunk_path: nil)

        expect(result).not_to be_empty
        expect(result.first[:content]).not_to include("<topics>")
        expect(result.first[:content]).not_to include("Rails setup, database config")
        expect(result.first[:content]).to include("The conversation covered Rails setup.")
      end

      it "still injects chunk anchor after stripping <topics>" do
        raw = "<topics>auth, deploy</topics>\n<summary>Summary text.</summary>"
        chunk_path = "/tmp/test-chunk-1.md"
        result = compressor.send(:parse_compressed_result, raw, chunk_path: chunk_path)

        expect(result.first[:content]).to include(chunk_path)
        expect(result.first[:content]).to include("file_reader")
        expect(result.first[:content]).not_to include("<topics>")
      end

      it "handles content with no <topics> tag gracefully" do
        raw = "<summary>Summary without topics tag.</summary>"
        result = compressor.send(:parse_compressed_result, raw, chunk_path: nil)

        expect(result.first[:content]).to include("Summary without topics tag.")
      end

      it "sets compressed_summary: true on the returned message" do
        raw = "<topics>foo, bar</topics>\n<summary>text</summary>"
        result = compressor.send(:parse_compressed_result, raw, chunk_path: nil)
        expect(result.first[:compressed_summary]).to be true
      end
    end
  end

  # ── Section 3: MessageHistory#last_injected_chunk_count ────────────────────

  describe Clacky::MessageHistory do
    describe "#last_injected_chunk_count" do
      it "returns 0 when no chunk_index message exists" do
        history = described_class.new([
          { role: "system",    content: "sys" },
          { role: "user",      content: "hello" }
        ])
        expect(history.last_injected_chunk_count).to eq(0)
      end

      it "returns the chunk_count from the most recent chunk_index message" do
        history = described_class.new([
          { role: "user", content: "chunk index", system_injected: true, chunk_index: true, chunk_count: 2 }
        ])
        expect(history.last_injected_chunk_count).to eq(2)
      end

      it "returns the latest value when multiple chunk_index messages exist" do
        history = described_class.new([
          { role: "user", content: "old index", system_injected: true, chunk_index: true, chunk_count: 1 },
          { role: "user", content: "new index", system_injected: true, chunk_index: true, chunk_count: 2 }
        ])
        expect(history.last_injected_chunk_count).to eq(2)
      end
    end

    describe "chunk_index field in INTERNAL_FIELDS" do
      it "strips chunk_index and chunk_count from to_api output" do
        history = described_class.new([
          { role: "user", content: "index card", system_injected: true,
            chunk_index: true, chunk_count: 3 }
        ])
        api_msg = history.to_api.find { |m| m[:content] == "index card" }
        expect(api_msg).not_to be_nil
        expect(api_msg.keys).not_to include(:chunk_index)
        expect(api_msg.keys).not_to include(:chunk_count)
      end
    end
  end

  # ── Section 4: inject_chunk_index_if_needed behaviour ─────────────────────

  describe "inject_chunk_index_if_needed" do
    it "does nothing when history has no compressed_summary messages" do
      agent = build_agent([
        { role: "system", content: "sys" },
        { role: "user",   content: "hello", created_at: Time.now.to_f }
      ])

      agent.send(:inject_chunk_index_if_needed)

      injected = agent.history.to_a.select { |m| m[:chunk_index] }
      expect(injected).to be_empty
    end

    it "injects an index card when compressed_summary messages exist" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      write_chunk(chunk_path, topics: "Rails setup, database config", message_count: 16)

      agent = build_agent([
        { role: "system",    content: "sys" },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path }
      ])

      agent.send(:inject_chunk_index_if_needed)

      injected = agent.history.to_a.select { |m| m[:chunk_index] }
      expect(injected.size).to eq(1)
      expect(injected.first[:content]).to include("CHUNK-1")
      expect(injected.first[:content]).to include(chunk_path)
    end

    it "includes topics from chunk front matter in the index card" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      write_chunk(chunk_path, topics: "Rails setup, database config")

      agent = build_agent([
        { role: "assistant", compressed_summary: true, chunk_path: chunk_path, content: "s" }
      ])

      agent.send(:inject_chunk_index_if_needed)

      card = agent.history.to_a.find { |m| m[:chunk_index] }
      expect(card[:content]).to include("Rails setup, database config")
    end

    it "includes message_count (turns) from chunk front matter" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      write_chunk(chunk_path, message_count: 24)

      agent = build_agent([
        { role: "assistant", compressed_summary: true, chunk_path: chunk_path, content: "s" }
      ])

      agent.send(:inject_chunk_index_if_needed)

      card = agent.history.to_a.find { |m| m[:chunk_index] }
      expect(card[:content]).to include("24")
    end

    it "does NOT re-inject when chunk count has not changed" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      write_chunk(chunk_path, topics: "auth")

      agent = build_agent([
        { role: "assistant", compressed_summary: true, chunk_path: chunk_path, content: "s" }
      ])

      agent.send(:inject_chunk_index_if_needed)
      agent.send(:inject_chunk_index_if_needed)  # second call

      injected = agent.history.to_a.select { |m| m[:chunk_index] }
      expect(injected.size).to eq(1)  # only one, not two
    end

    it "replaces the old index card when a new chunk is added" do
      chunk1 = File.join(sessions_dir, "chunk-1.md")
      chunk2 = File.join(sessions_dir, "chunk-2.md")
      write_chunk(chunk1, topics: "first topics")
      write_chunk(chunk2, topics: "second topics")

      # Start with only chunk-1
      agent = build_agent([
        { role: "assistant", compressed_summary: true, chunk_path: chunk1, content: "s1" }
      ])
      agent.send(:inject_chunk_index_if_needed)

      # Simulate new compression: add chunk-2 to history
      agent.history.append(
        { role: "assistant", compressed_summary: true, chunk_path: chunk2, content: "s2" }
      )
      agent.send(:inject_chunk_index_if_needed)

      injected = agent.history.to_a.select { |m| m[:chunk_index] }
      expect(injected.size).to eq(1)             # still only one index card
      expect(injected.first[:chunk_count]).to eq(2)
      expect(injected.first[:content]).to include("CHUNK-1")
      expect(injected.first[:content]).to include("CHUNK-2")
    end

    it "marks the injected message as system_injected" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      write_chunk(chunk_path)

      agent = build_agent([
        { role: "assistant", compressed_summary: true, chunk_path: chunk_path, content: "s" }
      ])

      agent.send(:inject_chunk_index_if_needed)

      card = agent.history.to_a.find { |m| m[:chunk_index] }
      expect(card[:system_injected]).to be true
    end

    it "handles missing chunk file gracefully (no crash, omits topics/turns)" do
      agent = build_agent([
        { role: "assistant", compressed_summary: true,
          chunk_path: "/nonexistent/chunk-1.md", content: "s" }
      ])

      expect { agent.send(:inject_chunk_index_if_needed) }.not_to raise_error

      card = agent.history.to_a.find { |m| m[:chunk_index] }
      expect(card).not_to be_nil
      expect(card[:content]).to include("CHUNK-1")
    end
  end

  # ── Section 5: chunk_index card excluded from replay_history ──────────────

  describe "chunk_index message is invisible in replay_history" do
    it "does not show up as a user turn in replay output" do
      chunk_path = File.join(sessions_dir, "chunk-1.md")
      write_chunk(chunk_path, topics: "Rails setup")

      messages = [
        { role: "system",    content: "sys" },
        { role: "assistant", content: "Summary.", compressed_summary: true, chunk_path: chunk_path },
        # injected index card
        { role: "user", content: "## Previous Session Archives...", system_injected: true,
          chunk_index: true, chunk_count: 1 },
        { role: "user", content: "Real user question", created_at: Time.now.to_f }
      ]

      agent = build_agent(messages)

      collector = Class.new do
        attr_reader :events
        def initialize; @events = []; end
        def show_user_message(content, created_at: nil, files: [], editable: true); @events << { type: :user, content: content }; end
        def show_assistant_message(content, files:); @events << { type: :assistant, content: content }; end
        def show_tool_call(*); end
        def show_tool_result(*); end
        def show_token_usage(*); end
        def method_missing(*); end
        def respond_to_missing?(*); true; end
      end.new

      agent.replay_history(collector)

      user_contents = collector.events.select { |e| e[:type] == :user }.map { |e| e[:content] }
      expect(user_contents).to include(a_string_including("Real user question"))
      # The index card content must NOT appear as a user turn
      expect(user_contents).not_to include(a_string_including("## Previous Session Archives"))
    end
  end
end
