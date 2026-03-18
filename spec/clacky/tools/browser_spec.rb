# frozen_string_literal: true

require "spec_helper"
require "clacky/tools/browser"

RSpec.describe Clacky::Tools::Browser do
  let(:tool) { described_class.new }

  describe "#compress_snapshot" do
    let(:snapshot_output) do
      <<~SNAP
        - document:
          - heading "Example" [ref=e1] [level=1]
          - link "Learn more" [ref=e2]:
            - /url: https://example.com/very/long/path?with=many&query=params&that=bloat&the=output
          - textbox "Email" [ref=e3]:
            - /placeholder: you@example.com
          - img
          - img "Logo with alt text"
          - button "Submit" [ref=e4]
          - link "Home" [ref=e5]:
            - /url: /
      SNAP
    end

    subject(:compressed) { tool.send(:compress_snapshot, snapshot_output) }

    it "removes /url: lines" do
      expect(compressed).not_to include("/url:")
    end

    it "removes /placeholder: lines" do
      expect(compressed).not_to include("/placeholder:")
    end

    it "removes bare img lines with no alt text" do
      lines = compressed.lines.map(&:strip)
      expect(lines).not_to include("- img")
    end

    it "keeps img lines that have alt text" do
      expect(compressed).to include("img \"Logo with alt text\"")
    end

    it "keeps all [ref=eN] anchors" do
      %w[e1 e2 e3 e4 e5].each do |ref|
        expect(compressed).to include("[ref=#{ref}]")
      end
    end

    it "keeps interactive elements" do
      expect(compressed).to include("button \"Submit\"")
      expect(compressed).to include("textbox \"Email\"")
      expect(compressed).to include("heading \"Example\"")
    end

    it "appends a compression note when lines were removed" do
      expect(compressed).to include("[snapshot compressed:")
    end

    it "is smaller than the original" do
      expect(compressed.length).to be < snapshot_output.length
    end

    it "returns output unchanged when there is nothing to remove" do
      plain = "- document:\n  - heading \"Title\" [ref=e1] [level=1]\n  - button \"Go\" [ref=e2]\n"
      result = tool.send(:compress_snapshot, plain)
      # No compression note added when nothing removed
      expect(result).not_to include("[snapshot compressed:")
      expect(result).to eq(plain)
    end

    it "handles empty input" do
      expect(tool.send(:compress_snapshot, "")).to eq("")
    end
  end

  describe "#format_result_for_llm" do
    context "when command is snapshot" do
      let(:big_snapshot) do
        # Build a snapshot with many /url: lines to exceed MAX_SNAPSHOT_CHARS
        lines = ["- document:\n"]
        50.times do |i|
          lines << "  - link \"Link #{i}\" [ref=e#{i}]:\n"
          lines << "    - /url: https://example.com/very/long/path/#{i}?utm_source=test&utm_medium=email\n"
        end
        lines.join
      end

      let(:result) do
        {
          action: "snapshot",
          success: true,
          exit_code: 0,
          stdout: big_snapshot,
          stderr: ""
        }
      end

      it "compresses snapshot output (removes /url: lines)" do
        formatted = tool.format_result_for_llm(result)
        expect(formatted[:stdout]).not_to include("/url:")
      end

      it "uses MAX_SNAPSHOT_CHARS limit (smaller than MAX_LLM_OUTPUT_CHARS)" do
        # The result stdout should be limited to ~MAX_SNAPSHOT_CHARS, not 6000
        formatted = tool.format_result_for_llm(result)
        expect(formatted[:stdout].length).to be <= described_class::MAX_SNAPSHOT_CHARS + 300
      end
    end

    context "when action is not snapshot" do
      let(:result) do
        {
          action: "open",
          success: true,
          exit_code: 0,
          stdout: "Page loaded\n",
          stderr: ""
        }
      end

      it "does not compress output" do
        formatted = tool.format_result_for_llm(result)
        expect(formatted[:stdout]).to eq("Page loaded\n")
      end
    end
  end
end
