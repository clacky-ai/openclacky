# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/markdown_renderer"
require "tty-markdown"

RSpec.describe Clacky::UI2::MarkdownRenderer do
  describe ".render" do
    it "returns content unchanged when nil or empty" do
      expect(described_class.render(nil)).to be_nil
      expect(described_class.render("")).to eq("")
    end

    it "renders headers without raising" do
      expect { described_class.render("# Hello") }.not_to raise_error
      expect(described_class.render("# Hello")).to include("Hello")
    end

    # Regression: rouge 3.x calls CGI.parse internally, which was removed in Ruby 4.0.
    # Pinning rouge to < 5.0 lets bundler pick rouge 4.x on Ruby >= 2.7, which dropped
    # the CGI.parse dependency. MarkdownRenderer.render swallows StandardError, so we
    # assert against TTY::Markdown.parse directly to actually catch the regression.
    it "renders fenced code blocks without raising (rouge + Ruby 4.0 regression)" do
      markdown = <<~MD
        ```ruby
        def hello
          puts "world"
        end
        ```
      MD

      expect { TTY::Markdown.parse(markdown) }.not_to raise_error

      result = described_class.render(markdown)
      expect(result).to include("hello")
      expect(result).to include("world")
    end

    # Regression: strings 0.2.1 wrap raises IndexError on ANSI-colored CJK tables.
    it "falls back to uncolored rendering for Chinese tables at wide widths" do
      allow(TTY::Screen).to receive(:width).and_return(200)

      markdown = <<~MD
        | 文件 | 做什么 |
        |---|---|
        | `message_compressor_helper.rb` | 归档时提取附件的 name/type，序列化成 `_Display files: [...]_` 标记写入 chunk |
      MD

      result = described_class.render(markdown)
      expect(result).to include("message_compressor_helper")
      expect(result).to include("标记写入")
      expect(result).not_to include("`")
    end
  end

  describe ".markdown?" do
    it "detects code blocks" do
      expect(described_class.markdown?("```ruby\nx\n```")).to be true
    end

    it "detects headers" do
      expect(described_class.markdown?("# Title")).to be true
    end

    it "returns false for plain text" do
      expect(described_class.markdown?("just a plain sentence")).to be false
    end

    it "returns false for nil or empty" do
      expect(described_class.markdown?(nil)).to be false
      expect(described_class.markdown?("")).to be false
    end
  end
end
