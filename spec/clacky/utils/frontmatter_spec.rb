# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/frontmatter"

RSpec.describe Clacky::Utils::Frontmatter do
  def fm(body)
    described_class.parse("---\n#{body}\n---\nbody text\n")
  end

  describe ".parse" do
    it "parses plain string fields" do
      result = fm("topic: Ruby Tips\ndescription: Useful Ruby patterns")
      expect(result["topic"]).to eq("Ruby Tips")
      expect(result["description"]).to eq("Useful Ruby patterns")
    end

    it "keeps quoted date values as strings" do
      expect(fm("topic: a\nupdated_at: \"2026-03-08\"")["updated_at"]).to eq("2026-03-08")
    end

    # Legacy memory files written before v1.5.24 carry an unquoted `updated_at`.
    # YAML types it as a Date, which safe_load rejects unless permitted.
    it "does not drop the whole block for a bare date value" do
      result = fm("topic: 发布约定\ndescription: 线上发布的时间窗口\nupdated_at: 2026-05-07")
      expect(result["topic"]).to eq("发布约定")
      expect(result["description"]).to eq("线上发布的时间窗口")
      expect(result["updated_at"]).to eq(Date.new(2026, 5, 7))
    end

    it "tolerates other Date/Time typed fields" do
      expect(fm("topic: a\ncreated: 2026-11-17")["topic"]).to eq("a")
      expect(fm("topic: a\nlast_used: 2026-11-17 10:00")["topic"]).to eq("a")
    end

    it "falls back to field scanning when the block is not valid YAML" do
      result = fm("topic: a\ndescription: 部署: 先装 hashicorp")
      expect(result["topic"]).to eq("a")
      expect(result["description"]).to eq("部署: 先装 hashicorp")
    end

    it "returns an empty hash for unusable frontmatter" do
      expect(fm(": bad: yaml:")).to eq({})
    end

    it "returns an empty hash when YAML yields a non-hash" do
      expect(fm("just a string")).to eq({})
    end

    it "returns an empty hash without frontmatter" do
      expect(described_class.parse("plain text\n")).to eq({})
      expect(described_class.parse("")).to eq({})
    end

    it "returns an empty hash for an unclosed block" do
      expect(described_class.parse("---\ntopic: a\n")).to eq({})
    end

    it "ignores a horizontal rule mid-document" do
      expect(described_class.parse("intro\n\n---\ntopic: a\n---\n")).to eq({})
    end

    it "handles CRLF line endings" do
      content = "---\r\ntopic: a\r\nupdated_at: 2026-05-07\r\n---\r\nbody\r\n"
      result = described_class.parse(content)
      expect(result["topic"]).to eq("a")
      expect(result["updated_at"]).to eq(Date.new(2026, 5, 7))
    end

    it "handles an empty block" do
      expect(described_class.parse("---\n---\nbody\n")).to eq({})
    end
  end
end
