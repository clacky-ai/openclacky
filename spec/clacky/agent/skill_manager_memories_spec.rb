# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "SkillManager memory helpers" do
  # Minimal class that mixes in SkillManager and redirects memories_base_dir to tmpdir
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::SkillManager

      attr_writer :memories_dir

      def memories_base_dir
        @memories_dir
      end

      public :load_memories_meta, :parse_memory_frontmatter
    end
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:agent)  { agent_class.new.tap { |a| a.memories_dir = tmpdir } }

  after { FileUtils.rm_rf(tmpdir) }

  # Helper: write a memory file and optionally back-date its mtime
  def write_memory(name, content, mtime: nil)
    path = File.join(tmpdir, name)
    File.write(path, content)
    FileUtils.touch(path, mtime: mtime) if mtime
    path
  end

  # ─────────────────────────────────────────────
  # parse_memory_frontmatter
  # ─────────────────────────────────────────────
  describe "#parse_memory_frontmatter" do
    it "parses YAML frontmatter correctly" do
      path = write_memory("test.md", <<~MD)
        ---
        topic: Ruby Tips
        description: Useful Ruby patterns
        updated_at: "2026-03-08"
        ---
        Some content here.
      MD

      fm = agent.parse_memory_frontmatter(path)
      expect(fm["topic"]).to eq("Ruby Tips")
      expect(fm["description"]).to eq("Useful Ruby patterns")
      expect(fm["updated_at"]).to eq("2026-03-08")
    end

    it "returns empty hash when no frontmatter present" do
      path = write_memory("plain.md", "Just plain content.\n")
      expect(agent.parse_memory_frontmatter(path)).to eq({})
    end

    it "returns empty hash on malformed YAML" do
      path = write_memory("bad.md", "---\n: bad: yaml:\n---\ncontent\n")
      expect(agent.parse_memory_frontmatter(path)).to eq({})
    end
  end

  # ─────────────────────────────────────────────
  # load_memories_meta — basic behavior
  # ─────────────────────────────────────────────
  describe "#load_memories_meta" do
    it "returns no-memories message when directory is empty" do
      expect(agent.load_memories_meta).to eq("(No long-term memories found.)")
    end

    it "returns no-memories message when directory does not exist" do
      agent.memories_dir = "/nonexistent/path/clacky/memories"
      expect(agent.load_memories_meta).to eq("(No long-term memories found.)")
    end

    it "lists memory files with topic, description and last-seen mtime" do
      write_memory("user.md", <<~MD)
        ---
        topic: User Profile
        description: Background info about the user
        ---
        Content.
      MD

      result = agent.load_memories_meta
      expect(result).to include("user.md")
      expect(result).to include("User Profile")
      expect(result).to include("Background info about the user")
      # mtime-based — always shows today's date for a freshly written file.
      expect(result).to include("last seen: #{Time.now.strftime("%Y-%m-%d")}")
    end

    it "ignores any legacy `updated_at` frontmatter field" do
      # Old memory files may still carry updated_at; we no longer surface it.
      write_memory("legacy.md", <<~MD)
        ---
        topic: Legacy
        description: Has stale frontmatter date
        updated_at: "2020-01-01"
        ---
        Content.
      MD

      result = agent.load_memories_meta
      expect(result).not_to include("2020-01-01")
      expect(result).not_to include("updated:")
      expect(result).to include("last seen:")
    end

    it "falls back to filename stem as topic when frontmatter is missing" do
      write_memory("my-topic.md", "No frontmatter here.\n")
      expect(agent.load_memories_meta).to include("my-topic")
    end

    it "shows '(no description)' when description is absent" do
      write_memory("nodesc.md", <<~MD)
        ---
        topic: Some Topic
        ---
        Content.
      MD
      expect(agent.load_memories_meta).to include("(no description)")
    end
  end

  # ─────────────────────────────────────────────
  # LRU: mtime ordering and file cap
  # ─────────────────────────────────────────────
  describe "#load_memories_meta — LRU ordering" do
    it "returns files sorted by mtime descending (most recently touched first)" do
      old_path = write_memory("old.md", "---\ntopic: Old\n---\n", mtime: Time.now - 3600)
      new_path = write_memory("new.md", "---\ntopic: New\n---\n", mtime: Time.now)

      result = agent.load_memories_meta
      expect(result.index("new.md")).to be < result.index("old.md")
    end

    it "promotes a file to the top after it is touched" do
      write_memory("alpha.md", "---\ntopic: Alpha\n---\n", mtime: Time.now - 7200)
      write_memory("beta.md",  "---\ntopic: Beta\n---\n",  mtime: Time.now - 3600)

      # alpha starts second; touch it to make it newest
      FileUtils.touch(File.join(tmpdir, "alpha.md"))

      result = agent.load_memories_meta
      expect(result.index("alpha.md")).to be < result.index("beta.md")
    end

    def write_many(count)
      count.times do |i|
        write_memory("mem-#{i.to_s.rjust(2, "0")}.md", "---\ntopic: Topic #{i}\n---\n",
                     mtime: Time.now - (count - i) * 60)
      end
    end

    it "lists every file without a hint when at the cap" do
      cap = Clacky::Agent::SkillManager::MAX_MEMORIES_META_FILES
      write_many(cap)

      result = agent.load_memories_meta
      expect(result.scan("| topic:").length).to eq(cap)
      expect(result).not_to include("older memories not listed")
    end

    it "returns at most MAX_MEMORIES_META_FILES files" do
      cap = Clacky::Agent::SkillManager::MAX_MEMORIES_META_FILES
      write_many(cap + 5)

      expect(agent.load_memories_meta.scan("| topic:").length).to eq(cap)
    end

    it "keeps the most recently touched files and drops the oldest beyond the cap" do
      cap = Clacky::Agent::SkillManager::MAX_MEMORIES_META_FILES
      write_many(cap + 5)

      result = agent.load_memories_meta
      expect(result).to include("mem-#{(cap + 4).to_s.rjust(2, "0")}.md")
      expect(result).to include("mem-05.md")
      expect(result).not_to include("mem-04.md")
    end

    it "appends a hint with the number of omitted files" do
      cap = Clacky::Agent::SkillManager::MAX_MEMORIES_META_FILES
      write_many(cap + 5)

      expect(agent.load_memories_meta).to end_with(
        "(5 older memories not listed — search ~/.clacky/memories/ with grep if needed)"
      )
    end

    it "honors an explicit limit" do
      write_many(10)

      result = agent.load_memories_meta(limit: 3)
      expect(result.scan("| topic:").length).to eq(3)
      expect(result).to include("mem-09.md", "mem-07.md")
      expect(result).not_to include("mem-06.md")
      expect(result).to end_with("(7 older memories not listed — search ~/.clacky/memories/ with grep if needed)")
    end
  end

  # ─────────────────────────────────────────────
  # Per-field truncation
  # ─────────────────────────────────────────────
  describe "#load_memories_meta — field truncation" do
    let(:topic_cap) { Clacky::Agent::SkillManager::MAX_MEMORY_TOPIC_CHARS }
    let(:desc_cap)  { Clacky::Agent::SkillManager::MAX_MEMORY_DESCRIPTION_CHARS }

    it "keeps fields at exactly the cap untouched" do
      write_memory("exact.md", "---\ntopic: #{"t" * topic_cap}\ndescription: #{"d" * desc_cap}\n---\n")

      result = agent.load_memories_meta
      expect(result).to include("topic: #{"t" * topic_cap} |")
      expect(result).to include("| #{"d" * desc_cap} |")
      expect(result).not_to include("…")
    end

    it "truncates an oversized topic with an ellipsis" do
      write_memory("long-topic.md", "---\ntopic: #{"t" * (topic_cap + 50)}\n---\n")

      result = agent.load_memories_meta
      expect(result).to include("topic: #{"t" * topic_cap}… |")
      expect(result).not_to include("t" * (topic_cap + 1))
    end

    it "truncates an oversized description with an ellipsis" do
      write_memory("long-desc.md", "---\ntopic: T\ndescription: #{"d" * (desc_cap + 500)}\n---\n")

      result = agent.load_memories_meta
      expect(result).to include("| #{"d" * desc_cap}… |")
      expect(result).not_to include("d" * (desc_cap + 1))
    end

    it "truncates by characters, not bytes, for multibyte text" do
      write_memory("cjk.md", "---\ntopic: T\ndescription: #{"记" * (desc_cap + 10)}\n---\n")

      expect(agent.load_memories_meta).to include("| #{"记" * desc_cap}… |")
    end

    it "collapses multi-line descriptions into a single line" do
      write_memory("multiline.md", <<~MD)
        ---
        topic: T
        description: |
          first line
          second line
        ---
      MD

      result = agent.load_memories_meta
      expect(result).to include("| first line second line |")
    end
  end
end
