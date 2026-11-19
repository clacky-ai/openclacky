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

    # Regression: tty-markdown wraps one inline element at a time, so a
    # paragraph mixing Chinese text with `inline code` is only as short as its
    # longest single element. A real message came out as one 240-column line
    # in a 136-column pane; the terminal hard-wrapped it, everything below
    # moved down a row, and the screen looked like overlapping text with
    # crooked table borders.
    describe "lines that inline elements split into short pieces" do
      let(:paragraph) do
        "明白，目标是把每处都做对，同时保证主聊天不出问题。我又看了一遍分发逻辑：" \
          "主聊天对每个事件都检查 `ev.session_id === Sessions.activeId`" \
          "（`ws-dispatcher.js:603` 起）。所以只要侧边会话有自己的 session_id，" \
          "它的事件本来就进不了主聊天，不需要另外绕路。"
      end

      def widths(rendered)
        rendered.lines.map { |line| Unicode::DisplayWidth.of(Strings::ANSI.sanitize(line.chomp)) }
      end

      it "wraps the paragraph to the width it was given" do
        allow(TTY::Screen).to receive(:width).and_return(84) # 80 usable columns
        # Real sessions render with colour: stdout is a tty, so tty-markdown
        # enables Pastel. A piped test run silently exercises the colourless
        # path, which is exactly how the coloured wrap bug went unnoticed.
        allow(TTY::Markdown).to receive(:parse).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs, color: :always)
        end

        rendered = described_class.render(paragraph)

        expect(rendered).to include("\e[") # colour really is on
        expect(rendered.lines.size).to be > 2
        expect(widths(rendered).max).to be <= 80
      end

      it "keeps the inline code text intact" do
        allow(TTY::Screen).to receive(:width).and_return(84)

        plain = Strings::ANSI.sanitize(described_class.render(paragraph))
        expect(plain).to include("ws-dispatcher.js:603")
        expect(plain).to include("Sessions.activeId")
      end

      it "never leaves half a colour sequence in the text" do
        allow(TTY::Screen).to receive(:width).and_return(84)
        # Real sessions render with colour: stdout is a tty, so tty-markdown
        # enables Pastel. A piped test run silently exercises the colourless
        # path, which is exactly how the coloured wrap bug went unnoticed.
        allow(TTY::Markdown).to receive(:parse).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs, color: :always)
        end

        # Several colour runs on one line is what broke Strings.wrap: its
        # reinserted offsets landed inside another sequence, so the terminal
        # printed "0m", "9m", "97m" as body text.
        markdown = "- 代码核对基本完成。确认了 `fork_subagent`、`SessionManager#save`、" \
          "registry 的回收和驱逐逻辑、WS 断开处理（`on_ws_close`）、" \
          "软删除（`soft_delete_session`）这几处的实际写法"

        rendered = described_class.render(markdown)
        plain = Strings::ANSI.sanitize(rendered)

        expect(rendered).to include("\e[")
        expect(plain).not_to match(/\d{1,3}(?:;\d{1,3})+m/)
        expect(plain).not_to match(/(?<![0-9;])\d{1,3}m/)
        # No escape may survive on its own: every "\e" opens a full sequence.
        rendered.each_line do |line|
          expect(line.scan("\e").size).to eq(line.scan(/\e\[[0-9;]*m/).size)
        end
        expect(widths(rendered).max).to be <= 80
      end

      # Regression: with two colour runs on one line, Strings.wrap reinserted a
      # code at a stale offset, landing inside another sequence — "\e[97m" came
      # out as "\e" + "[97m", so the terminal printed "[97m" (and "0m", "9m")
      # as body text. This exact string is the minimal case that broke it.
      it "does not cut a colour sequence when several runs share a line" do
        coloured = "●\e[38;5;230mWS 断开处理（on_ws_close）、SessionManager#save、" \
          "\e[97mregistry 的回收和驱逐逻辑、registry 的回收和驱逐逻辑、"

        lines = described_class.send(:wrap_colored, coloured, 50, "  ")

        expect(lines.size).to be > 1
        lines.each do |line|
          expect(line.scan("\e").size).to eq(line.scan(/\e\[[0-9;]*m/).size)
          expect(Strings::ANSI.sanitize(line)).not_to match(/(?<![0-9;])\d{1,3}m/)
          expect(Unicode::DisplayWidth.of(Strings::ANSI.sanitize(line))).to be <= 50 + 2
        end
      end

      it "replays the active colour on continuation lines" do
        coloured = "确认了 \e[1mregistry 的回收和驱逐逻辑、WS 断开处理（on_ws_close）、" \
          "软删除（soft_delete_session）这几处的实际写法"

        lines = described_class.send(:wrap_colored, coloured, 24, "  ")

        expect(lines.size).to be > 1
        # The line that continues inside the bold run re-opens it.
        continuation = lines.find { |line| Strings::ANSI.sanitize(line).include?("WS 断开") }
        expect(continuation).to start_with("  \e[1m")
        expect(Unicode::DisplayWidth.of(Strings::ANSI.sanitize(continuation))).to be <= 24 + 2
      end

      # Regression: the table came out at width + 6 — borders cut off by the
      # pane — because shrinking columns per share and flooring each one left
      # the rounding difference on the table.
      it "keeps a wide Chinese table inside the pane with aligned borders" do
        allow(TTY::Screen).to receive(:width).and_return(124) # 120 usable
        # Real sessions render with colour: stdout is a tty, so tty-markdown
        # enables Pastel. A piped test run silently exercises the colourless
        # path, which is exactly how the coloured wrap bug went unnoticed.
        allow(TTY::Markdown).to receive(:parse).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs, color: :always)
        end

        markdown = <<~MD
          | 方面 | 上一版 | 改为 | 理由 |
          |---|---|---|---|
          | 事件通道 | 把侧边事件包成 `side_event`，借主会话的连接发 | 侧边会话就是 registry 里的一个正常会话，有自己的 session_id 和 `WebUIController` | 中断、排队、报错、状态、切模型全部走现有路径，不用另写一套 |
          | 不落盘 | 在各个保存点跳过 | 只在 `SessionManager#save` 入口加一句：`source == "side"` 时直接返回 | 任务结束、出错、中断、空闲压缩这十几个保存点都由这一处拦住 |
        MD

        rendered = described_class.render(markdown)
        table_lines = rendered.lines.select do |line|
          Strings::ANSI.sanitize(line).strip.start_with?("│", "┌", "├", "└")
        end

        expect(table_lines).not_to be_empty
        # Ignore the padding space tty-markdown puts after the closing border.
        borders = table_lines.map { |line| Strings::ANSI.sanitize(line).rstrip }
        expect(widths(borders.join("\n")).uniq.size).to eq(1)
        expect(widths(rendered).max).to be <= 120
      end

      # Regression: shrinking every column by its proportional share gave the
      # first column five cells, so "方面" broke into one character per row —
      # the header alone became two lines and the whole table grew tall enough
      # to fight with the rows below it.
      it "keeps the narrow column readable and gives the wide ones equal room" do
        allow(TTY::Screen).to receive(:width).and_return(130)
        allow($stdout).to receive(:tty?).and_return(true)

        markdown = <<~MD
          | 方面 | 上一版 | 改为 | 理由 |
          |---|---|---|---|
          | 事件通道 | 把侧边事件包成 `side_event`，借主会话的连接发 | 侧边会话就是 registry 里的一个正常会话，有自己的 session_id 和 `WebUIController` | 中断、排队、报错、状态、切模型全部走现有路径，不用另写一套 |
          | 不落盘 | 在各个保存点跳过 | 只在 `SessionManager#save` 入口加一句：`source == "side"` 时直接返回 | 任务结束、出错、中断、空闲压缩这十几个保存点都由这一处拦住 |
        MD

        plain = Strings::ANSI.sanitize(described_class.render(markdown))
        border = plain.lines.find { |line| line.strip.start_with?("┌") }

        expect(border).not_to be_nil
        cells = border.strip[1..-2].split("┬").map(&:length)
        # "方面" is four columns wide; anything under six squeezes the padding.
        expect(cells.first).to be >= 6
        expect(cells.drop(1).max - cells.drop(1).min).to be <= 1
        # Nothing in the rows may run past the grid.
        expect(plain.lines.map { |l| Unicode::DisplayWidth.of(l.chomp) }.max).to be <= 126
        expect(plain).to include("WebUIController")
        expect(plain).to include("SessionManager#save")
      end
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
