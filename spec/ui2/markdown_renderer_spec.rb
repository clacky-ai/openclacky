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

    # Regression: strings 0.2.1 wrap raised IndexError on ANSI-colored CJK tables,
    # silently downgrading the whole message to uncolored output. The
    # strings_cjk_patch must keep the colored path working.
    it "renders Chinese tables with colors instead of falling back" do
      allow(TTY::Screen).to receive(:width).and_return(200)
      allow(Pastel).to receive(:new).and_wrap_original { |m, **| m.call(enabled: true) }

      markdown = <<~MD
        | 文件 | 做什么 |
        |---|---|
        | `message_compressor_helper.rb` | 归档时提取附件的 name/type，序列化成 `_Display files: [...]_` 标记写入 chunk |
      MD

      result = described_class.render(markdown)
      expect(result).to include("message_compressor_helper")
      expect(result).to include("标记写入")
      expect(result).not_to include("`")
      expect(result.scan(/\e\[/)).not_to be_empty
    end

    it "renders long colored CJK paragraphs without falling back" do
      allow(TTY::Screen).to receive(:width).and_return(30)
      allow(Pastel).to receive(:new).and_wrap_original { |m, **| m.call(enabled: true) }

      markdown = <<~MD
        > 这是一段很长的中文引用文本，包含足够多的字符数来触发折行逻辑，验证 ANSI 颜色状态在折行后能够正确恢复而不会崩溃。
      MD

      result = described_class.render(markdown)
      expect(result).to include("验证")
      expect(result.scan(/\e\[/)).not_to be_empty
    end
  end

  describe "Strings.wrap CJK patch" do
    it "wraps ANSI-colored CJK text without IndexError and keeps colors per line" do
      colored = "\e[36m这是一段被染色的中文长文本，用来测试折行时颜色码的恢复，确保不会越界\e[0m"

      result = Strings.wrap(colored, 20)

      expect(result.lines.size).to be > 1
      result.lines.each do |line|
        expect(line).to start_with("\e[36m")
        expect(line.rstrip).to end_with("\e[0m")
      end
    end

    it "wraps ANSI-colored ASCII text preserving colors" do
      colored = "\e[31mred\e[0m plain \e[32mgreen text that wraps here\e[0m"

      result = Strings.wrap(colored, 12)

      expect(result.lines.size).to be > 1
      expect(result).to include("\e[32m")
      result.lines.each do |line|
        next unless line.include?("green") || line.include?("that") || line.include?("here")
        expect(line).to include("\e[32m")
      end
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
