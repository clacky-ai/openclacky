# frozen_string_literal: true

require "json"
require "open3"

# Chat markdown is rendered in the browser, so the TUI's CJK repair
# (ui2/markdown_renderer.rb#align_box_diagrams) never runs for the web UI. The
# web renderer carries its own port; these specs keep the two from drifting.
RSpec.describe "Box diagrams in the web chat renderer" do
  root     = File.expand_path("../../..", __dir__)
  web      = File.join(root, "lib/clacky/web")
  js_path  = File.join(web, "lib/box-diagram.js")
  index    = File.read(File.join(web, "index.html"))
  css      = File.read(File.join(web, "app.css"))
  sessions = File.read(File.join(web, "sessions.js"))

  it "loads the aligner before the message renderer that calls it" do
    expect(index).to include('<script src="/lib/box-diagram.js"></script>')
    expect(index.index("/lib/box-diagram.js")).to be < index.index('src="/sessions.js"')
  end

  it "pins wide glyphs to two monospace columns" do
    expect(css).to match(/\.bd-c\s*\{[^}]*\bwidth:\s*2ch/)
  end

  it "routes framed code blocks past the syntax highlighter" do
    expect(sessions).to include("BoxDiagram.hasFrame(code)")
    expect(sessions).to include('<pre class="box-diagram">')
    # The glyph spans must not leak into the clipboard.
    expect(sessions).to include("_copyTextAndFlash(codeBtn, codeEl.textContent")
  end

  describe "rendering behavior" do
    let(:node) { `command -v node 2>/dev/null`.strip }

    let(:harness) do
      <<~'JS'
        var fs = require("fs");
        var window = {};
        new Function("window", fs.readFileSync(process.env.BOX_DIAGRAM_JS, "utf8"))(window);
        var input = fs.readFileSync(0, "utf8");
        var aligned = window.BoxDiagram.align(input);
        process.stdout.write(JSON.stringify({
          framed: window.BoxDiagram.hasFrame(input),
          aligned: aligned,
          html: window.BoxDiagram.toHtml(aligned)
        }));
      JS
    end

    def render_in_browser(node, harness, js_path, source)
      skip "node is not installed" if node.empty?

      out, err, status = Open3.capture3({ "BOX_DIAGRAM_JS" => js_path }, node, "-e", harness,
                                        stdin_data: source)
      expect(status.success?).to be(true), err
      JSON.parse(out)
    end

    it "produces the same alignment as the TUI renderer" do
      diagrams = [
        [
          "┌──────────────────┐",
          "│  接入层   TUI(ui2)  │",
          "│ 飞书/企微/  │",
          "│ TG/Discord │",
          "└──────────────────┘"
        ].join("\n"),
        [
          "┌──────────────────────────────────┐",
          "│  工具                            │",
          "│  ┌────────────┐  ┌────────────┐  │",
          "│  │ ▤  时光机  │  │ ▤  预览    │  │",
          "│  └────────────┘  └────────────┘  │",
          "└──────────────────────────────────┘"
        ].join("\n"),
        [
          "┌────────────────────────────┐",
          "│  工具                       │",
          "└─────────────┬──────────────┘",
          "              │  统一的 UI Controller 抽象"
        ].join("\n")
      ]

      diagrams.each do |source|
        result = render_in_browser(node, harness, js_path, source)
        expect(result["aligned"]).to eq(
          Clacky::UI2::MarkdownRenderer.send(:align_box_diagrams, source)
        )
      end
    end

    it "wraps every wide glyph and escapes the markup characters" do
      result = render_in_browser(node, harness, js_path, "┌────────┐\n│ a<b & 中 │\n└────────┘")

      expect(result["html"]).to include('<span class="bd-c">中</span>')
      expect(result["html"]).to include("&lt;b")
      expect(result["html"]).to include("&amp;")
    end

    it "only claims frames drawn with square corners" do
      plain = render_in_browser(node, harness, js_path, "def foo\n  1\nend")
      rounded = render_in_browser(node, harness, js_path, "╭──────────╮\n│  ✦ 卡片  │\n╰──────────╯")

      expect(plain["framed"]).to be(false)
      expect(rounded["framed"]).to be(false)
    end
  end
end
