# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "time"

RSpec.describe "Compression chunk MD archiving" do
  let(:sessions_dir) { Dir.mktmpdir }
  let(:session_id) { "abc12345-0000-0000-0000-000000000000" }
  let(:created_at) { "2026-03-08T10:00:00+08:00" }

  # Minimal agent class that includes MessageCompressorHelper
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::MessageCompressorHelper

      attr_accessor :messages, :session_id, :created_at, :compressed_summaries, :compression_level

      def initialize(sessions_dir)
        @sessions_dir_override = sessions_dir
        @messages = []
        @session_id = nil
        @created_at = nil
        @compressed_summaries = []
        @compression_level = 0
      end

      def ui
        nil
      end

      def config
        double("config", enable_compression: true)
      end
    end
  end

  before do
    stub_const("Clacky::SessionManager::SESSIONS_DIR", sessions_dir)
  end

  after do
    FileUtils.rm_rf(sessions_dir)
  end

  subject(:agent) do
    obj = agent_class.new(sessions_dir)
    obj.session_id = session_id
    obj.created_at = created_at
    obj
  end

  let(:user_msg)      { { role: "user", content: "Tell me about compression" } }
  let(:assistant_msg) { { role: "assistant", content: "Compression reduces token usage." } }
  let(:system_msg)    { { role: "system", content: "You are a helpful assistant." } }
  let(:recent_msg)    { { role: "user", content: "And what about memory?" } }

  describe "#save_compressed_chunk" do
    it "creates a chunk MD file in the sessions directory" do
      original_messages = [system_msg, user_msg, assistant_msg, recent_msg]
      recent_messages = [recent_msg]

      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)

      expect(path).not_to be_nil
      expect(File.exist?(path)).to be true
    end

    it "names the file with the correct pattern: datetime-shortid-chunk-n.md" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      filename = File.basename(path)
      expect(filename).to match(/\A2026-03-08-10-00-00-abc12345-chunk-1\.md\z/)
    end

    it "increments chunk index for sequential compressions" do
      original_messages = [system_msg, user_msg, assistant_msg]

      path1 = agent.send(:save_compressed_chunk, original_messages, [], chunk_index: 1, compression_level: 1)
      path2 = agent.send(:save_compressed_chunk, original_messages, [], chunk_index: 2, compression_level: 2)

      expect(File.basename(path1)).to include("chunk-1")
      expect(File.basename(path2)).to include("chunk-2")
    end

    it "excludes system messages from the chunk content" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).not_to include("You are a helpful assistant")
    end

    it "excludes recent messages from the chunk content" do
      original_messages = [system_msg, user_msg, assistant_msg, recent_msg]
      recent_messages = [recent_msg]

      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).not_to include("And what about memory?")
      expect(content).to include("Tell me about compression")
    end

    it "includes user and assistant messages in readable MD format" do
      original_messages = [system_msg, user_msg.merge(task_id: 6), assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).to include("## User [Task 6]")
      expect(content).to include("## Assistant")
      expect(content).to include("Tell me about compression")
      expect(content).to include("Compression reduces token usage.")
    end

    it "includes front matter with session metadata" do
      original_messages = [system_msg, user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)

      content = File.read(path)
      expect(content).to include("session_id: #{session_id}")
      expect(content).to include("chunk: 1")
      expect(content).to include("compression_level: 1")
    end

    it "returns nil if session_id is not set" do
      agent.session_id = nil
      original_messages = [user_msg, assistant_msg]
      path = agent.send(:save_compressed_chunk, original_messages, [],
                        chunk_index: 1, compression_level: 1)
      expect(path).to be_nil
    end

    it "returns nil if there are no messages to archive (only system + recent)" do
      original_messages = [system_msg, recent_msg]
      recent_messages = [recent_msg]
      path = agent.send(:save_compressed_chunk, original_messages, recent_messages,
                        chunk_index: 1, compression_level: 1)
      expect(path).to be_nil
    end
  end

  describe "SessionManager cleanup" do
    let(:manager) { Clacky::SessionManager.new(sessions_dir: sessions_dir) }

    # Build a minimal valid session data hash
    def session_data(session_id:, created_at:, updated_at:)
      {
        session_id: session_id,
        created_at: created_at,
        updated_at: updated_at,
        working_dir: "/tmp",
        messages: [],
        todos: [],
        time_machine: { task_parents: {}, current_task_id: 0, active_task_id: 0 },
        config: { models: {}, permission_mode: "auto_approve", enable_compression: true,
                  enable_prompt_caching: false, max_tokens: 8192, verbose: false },
        stats: { total_iterations: 0, total_cost_usd: 0.0, total_tasks: 0,
                 last_status: "ok", previous_total_tokens: 0,
                 cache_stats: {}, debug_logs: [] }
      }
    end

    # Write a chunk MD file using the same naming convention as the real code
    def write_chunk(manager, session_id, created_at, chunk_index)
      datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
      short_id = session_id[0..7]
      base = "#{datetime}-#{short_id}"
      chunk_path = File.join(sessions_dir, "#{base}-chunk-#{chunk_index}.md")
      File.write(chunk_path, "# Chunk #{chunk_index}\n\nSome archived content.")
      chunk_path
    end

    it "deletes associated chunk MD files when cleanup_by_count removes a session" do
      old_id = "old-sess-0000-0000-0000-000000000001"
      new_id = "new-sess-0000-0000-0000-000000000002"
      old_created = "2026-01-01T00:00:00+08:00"
      new_created = "2026-03-08T10:00:00+08:00"

      # Save sessions via manager so filenames are consistent
      manager.save(session_data(session_id: old_id, created_at: old_created, updated_at: old_created))
      chunk_path = write_chunk(manager, old_id, old_created, 1)
      manager.save(session_data(session_id: new_id, created_at: new_created, updated_at: new_created))

      # Keep only 1 session — old one should be deleted with its chunk
      # (save already called cleanup_by_count(keep:10), so call explicitly with keep:1)
      manager.cleanup_by_count(keep: 1)

      expect(File.exist?(chunk_path)).to be false
    end

    it "deletes multiple chunk files for a deleted session" do
      old_id = "old-sess-0000-0000-0000-000000000001"
      new_id = "new-sess-0000-0000-0000-000000000002"
      old_created = "2026-01-01T00:00:00+08:00"
      new_created = "2026-03-08T10:00:00+08:00"

      manager.save(session_data(session_id: old_id, created_at: old_created, updated_at: old_created))
      chunk1 = write_chunk(manager, old_id, old_created, 1)
      chunk2 = write_chunk(manager, old_id, old_created, 2)
      manager.save(session_data(session_id: new_id, created_at: new_created, updated_at: new_created))

      manager.cleanup_by_count(keep: 1)

      expect(File.exist?(chunk1)).to be false
      expect(File.exist?(chunk2)).to be false
    end
  end

  describe Clacky::MessageCompressor do
    describe "#rebuild_with_compression" do
      let(:compressor) { described_class.new(nil) }
      let(:system_msg) { { role: "system", content: "System prompt" } }
      let(:recent_msg) { { role: "user", content: "Recent message" } }

      it "injects chunk anchor into compressed summary when chunk_path is provided" do
        chunk_path = "/home/user/.clacky/sessions/2026-03-08-10-00-00-abc12345-chunk-1.md"
        original_messages = [system_msg]

        result = compressor.rebuild_with_compression(
          "<summary>Conversation summary here</summary>",
          original_messages: original_messages,
          recent_messages: [recent_msg],
          chunk_path: chunk_path
        )

        summary_msg = result.find { |m| m[:compressed_summary] }
        expect(summary_msg[:role]).to eq("user")
        expect(summary_msg[:content]).to include(chunk_path)
        expect(summary_msg[:content]).to include("file_reader")
        expect(summary_msg[:chunk_path]).to eq(chunk_path)
      end

      it "does not inject anchor when chunk_path is nil" do
        original_messages = [system_msg]

        result = compressor.rebuild_with_compression(
          "<summary>Conversation summary here</summary>",
          original_messages: original_messages,
          recent_messages: [recent_msg],
          chunk_path: nil
        )

        summary_msg = result.find { |m| m[:compressed_summary] }
        expect(summary_msg[:role]).to eq("user")
        expect(summary_msg[:content]).not_to include("file_reader")
        expect(summary_msg[:chunk_path]).to be_nil
      end

      it "sets compressed_summary: true on the rebuilt summary message (role: user)" do
        result = compressor.rebuild_with_compression(
          "<summary>Summary</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: nil
        )
        summary_msg = result.find { |m| m[:compressed_summary] }
        expect(summary_msg[:role]).to eq("user")
        expect(summary_msg[:compressed_summary]).to be true
        # system_injected keeps it hidden from UI replay
        expect(summary_msg[:system_injected]).to be true
      end
    end

    describe "#parse_compressed_result" do
      let(:compressor) { described_class.new(nil) }

      it "stores topics in the returned message hash" do
        result = compressor.parse_compressed_result(
          "<topics>Rails setup, database config</topics>\n<summary>Did some work</summary>",
          chunk_path: "/tmp/chunk-1.md",
          topics: "Rails setup, database config"
        )

        msg = result.first
        expect(msg[:topics]).to eq("Rails setup, database config")
      end

      it "stores nil topics when not provided" do
        result = compressor.parse_compressed_result(
          "<summary>Did some work</summary>",
          chunk_path: "/tmp/chunk-1.md"
        )

        msg = result.first
        expect(msg[:topics]).to be_nil
      end

      it "embeds previous_chunks references in the content" do
        previous = [
          { basename: "2026-03-08-abc12345-chunk-1.md", topics: "Rails setup, database config" },
          { basename: "2026-03-08-abc12345-chunk-2.md", topics: "Deploy pipeline, bug fixes" }
        ]

        result = compressor.parse_compressed_result(
          "<topics>Refactoring</topics>\n<summary>Current work</summary>",
          chunk_path: "/tmp/chunk-3.md",
          topics: "Refactoring",
          previous_chunks: previous
        )

        msg = result.first
        content = msg[:content]

        # Should include a "Previous chunks" section (now "newest first")
        expect(content).to include("Previous chunks (newest first)")

        # Should reference each previous chunk by basename
        expect(content).to include("chunk-1.md")
        expect(content).to include("chunk-2.md")

        # Should include topics for each previous chunk
        expect(content).to include("Rails setup, database config")
        expect(content).to include("Deploy pipeline, bug fixes")

        # Should include file_reader hint
        expect(content).to include("file_reader")

        # Newest should appear first (chunk-2 before chunk-1 in string)
        pos_2 = content.index("chunk-2.md")
        pos_1 = content.index("chunk-1.md")
        expect(pos_2).to be < pos_1
      end

      it "does NOT include previous_chunks section when previous_chunks is empty" do
        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-1.md",
          previous_chunks: []
        )

        msg = result.first
        expect(msg[:content]).not_to include("Previous chunks")
      end

      it "handles previous_chunks with nil topics gracefully" do
        previous = [
          { basename: "chunk-1.md", topics: nil },
          { basename: "chunk-2.md", topics: "Some work" }
        ]

        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-3.md",
          previous_chunks: previous
        )

        content = result.first[:content]
        # chunk-1.md should appear without " — " suffix
        expect(content).to include("chunk-1.md")
        # chunk-2.md should include its topics
        expect(content).to include("Some work")
      end

      it "caps at 10 visible chunks and shows newest first (reverse order)" do
        # Simulate 12 previous chunks
        previous = (1..12).map do |i|
          { basename: "chunk-#{i}.md", topics: "Topic #{i}" }
        end

        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-13.md",
          previous_chunks: previous
        )

        content = result.first[:content]

        # Should show only the 10 newest: chunk-12 through chunk-3 (reverse order)
        expect(content).to include("chunk-12.md")
        expect(content).to include("chunk-3.md")

        # Should NOT show the 2 oldest in the numbered list
        # (they appear only in the "older chunks back to" summary line)
        # chunk-12 through chunk-3 = 10 visible entries
        (3..12).each do |i|
          expect(content).to include("chunk-#{i}.md")
        end

        # Should mention older chunks count and reference the oldest
        expect(content).to include("and 2 older chunks back to")
        expect(content).to include("`chunk-1.md`")

        # chunk-2.md should NOT appear at all (not in visible list, not in older note)
        expect(content).not_to include("chunk-2.md")

        # Should mention older chunks count
        expect(content).to include("and 2 older chunks back to")

        # Newest should appear first (chunk-12 before chunk-11 in string)
        pos_12 = content.index("chunk-12.md")
        pos_11 = content.index("chunk-11.md")
        expect(pos_12).to be < pos_11
      end

      it "shows all chunks without cap note when total <= 10" do
        previous = (1..5).map do |i|
          { basename: "chunk-#{i}.md", topics: "Topic #{i}" }
        end

        result = compressor.parse_compressed_result(
          "<summary>Work</summary>",
          chunk_path: "/tmp/chunk-6.md",
          previous_chunks: previous
        )

        content = result.first[:content]

        # All 5 should be visible
        expect(content).to include("chunk-1.md")
        expect(content).to include("chunk-5.md")

        # No "older chunks" note
        expect(content).not_to include("older chunks back to")
      end

      it "previous_chunks section appears between summary and current chunk anchor" do
        previous = [{ basename: "chunk-1.md", topics: "Setup" }]

        result = compressor.parse_compressed_result(
          "<summary>Work done</summary>",
          chunk_path: "/tmp/chunk-2.md",
          previous_chunks: previous
        )

        content = result.first[:content]

        # The previous chunks section should come after the summary text
        # and before the current chunk anchor
        summary_pos = content.index("Work done")
        prev_chunks_pos = content.index("Previous chunks")
        current_anchor_pos = content.index("Current chunk archived at")

        expect(summary_pos).to be < prev_chunks_pos
        expect(prev_chunks_pos).to be < current_anchor_pos
      end
    end

    describe "#rebuild_with_compression with topics and previous_chunks" do
      let(:compressor) { described_class.new(nil) }
      let(:system_msg) { { role: "system", content: "System prompt" } }
      let(:recent_msg) { { role: "user", content: "Recent" } }

      it "passes topics through to the compressed summary message" do
        result = compressor.rebuild_with_compression(
          "<topics>Rails, DB</topics>\n<summary>Work</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: "/tmp/chunk-1.md",
          topics: "Rails, DB"
        )

        summary = result.find { |m| m[:compressed_summary] }
        expect(summary[:topics]).to eq("Rails, DB")
      end

      it "embeds previous_chunks in the rebuilt summary content" do
        previous = [{ basename: "chunk-1.md", topics: "Initial setup" }]

        result = compressor.rebuild_with_compression(
          "<summary>Second batch of work</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: "/tmp/chunk-2.md",
          previous_chunks: previous
        )

        summary = result.find { |m| m[:compressed_summary] }
        expect(summary[:content]).to include("Previous chunks")
        expect(summary[:content]).to include("chunk-1.md")
        expect(summary[:content]).to include("Initial setup")
      end

      it "history role sequence still valid with previous_chunks (summary as user anchor)" do
        previous = [{ basename: "chunk-1.md", topics: "Setup" }]

        result = compressor.rebuild_with_compression(
          "<summary>Recent work</summary>",
          original_messages: [system_msg],
          recent_messages: [recent_msg],
          chunk_path: "/tmp/chunk-2.md",
          previous_chunks: previous
        )

        roles = result.map { |m| m[:role].to_s }
        expect(roles[0]).to eq("system")
        expect(roles[1]).to eq("user")  # summary still acts as user anchor
        expect(roles[1..]).not_to include("system")  # system only at position 0
      end
    end

    # Regression: a previous implementation placed the compressed summary as
    # `role: "assistant"` right after the `system` message. If the very next
    # kept message was also an assistant (e.g. because the last user turn had
    # already been archived into the chunk), the rebuilt history sent to the
    # API contained two consecutive assistant messages — and worse, an
    # `assistant + tool_calls` chain with no preceding user anchor. OpenAI-
    # compatible providers reject this with 400 "tool_use ids found without
    # tool_result blocks" / "messages must alternate".
    #
    # The summary must be `role: "user"` so it acts as the anchor for any
    # orphaned assistant/tool_result messages that follow it.
    describe "#rebuild_with_compression history structure (regression)" do
      let(:compressor) { described_class.new(nil) }
      let(:system_msg) { { role: "system", content: "System prompt" } }

      # Helper: flatten rebuilt history into a role sequence for assertions
      def role_sequence(messages)
        messages.map { |m| m[:role].to_s }
      end

      it "never produces two consecutive assistant messages after compression" do
        # Scenario: the chunk swallowed the trailing user turn; recent_messages
        # starts with an assistant message carrying tool_calls.
        recent = [
          { role: "assistant", content: "", tool_calls: [{ id: "t1", name: "shell", arguments: {} }] },
          { role: "tool",      content: "output", tool_call_id: "t1" },
          { role: "assistant", content: "Done." }
        ]

        result = compressor.rebuild_with_compression(
          "<summary>Earlier work summary</summary>",
          original_messages: [system_msg],
          recent_messages: recent,
          chunk_path: "/tmp/fake-chunk-1.md"
        )

        roles = role_sequence(result)
        # Walk the sequence and assert no two adjacent assistants
        roles.each_cons(2) do |a, b|
          expect([a, b]).not_to eq(%w[assistant assistant]),
            "found consecutive assistants in rebuilt history: #{roles.inspect}"
        end
      end

      it "places a user message before any assistant-with-tool_calls chain" do
        # This is the exact shape that triggered the production 400 error:
        # system → [summary] → assistant(tool_calls) → tool → assistant
        recent = [
          { role: "assistant", content: "", tool_calls: [{ id: "t1", name: "shell", arguments: {} }] },
          { role: "tool",      content: "ok", tool_call_id: "t1" }
        ]

        result = compressor.rebuild_with_compression(
          "<summary>Prior conversation</summary>",
          original_messages: [system_msg],
          recent_messages: recent,
          chunk_path: "/tmp/fake-chunk-1.md"
        )

        # Find the first assistant message that carries tool_calls
        first_tool_call_idx = result.index { |m| m[:role] == "assistant" && !Array(m[:tool_calls]).empty? }
        expect(first_tool_call_idx).not_to be_nil

        # Every assistant+tool_calls must have at least one user message somewhere before it
        preceding = result[0...first_tool_call_idx]
        expect(preceding.any? { |m| m[:role] == "user" }).to be(true),
          "no user anchor before assistant(tool_calls); got roles: #{role_sequence(result).inspect}"
      end

      it "rebuilt history starts with system then user (summary acts as user anchor)" do
        recent = [{ role: "assistant", content: "hello" }]

        result = compressor.rebuild_with_compression(
          "<summary>s</summary>",
          original_messages: [system_msg],
          recent_messages: recent,
          chunk_path: nil
        )

        expect(result[0][:role]).to eq("system")
        expect(result[1][:role]).to eq("user")
        expect(result[1][:compressed_summary]).to be true
      end
    end
  end

  # ── chunk_index derivation from disk ─────────────────────────────────────────
  #
  # chunk_index MUST be derived by scanning the sessions directory for existing
  # chunk files matching the current session — NOT from @compressed_summaries.size
  # (which resets to 0 on every process restart) and NOT from counting
  # compressed_summary messages in history (which caps at 1 because each
  # compression's rebuild keeps only the latest summary).
  #
  # The SessionManager owns all on-disk chunk I/O; these tests exercise it
  # directly rather than reaching through an agent helper.
  describe "SessionManager chunk discovery" do
    let(:sm) { Clacky::SessionManager.new(sessions_dir: sessions_dir) }

    # Seed a chunk using SessionManager's own write method so tests exercise
    # the real naming convention.
    def seed_chunk(sid, ca, idx, topics: nil, content_extra: "")
      md = +"---\nsession_id: #{sid}\nchunk: #{idx}\n"
      md << "topics: #{topics}\n" if topics
      md << "---\n\n# chunk #{idx}#{content_extra}\n"
      sm.write_chunk(sid, ca, idx, md)
    end

    it "returns [] when no chunks exist on disk yet" do
      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing).to eq([])
      expect(sm.next_chunk_index(session_id, created_at)).to eq(1)
    end

    it "returns 2 when chunk-1.md already exists on disk" do
      seed_chunk(session_id, created_at, 1, topics: "topic one")

      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing.size).to eq(1)
      expect(existing.first[:index]).to eq(1)
      expect(existing.first[:topics]).to eq("topic one")

      expect(sm.next_chunk_index(session_id, created_at)).to eq(2)
    end

    it "returns 3 when both chunk-1.md and chunk-2.md exist on disk (regression)" do
      # THIS IS THE REGRESSION: the old implementation returned 2 here because
      # history only ever has 1 compressed_summary message. Disk-based discovery
      # correctly sees both chunk-1.md and chunk-2.md.
      seed_chunk(session_id, created_at, 1, topics: "t1")
      seed_chunk(session_id, created_at, 2, topics: "t2")

      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing.map { |c| c[:index] }).to eq([1, 2])

      expect(sm.next_chunk_index(session_id, created_at)).to eq(3)
    end

    it "sorts chunks ascending by index even when filesystem order differs" do
      # Write in reverse order so filesystem iteration may not match index order
      seed_chunk(session_id, created_at, 3, topics: "third")
      seed_chunk(session_id, created_at, 1, topics: "first")
      seed_chunk(session_id, created_at, 2, topics: "second")

      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing.map { |c| c[:index] }).to eq([1, 2, 3])
      expect(existing.map { |c| c[:topics] }).to eq(["first", "second", "third"])
    end

    it "handles double-digit chunk numbers correctly (chunk-10 > chunk-9)" do
      # Lexicographic sort would put chunk-10 between chunk-1 and chunk-2 — we
      # must parse the integer to compare correctly.
      [1, 2, 9, 10].each { |i| seed_chunk(session_id, created_at, i, topics: "t#{i}") }

      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing.map { |c| c[:index] }).to eq([1, 2, 9, 10])
      expect(sm.next_chunk_index(session_id, created_at)).to eq(11)
    end

    it "returns [] when session_id or created_at is missing" do
      expect(sm.chunks_for_current(nil, created_at)).to eq([])
      expect(sm.chunks_for_current(session_id, nil)).to eq([])
      expect(sm.next_chunk_index(nil, created_at)).to eq(1)
    end

    it "only matches chunks for the current session (session_id + datetime prefix)" do
      # A different session in the same directory must not leak into results
      other_session_id = "zzzzzzzz-0000-0000-0000-000000000000"
      seed_chunk(other_session_id, created_at, 5, topics: "other")

      seed_chunk(session_id, created_at, 1, topics: "mine")

      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing.size).to eq(1)
      expect(existing.first[:index]).to eq(1)
      expect(existing.first[:topics]).to eq("mine")
    end

    it "reads topics from chunk MD front matter" do
      seed_chunk(session_id, created_at, 1, topics: "Rails setup, DB config")

      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing.first[:topics]).to eq("Rails setup, DB config")
    end

    it "tolerates chunks without topics in front matter" do
      seed_chunk(session_id, created_at, 1, topics: nil)

      existing = sm.chunks_for_current(session_id, created_at)
      expect(existing.first[:topics]).to be_nil
    end

    it "#write_chunk returns a path with the correct naming convention" do
      path = sm.write_chunk(session_id, created_at, 7, "# content")
      filename = File.basename(path)
      expect(filename).to match(/\A2026-03-08-10-00-00-abc12345-chunk-7\.md\z/)
      expect(File.exist?(path)).to be true
      expect(File.read(path)).to eq("# content")
    end

    it "#write_chunk chmods the file to 0600" do
      path = sm.write_chunk(session_id, created_at, 1, "content")
      mode = File.stat(path).mode & 0o777
      expect(mode).to eq(0o600)
    end

    it "#write_chunk returns nil when session_id or created_at is missing" do
      expect(sm.write_chunk(nil, created_at, 1, "x")).to be_nil
      expect(sm.write_chunk(session_id, nil, 1, "x")).to be_nil
    end
  end

  # ── End-to-end regression: 3+ consecutive compressions ───────────────────────
  #
  # Reproduces the production bug: after the second compression, every
  # subsequent compression was overwriting chunk-2.md and losing references
  # to chunk-1.md, because chunk_index was derived from history (which caps
  # at 1 compressed_summary message after rebuild).
  #
  # With the disk-based fix:
  #   - Each compression writes chunk-N.md with a unique, monotonically
  #     increasing N (1, 2, 3, 4, ...)
  #   - The new summary message embeds references to ALL prior chunks on disk
  describe "end-to-end: consecutive compressions produce unique chunk files" do
    # A minimal agent that carries just the state handle_compression_response needs
    let(:full_agent_class) do
      Class.new do
        include Clacky::Agent::MessageCompressorHelper

        attr_accessor :session_id, :created_at, :compressed_summaries,
                      :compression_level, :previous_total_tokens,
                      :history, :message_compressor, :ui, :config

        # Expose for the helper's instance-variable access pattern
        def initialize
          @compressed_summaries = []
          @compression_level = 0
          @previous_total_tokens = 0
          @ui = nil
        end
      end
    end

    let(:cfg) do
      instance_double(Clacky::AgentConfig, enable_compression: true)
    end

    subject(:full_agent) do
      a = full_agent_class.new
      a.session_id = session_id
      a.created_at = created_at
      a.config = cfg
      a.history = Clacky::MessageHistory.new([])
      a.message_compressor = Clacky::MessageCompressor.new(nil)
      a
    end

    # Simulates one ACTIVE compression round (triggers when token/message
    # thresholds are exceeded during normal use). Always creates a new chunk.
    def run_compression_round(agent, round_number)
      run_compression_round_internal(agent, round_number, force_new_chunk: true)
    end

    # Simulates one IDLE compression round (triggers when user is idle).
    # Always merges into the previous chunk when one exists.
    def run_idle_compression_round(agent, round_number)
      run_compression_round_internal(agent, round_number, force_new_chunk: false)
    end

    def run_compression_round_internal(agent, round_number, force_new_chunk:)
      # Seed history: system + several user/assistant turns + some recent msgs
      system = { role: "system", content: "System prompt" }

      # If prior compressions happened, the history already contains the latest
      # compressed_summary and some post-summary messages. Preserve those.
      pre_existing = agent.history.to_a
      new_turns = 6.times.flat_map do |i|
        [
          { role: "user", content: "round #{round_number} user msg #{i}" },
          { role: "assistant", content: "round #{round_number} reply #{i}" }
        ]
      end

      if pre_existing.empty?
        agent.history = Clacky::MessageHistory.new([system, *new_turns])
      else
        # Append new turns to the existing history (which already has system + summary + recent)
        agent.history.replace_all(pre_existing + new_turns)
      end

      all = agent.history.to_a
      recent_messages = all.last(4)

      compression_context = {
        recent_messages: recent_messages,
        original_token_count: 50_000,
        original_message_count: all.size,
        compression_level: round_number,
        force_new_chunk: force_new_chunk
      }

      # Insert the compression instruction (as the real flow does)
      agent.history.append({ role: "user", content: "compress please", system_injected: true })

      # Fake LLM response
      fake_response = {
        content: "<topics>Round #{round_number} topics</topics>\n<summary>Round #{round_number} summary body</summary>"
      }

      agent.send(:handle_compression_response, fake_response, compression_context)

      # Return the latest chunk info for assertions. Read from SessionManager
      # (the canonical owner of chunk discovery).
      sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)
      latest_chunk = sm.chunks_for_current(agent.session_id, agent.created_at).last
      summary_msg = agent.history.to_a.find { |m| m[:compressed_summary] }
      [latest_chunk, summary_msg]
    end

    it "produces chunk-1.md, chunk-2.md, chunk-3.md on three consecutive compressions (no overwrite)" do
      chunk1, summary1 = run_compression_round(full_agent, 1)
      chunk2, summary2 = run_compression_round(full_agent, 2)
      chunk3, summary3 = run_compression_round(full_agent, 3)

      # Each round produced a distinct chunk file on disk
      expect(chunk1[:index]).to eq(1)
      expect(chunk2[:index]).to eq(2)
      expect(chunk3[:index]).to eq(3)

      expect(chunk1[:basename]).to include("chunk-1.md")
      expect(chunk2[:basename]).to include("chunk-2.md")
      expect(chunk3[:basename]).to include("chunk-3.md")

      # All three files still exist (no overwrites)
      expect(File.exist?(chunk1[:path])).to be true
      expect(File.exist?(chunk2[:path])).to be true
      expect(File.exist?(chunk3[:path])).to be true

      # Each file has distinct content (summaries differ per round)
      expect(File.read(chunk1[:path])).to include("round 1 user msg")
      expect(File.read(chunk2[:path])).to include("round 2 user msg")
      expect(File.read(chunk3[:path])).to include("round 3 user msg")

      # The latest summary message references ALL prior chunks (chunk-1 AND chunk-2)
      expect(summary3[:content]).to include("chunk-1.md")
      expect(summary3[:content]).to include("chunk-2.md")
      # And the current chunk anchor
      expect(summary3[:content]).to include("chunk-3.md")

      # Previous-chunks section is present with topics from BOTH earlier rounds
      expect(summary3[:content]).to include("Round 1 topics")
      expect(summary3[:content]).to include("Round 2 topics")
    end

    it "continues to produce unique chunks for 5 consecutive compressions" do
      5.times { |i| run_compression_round(full_agent, i + 1) }

      chunk_files = Dir.glob(File.join(sessions_dir, "*-chunk-*.md")).map { |p| File.basename(p) }
      # Exactly 5 unique chunk indexes
      indexes = chunk_files.map { |n| n[/-chunk-(\d+)\.md\z/, 1].to_i }.sort
      expect(indexes).to eq([1, 2, 3, 4, 5])
    end

    # ── chunk merging: idle compression always merges ──────────────────────────
    #
    # Idle compression (force_new_chunk: false) always merges into the previous
    # chunk when one exists. Active compression (force_new_chunk: true) always
    # creates a new chunk regardless.

    it "idle compression merges into the previous chunk" do
      # First compression is active (no previous chunk exists yet) → chunk-1
      run_compression_round(full_agent, 1)
      # Second is idle → merges into chunk-1
      run_idle_compression_round(full_agent, 2)

      sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)
      chunks = sm.chunks_for_current(full_agent.session_id, full_agent.created_at)

      # Only ONE chunk file exists — round 2 merged into chunk-1
      expect(chunks.map { |c| c[:index] }).to eq([1])

      merged_path = chunks.first[:path]
      content = File.read(merged_path)

      # Both rounds' content live in the single chunk
      expect(content).to include("round 1 user msg")
      expect(content).to include("round 2 user msg")

      # Front matter reflects the merge
      expect(content).to include("merged_count: 2")
      expect(content).to include("Round 1 topics")
      expect(content).to include("Round 2 topics")
    end

    it "active compression creates a new chunk even after idle merges" do
      run_compression_round(full_agent, 1)         # active → chunk-1
      run_idle_compression_round(full_agent, 2)    # idle  → merged into chunk-1
      _chunk3, summary = run_compression_round(full_agent, 3)  # active → new chunk-2

      sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)
      chunks = sm.chunks_for_current(full_agent.session_id, full_agent.created_at)
      expect(chunks.map { |c| c[:index] }).to eq([1, 2])
      # New summary indexes the earlier chunk-1 as a previous chunk
      expect(summary[:content]).to include("Previous chunks")
      expect(summary[:content]).to include("chunk-1.md")
    end

    it "first compression always creates chunk-1 regardless" do
      # Even idle compression creates chunk-1 when no previous chunk exists
      run_idle_compression_round(full_agent, 1)

      sm = Clacky::SessionManager.new(sessions_dir: sessions_dir)
      chunks = sm.chunks_for_current(full_agent.session_id, full_agent.created_at)
      expect(chunks.map { |c| c[:index] }).to eq([1])
      expect(File.read(chunks.first[:path])).not_to include("merged_count")
    end

    it "multiple idle compressions in a row all merge into the same chunk" do
      run_compression_round(full_agent, 1)  # active → chunk-1
      3.times { |i| run_idle_compression_round(full_agent, i + 2) }  # all idle → all merge

      chunks = Clacky::SessionManager.new(sessions_dir: sessions_dir)
        .chunks_for_current(full_agent.session_id, full_agent.created_at)
      expect(chunks.map { |c| c[:index] }).to eq([1])

      content = File.read(chunks.first[:path])
      expect(content).to include("merged_count: 4")  # 1 base + 3 merges
      expect(content).to include("round 1 user msg")
      expect(content).to include("round 4 user msg")
    end

    it "mixed active and idle compressions create appropriate chunks" do
      run_compression_round(full_agent, 1)         # active  → chunk-1
      run_idle_compression_round(full_agent, 2)    # idle    → merged into chunk-1
      run_compression_round(full_agent, 3)         # active  → chunk-2
      run_idle_compression_round(full_agent, 4)    # idle    → merged into chunk-2
      run_compression_round(full_agent, 5)         # active  → chunk-3

      chunks = Clacky::SessionManager.new(sessions_dir: sessions_dir)
        .chunks_for_current(full_agent.session_id, full_agent.created_at)
      expect(chunks.map { |c| c[:index] }).to eq([1, 2, 3])

      # Chunk-2 has content from rounds 3 AND 4 (round 4 was idle → merged)
      c2 = File.read(chunks.find { |c| c[:index] == 2 }[:path])
      expect(c2).to include("round 3 user msg")
      expect(c2).to include("round 4 user msg")
      expect(c2).to include("merged_count: 2")
    end
  end
end
