# frozen_string_literal: true

require "spec_helper"

KNOWLEDGE_EXT_DIR = File.expand_path("../../lib/clacky/default_extensions/knowledge", __dir__)
require File.join(KNOWLEDGE_EXT_DIR, "lib/knowledge")
require File.join(KNOWLEDGE_EXT_DIR, "tools/kb_search")
require File.join(KNOWLEDGE_EXT_DIR, "tools/kb_read")

RSpec.describe "Knowledge default extension" do
  let(:root) { Dir.mktmpdir }

  before { Clacky::Knowledge.root = root }
  after do
    Clacky::Knowledge.root = nil
    FileUtils.remove_entry(root) if Dir.exist?(root)
  end

  def write_kb(enabled: true, extra: "")
    File.write(File.join(root, "kb.yml"), "version: 1\nenabled: #{enabled}\n#{extra}")
  end

  def write_entry(rel, body, meta = nil)
    path = File.join(root, "entries", rel)
    FileUtils.mkdir_p(File.dirname(path))
    front = meta ? "---\n#{meta.map { |k, v| "#{k}: #{v}" }.join("\n")}\n---\n" : ""
    File.write(path, front + body)
  end

  describe "manifest" do
    let(:state_file) { File.join(Dir.mktmpdir, "state.json") }

    before { stub_const("Clacky::ExtensionLoader::STATE_FILE", state_file) }
    after  { FileUtils.remove_entry(File.dirname(state_file)) }

    def load_builtin(tmp)
      Clacky::ExtensionLoader.load_all(
        layers: { builtin: File.dirname(KNOWLEDGE_EXT_DIR), installed: tmp, local: tmp }, force: true
      )
    end

    it "is off by default: contributes nothing until the user turns it on" do
      tmp = Dir.mktmpdir
      result = load_builtin(tmp)
      expect(result.errors).to be_empty
      expect(result.containers).to have_key("knowledge")
      expect(Clacky::ExtensionLoader.disabled?("knowledge")).to be true
      expect(result.hooks.select { |h| h.ext_id == "knowledge" }).to be_empty
      expect(result.tools.select { |t| t.ext_id == "knowledge" }).to be_empty
      expect(result.agents.map(&:id)).not_to include("knowledge")
    ensure
      FileUtils.remove_entry(tmp)
    end

    it "once enabled, adds a knowledge agent built on general, with the hook and tools scoped to it" do
      tmp = Dir.mktmpdir
      Clacky::ExtensionLoader.enable!("knowledge")
      result = load_builtin(tmp)
      expect(result.errors).to be_empty
      hooks = result.hooks.select { |h| h.ext_id == "knowledge" }
      expect(hooks.map { |h| h.spec["event"] }).to eq(["on_start"])
      tools = result.tools.select { |t| t.ext_id == "knowledge" }
      expect(tools.map(&:id)).to contain_exactly("kb_search", "kb_read")
      expect(tools.map { |t| t.spec["attach"] }).to all(eq(["knowledge"]))
      agent = result.agents.find { |a| a.id == "knowledge" }
      expect(agent.spec).to include("base_agent" => "general", "title_zh" => "知识库")
      expect(agent.spec["hidden"]).to be_falsey
      expect(File.read(agent.spec["prompt_abs"])).to include("[K1]", "kb_search")
      panel = result.panels.find { |p| p.ext_id == "knowledge" }
      expect(panel.id).to eq("kb")
      expect(Array(panel.spec["attach"])).to be_empty
      expect(result.api.map(&:ext_id)).to include("knowledge")
      view = File.read(File.join(KNOWLEDGE_EXT_DIR, "panels/kb/view.js"))
      expect(view).to include('mount("sidebar.nav.bottom"', "order: 110", 'registerWorkspace(WS_ID')
    ensure
      FileUtils.remove_entry(tmp)
    end
  end

  describe "panel view" do
    it "hints icon-only row buttons, but leaves the modal close button to its aria-label" do
      view = File.read(File.join(KNOWLEDGE_EXT_DIR, "panels/kb/view.js")).lines
      row = view.find { |l| l.include?('"kb-row-act"') }
      expect(row).to include("data-tooltip")
      expect(row).not_to include("title:")
      close = view.find { |l| l.include?('"modal-close-btn"') }
      expect(close).to include('"aria-label"')
      expect(close).not_to include("data-tooltip")
      expect(close).not_to include("title:")
      expect(view.join).to include('"close": "关闭"')
    end

    it "explains the recall score number on hover, in both languages" do
      view = File.read(File.join(KNOWLEDGE_EXT_DIR, "panels/kb/view.js"))
      expect(view).to include('"data-tooltip": t("recall.score.tip"')
      expect(view).to include('"recall.score.tip": "相关度 {{score}}\\n')
      expect(view).to include('"recall.score.tip": "Relevance {{score}}\\n')
    end

    it "keeps recent recall-test queries and can clear them, labelled in both languages" do
      view = File.read(File.join(KNOWLEDGE_EXT_DIR, "panels/kb/view.js"))
      expect(view).to include('"recall.history": "Recent searches"', '"recall.history.clear": "Clear"')
      expect(view).to include('"recall.history": "搜索历史"', '"recall.history.clear": "清空"')
      expect(view).to include('const HISTORY_KEY = "clacky-kb-recall-history"')
      expect(view).to include("rememberQuery(query)") # recorded on every search
      expect(view).to include("loadHistory().filter((old) => old !== v)") # newest first, de-duplicated
      expect(view).to include("saveHistory([])") # the Clear action
    end

    it "expands a hit in place instead of leaving the recall modal for the editor" do
      view = File.read(File.join(KNOWLEDGE_EXT_DIR, "panels/kb/view.js"))
      expect(view).not_to include("closeModal(); openEntry(")
      expect(view).to include('card.classList.add("expanded")')
      expect(view).to include(".kb-hit.expanded .kb-hit-text")
      # a chevron in the head, flipped when open, so the card reads as expandable
      expect(view).to include('class: "kb-hit-toggle"')
      expect(view).to include(".kb-hit.expanded .kb-hit-toggle { transform: rotate(180deg); }")
    end

    it "styles the recall history trigger with the accent hover and hides the native clear button" do
      view = File.read(File.join(KNOWLEDGE_EXT_DIR, "panels/kb/view.js"))
      expect(view).to include(".kb-recall-hist-btn:hover { background: color-mix(in srgb, var(--color-accent-primary) 8%, transparent)")
      expect(view).to include(".kb-recall-input::-webkit-search-cancel-button")
    end

    it "offers name / last-updated sorting, labelled in both languages and remembered" do
      view = File.read(File.join(KNOWLEDGE_EXT_DIR, "panels/kb/view.js"))
      expect(view).to include('"sort.name": "Default"', '"sort.time": "Last updated"')
      expect(view).to include('"sort.name": "默认"', '"sort.time": "更新时间"')
      expect(view).to include("newFolder, sortButton()")
      # Newest first for both groups; the choice survives a reload.
      expect(view).to include('state.sort === "time"')
      expect(view).to include('const SORT_KEY = "clacky-kb-sort"')
      expect(view).to include("localStorage.setItem(SORT_KEY, v)")
    end
  end

  describe "tokenizer" do
    it "splits Chinese into bigrams and Latin into lower-cased words" do
      expect(Clacky::Knowledge::Index.tokenize("振成楼 Hakka 1912")).to eq(%w[振成 成楼 hakka 1912])
      expect(Clacky::Knowledge::Index.tokenize("楼")).to eq(["楼"])
    end
  end

  describe "enabled switch" do
    it "turns on once entries/ has a .md file, with no kb.yml" do
      expect(Clacky::Knowledge.enabled?).to be false
      write_entry("a.md", "正文")
      expect(File.exist?(File.join(root, "kb.yml"))).to be false
      expect(Clacky::Knowledge.enabled?).to be true
    end

    it "stays off when kb.yml says enabled: false" do
      write_entry("a.md", "正文")
      write_kb(enabled: false)
      expect(Clacky::Knowledge.enabled?).to be false
    end

    it "creates entries/ when the hook file loads" do
      allow(Clacky::ExtensionHookRegistry).to receive(:add)
      load File.join(KNOWLEDGE_EXT_DIR, "hooks/kb_inject.rb")
      expect(Dir.exist?(File.join(root, "entries"))).to be true
    end
  end

  describe "store" do
    it "reads frontmatter and falls back to the relative path" do
      write_entry("点位/门楼.md", "门楼正文", id: "menlou", title: "振成楼门楼", category: "点位", source: "《楼志》p12")
      write_entry("人物/林鸿超.md", "生平")
      entries = Clacky::Knowledge.store.entries.sort_by(&:id)

      expect(entries.map(&:id)).to eq(%w[menlou 人物/林鸿超])
      expect(entries.first).to have_attributes(title: "振成楼门楼", folder: "点位", source: "《楼志》p12", body: "门楼正文")
      expect(entries.first).not_to respond_to(:category)
      expect(entries.last.title).to eq("林鸿超")
    end
  end

  describe "search" do
    before do
      write_kb
      write_entry("a.md", "振成楼建于1912年，是一座八卦形土楼。", title: "振成楼概况")
      write_entry("b.md", "承启楼是圆形土楼，被称为土楼之王。", title: "承启楼")
      write_entry("c.md", "客家擂茶的做法。", title: "擂茶")
    end

    it "ranks the relevant entry first and drops unrelated ones" do
      hits = Clacky::Knowledge.index.search("振成楼是哪一年建的", limit: 5)
      expect(hits.first.entry.title).to eq("振成楼概况")
      expect(hits.map { |h| h.entry.title }).not_to include("擂茶")
    end

    it "rebuilds the index when an entry changes" do
      expect(Clacky::Knowledge.index.search("福裕楼")).to be_empty
      write_entry("d.md", "福裕楼是府第式土楼。", title: "福裕楼")
      expect(Clacky::Knowledge.index.search("福裕楼").first.entry.title).to eq("福裕楼")
    end
  end

  describe "on_start hook" do
    let(:hook) do
      captured = nil
      allow(Clacky::ExtensionHookRegistry).to receive(:add) { |*_, &blk| captured = blk }
      load File.join(KNOWLEDGE_EXT_DIR, "hooks/kb_inject.rb")
      captured
    end
    let(:history) { Clacky::MessageHistory.new }
    let(:agent) do
      double("agent", history: history, agent_profile: double(name: "knowledge")).tap do |a|
        allow(a).to receive(:instance_variable_get).with(:@is_subagent).and_return(false)
      end
    end

    before { write_entry("a.md", "振成楼建于1912年。", title: "振成楼概况", source: "《楼志》") }

    it "injects cited passages without any kb.yml" do
      hook.call("振成楼什么时候建的", agent, { run_id: "3" })

      msg = history.to_a.last
      expect(msg).to include(role: "user", system_injected: true, task_id: 3)
      expect(msg[:content]).to include("[K1] 振成楼概况", "source: 《楼志》", "<knowledge_base>")
    end

    it "cites the folder an entry lives in" do
      write_entry("青岚茶志/第一章/起源.md", "青岚茶起源于清代。", title: "起源")
      hook.call("青岚茶起源", agent, {})
      expect(history.to_a.last[:content]).to include("[K1] 起源 · folder: 青岚茶志/第一章 (id: 青岚茶志/第一章/起源)")
    end

    it "does nothing when disabled, unmatched, or for subagents" do
      write_kb(enabled: false)
      hook.call("振成楼", agent, {})
      write_kb
      hook.call("擂茶", agent, {})
      allow(agent).to receive(:instance_variable_get).with(:@is_subagent).and_return(true)
      hook.call("振成楼", agent, {})

      expect(history.to_a).to be_empty
    end

    it "skips every agent other than knowledge" do
      %w[general coding secretary].each do |name|
        other = double("agent", history: history, agent_profile: double(name: name))
        allow(other).to receive(:instance_variable_get).with(:@is_subagent).and_return(false)
        hook.call("振成楼", other, {})
      end

      expect(history.to_a).to be_empty
    end

    it "never raises into the turn" do
      write_kb
      allow(Clacky::Knowledge).to receive(:index).and_raise("boom")
      expect { hook.call("振成楼", agent, {}) }.not_to raise_error
    end
  end

  describe "tools" do
    before do
      write_kb
      write_entry("a.md", "第一行\n振成楼建于1912年\n第三行\n第四行", id: "zcl", title: "振成楼概况")
    end

    it "kb_search returns cited hits" do
      result = Clacky::Tools::KbSearch.new.execute(query: "振成楼")
      expect(result[:count]).to eq(1)
      expect(result[:results]).to include("[K1] 振成楼概况", "(id: zcl)")
    end

    it "kb_read returns the full body or greps within it" do
      tool = Clacky::Tools::KbRead.new
      expect(tool.execute(id: "zcl")[:content]).to include("第四行")

      grep = tool.execute(id: "zcl", pattern: "1912", context: 1)
      expect(grep[:matches]).to eq(1)
      expect(grep[:content]).to eq("1: 第一行\n2: 振成楼建于1912年\n3: 第三行")
      expect(tool.execute(id: "nope")[:error]).to include("No entry")
    end

    it "reports not enabled instead of searching" do
      write_kb(enabled: false)
      expect(Clacky::Tools::KbSearch.new.execute(query: "振成楼")[:error]).to include("empty or turned off")
    end
  end
end
