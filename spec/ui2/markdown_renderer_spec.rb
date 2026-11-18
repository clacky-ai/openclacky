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

    # Regression: tty-markdown sized table columns with String#length, so a
    # cell of 40 Chinese characters was counted as 40 columns instead of 80.
    # The table was laid out too narrow, text ran past the border and the
    # whole block overran the pane, pushing every following line around.
    it "keeps a Chinese table inside the width it was given" do
      allow(TTY::Screen).to receive(:width).and_return(120)
      allow(Pastel).to receive(:new).and_wrap_original { |m, **| m.call(enabled: true) }

      markdown = <<~MD
        | 文件 | 改动 |
        |---|---|
        | `lib/clacky/agent.rb` | 注册工具时分两部分：agent 自己在 `tools:` 里点名的，加上别的扩展用 `attach` 挂过来、能匹配上的。`["*"]` 匹配所有 agent，写 id 的按 id 匹配，派生 agent 也认它基于的那个 agent 的 id。同一个工具只注册一次 |
        | `spec/clacky/agent_extension_tools_spec.rb` | 新增 4 个用例：`["*"]` 挂给所有 agent、按 id 挂载、不匹配或没写 attach 的不挂、点名和 attach 同时出现时只注册一次 |
      MD

      rows = described_class.render(markdown).lines.map do |line|
        Strings::ANSI.sanitize(line.chomp)
      end.select { |line| line.start_with?("┌", "├", "└", "│") }

      expect(rows.size).to be > 4
      # Every row is at most the terminal width, and the content rows line up
      # with the borders (they carry one trailing space).
      expect(rows.map { |row| Unicode::DisplayWidth.of(row) }.max).to be <= TTY::Screen.width
      border = Unicode::DisplayWidth.of(rows.find { |row| row.start_with?("┌") })
      rows.each do |row|
        expect(Unicode::DisplayWidth.of(row)).to be_between(border, border + 1)
      end
    end

    # Regression: a wrap used to return a line untouched when its *character*
    # count was below the limit, so 40 Chinese characters (80 columns) were
    # emitted unwrapped and overflowed.
    it "wraps a CJK line that fits by character count but not by display width" do
      text = "中文" * 15 # 30 characters, 60 terminal columns

      expect(Strings.wrap(text, 40).lines.size).to be >= 2
    end
  end

  describe "Strings.wrap CJK patch" do
    # Regression: reinsertion offsets recorded on one line were reused on the
    # next one, landing inside an escape sequence and printing its tail
    # (";230m") as literal text.
    it "does not split an escape sequence that continues onto the next line" do
      colored = "read ext.yml then \e[38;5;230mattach\e[39m field plus more words to force a wrap here"

      result = Strings.wrap(colored, 26)

      expect(result.lines.size).to be > 1
      visible = result.gsub(/\e\[[0-9;]*m/, "")
      expect(visible).not_to match(/[0-9]+;[0-9]+m|;[0-9]+m/)
    end
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

  describe "Strings::ANSI.sanitize" do
    # Regression: strings-ansi's matcher ends with an optional `([\];])?` group,
    # so it ate a literal ";" that happened to follow a color code. A cell
    # holding "`;230m`" was then measured one column short, and align padded it
    # back — pushing that row's right border one cell past its neighbours.
    it "keeps a semicolon that immediately follows a color code" do
      expect(Strings::ANSI.sanitize("\e[38;5;230m;230m\e[39m")).to eq(";230m")
    end

    it "still strips broken escape sequences" do
      expect(Strings::ANSI.sanitize("\e[33mfoo\[e0m")).to eq("foo[e0m")
    end

    it "keeps every table row border in the same column" do
      allow(TTY::Screen).to receive(:width).and_return(120)
      allow(Pastel).to receive(:new).and_wrap_original { |m, **| m.call(enabled: true) }

      md = <<~MD
        | 名称 | 说明 |
        |---|---|
        | 甲 | 尾部 `;230m` 露出来 |
        | 乙 | 短 |
      MD

      rows = described_class.render(md).lines.filter_map do |line|
        plain = Strings::ANSI.sanitize(line.chomp)
        next unless plain.include?("│")

        plain.each_char.with_index.filter_map do |char, i|
          Unicode::DisplayWidth.of(plain[0...i]) if char == "│"
        end
      end

      expect(rows.uniq.size).to eq(1)
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
