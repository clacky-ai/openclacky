# frozen_string_literal: true

require "spec_helper"
require "clacky/tools/browser"

RSpec.describe Clacky::Tools::Browser do
  let(:tool) { described_class.new }

  # ---------------------------------------------------------------------------
  # compress_snapshot
  # ---------------------------------------------------------------------------
  describe "#compress_snapshot" do
    let(:snapshot_with_noise) do
      <<~SNAP
        - document:
          - heading "Example" [ref=e1]
          - link "Learn more" [ref=e2]:
            - /url: https://example.com/path
          - textbox "Email" [ref=e3]:
            - /placeholder: you@example.com
          - img
          - img "Logo"
          - button "Submit" [ref=e4]
      SNAP
    end

    subject(:compressed) { tool.send(:compress_snapshot, snapshot_with_noise) }

    it "removes /url: lines" do
      expect(compressed).not_to include("/url:")
    end

    it "removes /placeholder: lines" do
      expect(compressed).not_to include("/placeholder:")
    end

    it "removes bare img lines" do
      expect(compressed.lines.map(&:strip)).not_to include("- img")
    end

    it "keeps img lines with alt text" do
      expect(compressed).to include('img "Logo"')
    end

    it "keeps ref anchors" do
      %w[e1 e2 e3 e4].each { |r| expect(compressed).to include("[ref=#{r}]") }
    end

    it "appends compression note" do
      expect(compressed).to include("[snapshot compressed:")
    end

    it "returns unchanged output when nothing to remove" do
      plain = "- button \"Go\" [ref=e1]\n"
      expect(tool.send(:compress_snapshot, plain)).to eq(plain)
    end

    it "handles empty input" do
      expect(tool.send(:compress_snapshot, "")).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # build_ai_snapshot
  # ---------------------------------------------------------------------------
  describe "#build_ai_snapshot" do
    let(:snapshot_node) do
      {
        "id"   => "root",
        "role" => "document",
        "name" => "Example",
        "children" => [
          { "id" => "btn-1", "role" => "button",  "name" => "Continue" },
          { "id" => "txt-1", "role" => "textbox", "name" => "Email",
            "value" => "user@example.com" }
        ]
      }
    end

    subject(:output) { tool.send(:build_ai_snapshot, snapshot_node) }

    it "renders button ref" do
      expect(output).to include('- button "Continue" [ref=btn-1]')
    end

    it "renders textbox ref with value" do
      expect(output).to include('- textbox "Email" [ref=txt-1] value="user@example.com"')
    end

    it "renders the root document role" do
      expect(output).to include("- document")
    end

    context "with interactive: true" do
      subject(:output) { tool.send(:build_ai_snapshot, snapshot_node, interactive: true) }

      it "includes button" do
        expect(output).to include("button")
      end

      it "includes textbox" do
        expect(output).to include("textbox")
      end

      it "excludes non-interactive document role" do
        expect(output).not_to include("- document")
      end
    end

    context "with max_depth: 0" do
      subject(:output) { tool.send(:build_ai_snapshot, snapshot_node, max_depth: 0) }

      it "only shows the root node" do
        expect(output).to include("- document")
        expect(output).not_to include("button")
      end
    end

    it "handles nil/empty node gracefully" do
      expect(tool.send(:build_ai_snapshot, nil)).to eq("")
      expect(tool.send(:build_ai_snapshot, {})).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # MCP response extractors
  # ---------------------------------------------------------------------------
  describe "#extract_pages" do
    it "extracts pages from structuredContent" do
      result = {
        "structuredContent" => {
          "pages" => [
            { "id" => 1, "url" => "https://example.com", "selected" => true },
            { "id" => 2, "url" => "https://other.com",   "selected" => false }
          ]
        }
      }
      pages = tool.send(:extract_pages, result)
      expect(pages.size).to eq(2)
      expect(pages.first[:id]).to eq(1)
      expect(pages.first[:url]).to eq("https://example.com")
      expect(pages.first[:selected]).to be true
    end

    it "falls back to text content parsing" do
      result = {
        "content" => [
          { "type" => "text", "text" => "1: https://example.com [selected]\n2: https://other.com" }
        ]
      }
      pages = tool.send(:extract_pages, result)
      expect(pages.size).to eq(2)
      expect(pages.first[:url]).to eq("https://example.com")
      expect(pages.first[:selected]).to be true
    end

    it "returns empty array for nil/empty" do
      expect(tool.send(:extract_pages, nil)).to eq([])
      expect(tool.send(:extract_pages, {})).to eq([])
    end
  end

  describe "#extract_snapshot" do
    it "extracts snapshot from structuredContent" do
      node = { "id" => "root", "role" => "document" }
      result = { "structuredContent" => { "snapshot" => node } }
      expect(tool.send(:extract_snapshot, result)).to eq(node)
    end

    it "returns empty hash for missing snapshot" do
      expect(tool.send(:extract_snapshot, {})).to eq({})
    end
  end

  # ---------------------------------------------------------------------------
  # format_result_for_llm
  # ---------------------------------------------------------------------------
  describe "#format_result_for_llm" do
    it "returns error result unchanged" do
      result = { error: "something went wrong" }
      expect(tool.format_result_for_llm(result)).to eq(result)
    end

    it "compresses snapshot output" do
      output = "- link \"X\" [ref=e1]:\n  - /url: https://example.com\n"
      result = { action: "snapshot", success: true, output: output, profile: "user" }
      formatted = tool.format_result_for_llm(result)
      expect(formatted[:stdout]).not_to include("/url:")
    end

    it "does not compress non-snapshot output" do
      result = { action: "open", success: true, output: "Opened: https://x.com", profile: "user" }
      formatted = tool.format_result_for_llm(result)
      expect(formatted[:stdout]).to eq("Opened: https://x.com")
    end

    it "includes action and success fields" do
      result = { action: "tabs", success: true, output: "1: https://x.com", profile: "user" }
      formatted = tool.format_result_for_llm(result)
      expect(formatted[:action]).to eq("tabs")
      expect(formatted[:success]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # format_tabs
  # ---------------------------------------------------------------------------
  describe "#format_tabs" do
    it "formats tab list" do
      pages = [
        { id: 1, url: "https://example.com", selected: true },
        { id: 2, url: "https://other.com",   selected: false }
      ]
      output = tool.send(:format_tabs, pages)
      expect(output).to include("1: https://example.com [selected]")
      expect(output).to include("2: https://other.com")
    end

    it "returns message for empty tabs" do
      expect(tool.send(:format_tabs, [])).to eq("No open tabs.")
    end
  end

  # ---------------------------------------------------------------------------
  # parameter helpers
  # ---------------------------------------------------------------------------
  describe "#require_url" do
    it "returns url when present" do
      expect(tool.send(:require_url, { url: "https://example.com" })).to eq("https://example.com")
    end

    it "returns error hash when missing" do
      result = tool.send(:require_url, {})
      expect(result).to be_a(Hash)
      expect(result[:error]).to match(/url is required/)
    end
  end

  describe "#require_ref" do
    it "returns ref string when present" do
      expect(tool.send(:require_ref, "btn-1")).to eq("btn-1")
    end

    it "returns error hash when nil" do
      result = tool.send(:require_ref, nil)
      expect(result).to be_a(Hash)
      expect(result[:error]).to match(/ref is required/)
    end
  end

  # ---------------------------------------------------------------------------
  # truncate_output
  # ---------------------------------------------------------------------------
  describe "#truncate_output" do
    it "returns output unchanged when within limit" do
      out = "hello world"
      expect(tool.send(:truncate_output, out, 100)).to eq(out)
    end

    it "truncates long output with notice" do
      long_output = ("x" * 50 + "\n") * 100
      truncated = tool.send(:truncate_output, long_output, 200)
      expect(truncated.length).to be < long_output.length
      expect(truncated).to include("truncated")
    end
  end

  # ---------------------------------------------------------------------------
  # find_node_binary / chrome_mcp_available?



  # ---------------------------------------------------------------------------
  # build_evaluate_function
  # ---------------------------------------------------------------------------
  describe "#build_evaluate_function" do
    it "wraps any expression as an arrow returning that expression" do
      expect(tool.send(:build_evaluate_function, "document.title")).to eq("() => (document.title)")
    end

    it "wraps an async IIFE so its returned promise flows through" do
      js = "(async () => { const r = await fetch('/x'); return r.status })()"
      expect(tool.send(:build_evaluate_function, js)).to eq("() => (#{js})")
    end

    it "handles empty input" do
      expect(tool.send(:build_evaluate_function, "")).to eq("() => {}")
      expect(tool.send(:build_evaluate_function, "   ")).to eq("() => {}")
    end
  end

  # ---------------------------------------------------------------------------
  # apply_snapshot_window — query / offset
  # ---------------------------------------------------------------------------
  describe "#apply_snapshot_window" do
    let(:text) { (1..200).map { |i| "- line #{i}\n" }.join }

    it "returns text unchanged when no query/offset" do
      expect(tool.send(:apply_snapshot_window, text)).to eq(text)
    end

    it "returns a window around a query match" do
      out = tool.send(:apply_snapshot_window, text, query: "line 100")
      expect(out).to include("line 100")
      expect(out).to include("[snapshot window:")
      # window is centered, should not include very early or very late lines
      expect(out).not_to include("- line 1\n")
      expect(out).not_to include("- line 200\n")
    end

    it "reports when a query has no match" do
      out = tool.send(:apply_snapshot_window, text, query: "nowhere")
      expect(out).to include("no match for query")
    end

    it "applies offset when given" do
      out = tool.send(:apply_snapshot_window, text, offset: 50)
      expect(out).to include("[snapshot offset: showing from line 51")
      expect(out).not_to include("- line 1\n")
      expect(out).to include("- line 51\n")
    end

    it "reports when offset exceeds total lines" do
      out = tool.send(:apply_snapshot_window, text, offset: 9999)
      expect(out).to include(">= 200 total lines")
    end

    it "prefers query over offset when both given" do
      out = tool.send(:apply_snapshot_window, text, query: "line 100", offset: 50)
      expect(out).to include("[snapshot window:")
      expect(out).not_to include("[snapshot offset:")
    end
  end

  # ---------------------------------------------------------------------------
  # compress_snapshot — new statictext collapsing behaviour
  # ---------------------------------------------------------------------------
  describe "#compress_snapshot (statictext collapse)" do
    it "collapses consecutive text-only statictext lines" do
      input = <<~SNAP
        - main:
          - statictext "Hello"
          - statictext "world"
          - statictext "foo"
      SNAP
      out = tool.send(:compress_snapshot, input)
      expect(out).to include('statictext "Hello / world / foo"')
    end

    it "keeps statictext with refs separate from collapsing" do
      input = <<~SNAP
        - main:
          - statictext "alpha" [ref=t1]
          - statictext "beta" [ref=t2]
      SNAP
      out = tool.send(:compress_snapshot, input)
      expect(out).to include("[ref=t1]")
      expect(out).to include("[ref=t2]")
    end

    it "drops statictext that contains only digits (line numbers)" do
      input = <<~SNAP
        - code:
          - statictext "1"
          - statictext "2"
          - statictext "3"
          - statictext "real content"
      SNAP
      out = tool.send(:compress_snapshot, input)
      expect(out).not_to include('"1"')
      expect(out).not_to include('"2"')
      expect(out).to include("real content")
    end

    it "drops empty statictext entries" do
      input = <<~SNAP
        - main:
          - statictext ""
          - statictext "kept"
      SNAP
      out = tool.send(:compress_snapshot, input)
      expect(out).not_to match(/statictext ""/)
      expect(out).to include('"kept"')
    end
  end

  # ---------------------------------------------------------------------------
  # mcp_call retry behaviour
  # ---------------------------------------------------------------------------
  describe "#mcp_call retry" do
    let(:manager) { instance_double(Clacky::BrowserManager) }

    before do
      allow(Clacky::BrowserManager).to receive(:instance).and_return(manager)
    end

    it "retries once on 'No page found' after recovering selected page" do
      pages_result = {
        "structuredContent" => {
          "pages" => [{ "id" => 7, "url" => "https://x.com", "selected" => true }]
        }
      }
      call_count = 0
      allow(manager).to receive(:mcp_call) do |tool_name, _args|
        case tool_name
        when "click"
          call_count += 1
          raise "No page found" if call_count == 1
          { "ok" => true }
        when "list_pages" then pages_result
        when "select_page" then { "ok" => true }
        end
      end

      result = tool.send(:mcp_call, "click", { uid: "e1" })
      expect(result).to eq({ "ok" => true })
      expect(call_count).to eq(2)
    end

    it "raises a friendly message when there is no page to recover to" do
      empty_pages = { "structuredContent" => { "pages" => [] } }
      allow(manager).to receive(:mcp_call) do |tool_name, _args|
        case tool_name
        when "click" then raise "No page found"
        when "list_pages" then empty_pages
        end
      end

      expect { tool.send(:mcp_call, "click", { uid: "e1" }) }
        .to raise_error(RuntimeError, /no longer available/)
    end

    it "does not retry on unrelated errors" do
      call_count = 0
      allow(manager).to receive(:mcp_call) do |_tool_name, _args|
        call_count += 1
        raise "Element ref e1 not found"
      end

      expect { tool.send(:mcp_call, "click", { uid: "e1" }) }
        .to raise_error(RuntimeError, /Element ref e1 not found/)
      expect(call_count).to eq(1)
    end

    it "primes the page snapshot and retries once on 'No snapshot found for page'" do
      calls = []
      click_count = 0
      allow(manager).to receive(:mcp_call) do |tool_name, _args|
        calls << tool_name
        case tool_name
        when "click"
          click_count += 1
          raise "Error: No snapshot found for page 10. Use take_snapshot to capture one." if click_count == 1
          { "ok" => true }
        when "take_snapshot" then { "structuredContent" => { "snapshot" => {} } }
        when "list_pages" then { "structuredContent" => { "pages" => [] } }
        end
      end

      result = tool.send(:mcp_call, "click", { uid: "e1" })
      expect(result).to eq({ "ok" => true })
      expect(calls).to eq(%w[click list_pages take_snapshot click])
    end

    it "raises an actionable message when priming the snapshot fails" do
      allow(manager).to receive(:mcp_call) do |tool_name, _args|
        case tool_name
        when "click" then raise "No snapshot found for page 3."
        when "take_snapshot" then raise "boom"
        when "list_pages" then { "structuredContent" => { "pages" => [] } }
        end
      end

      expect { tool.send(:mcp_call, "click", { uid: "e1" }) }
        .to raise_error(RuntimeError, /action=snapshot first/)
    end

    it "tells the AI to re-snapshot when a ref has gone stale" do
      allow(manager).to receive(:mcp_call) do |tool_name, _args|
        raise 'Element uid "e9" not found on page 2.' if tool_name == "click"
        { "structuredContent" => { "pages" => [] } }
      end

      expect { tool.send(:mcp_call, "click", { uid: "e9" }) }
        .to raise_error(RuntimeError, /use action=snapshot to get fresh refs/)
    end

    it "does not retry a stale ref error" do
      call_count = 0
      allow(manager).to receive(:mcp_call) do |tool_name, _args|
        if tool_name == "click"
          call_count += 1
          raise "Element with uid e9 no longer exists on the page."
        end
        { "structuredContent" => { "pages" => [] } }
      end

      expect { tool.send(:mcp_call, "click", { uid: "e9" }) }
        .to raise_error(RuntimeError, /fresh refs/)
      expect(call_count).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # act: includeSnapshot passthrough
  # ---------------------------------------------------------------------------
  describe "#do_user_act includeSnapshot passthrough" do
    let(:manager) { instance_double(Clacky::BrowserManager) }
    let(:calls)   { [] }

    let(:snapshot_payload) do
      {
        "structuredContent" => {
          "message"  => "Successfully clicked on the element",
          "snapshot" => {
            "role" => "document", "id" => "e0",
            "children" => [
              { "role" => "button", "name" => "Submit", "id" => "e4" }
            ]
          }
        }
      }
    end

    before do
      allow(Clacky::BrowserManager).to receive(:instance).and_return(manager)
      allow(manager).to receive(:mcp_call) do |tool_name, args|
        calls << [tool_name, args]
        tool_name == "list_pages" ? { "structuredContent" => { "pages" => [] } } : snapshot_payload
      end
    end

    it "requests a snapshot by default on click" do
      tool.send(:do_user_act, { kind: "click", ref: "e4" })
      expect(calls).to include(["click", hash_including(includeSnapshot: true)])
    end

    it "renders the returned snapshot into the output" do
      result = tool.send(:do_user_act, { kind: "click", ref: "e4" })
      expect(result[:snapshot_included]).to be true
      expect(result[:output]).to include("Page snapshot after click")
      expect(result[:output]).to include('button "Submit" [ref=e4]')
    end

    it "omits includeSnapshot when include_snapshot is false" do
      result = tool.send(:do_user_act, { kind: "click", ref: "e4", include_snapshot: false })
      expect(calls).to include(["click", hash_excluding(includeSnapshot: true)])
      expect(result[:snapshot_included]).to be false
      expect(result[:output]).not_to include("Page snapshot")
    end

    it "accepts include_snapshot as the string 'false'" do
      tool.send(:do_user_act, { kind: "click", ref: "e4", "include_snapshot" => "false" })
      expect(calls).to include(["click", hash_excluding(includeSnapshot: true)])
    end

    it "passes includeSnapshot on fill" do
      tool.send(:do_user_act, { kind: "fill", ref: "e3", text: "a@b.c" })
      expect(calls).to include(["fill", hash_including(includeSnapshot: true, value: "a@b.c")])
    end

    it "fills then presses submit_key, attaching the snapshot to the key press" do
      tool.send(:do_user_act, { kind: "fill", ref: "e3", text: "hi", submit_key: "Enter" })
      fill_args  = calls.find { |c| c[0] == "fill" }[1]
      press_args = calls.find { |c| c[0] == "press_key" }[1]
      expect(fill_args).not_to include(:includeSnapshot)
      expect(press_args).to include(key: "Enter", includeSnapshot: true)
    end

    it "falls back to a generic message when the response has none" do
      allow(manager).to receive(:mcp_call).and_return({})
      result = tool.send(:do_user_act, { kind: "hover", ref: "e1" })
      expect(result[:output]).to eq("hover completed.")
      expect(result[:snapshot_included]).to be false
    end

    it "strips the MCP-rendered snapshot block from text-only responses" do
      text_result = {
        "content" => [
          { "type" => "text", "text" => "Clicked.\n## Latest page snapshot\n- button \"x\"" }
        ]
      }
      allow(manager).to receive(:mcp_call).and_return(text_result)
      result = tool.send(:do_user_act, { kind: "click", ref: "e4" })
      expect(result[:output]).to include("Clicked.")
      expect(result[:output]).not_to include("Latest page snapshot")
    end
  end

  # ---------------------------------------------------------------------------
  # act: fill_form
  # ---------------------------------------------------------------------------
  describe "#do_user_act fill_form" do
    let(:manager) { instance_double(Clacky::BrowserManager) }
    let(:calls)   { [] }

    before do
      allow(Clacky::BrowserManager).to receive(:instance).and_return(manager)
      allow(manager).to receive(:mcp_call) do |tool_name, args|
        calls << [tool_name, args]
        tool_name == "list_pages" ? { "structuredContent" => { "pages" => [] } } : {}
      end
    end

    it "maps ref to the uid key the MCP server expects" do
      tool.send(:do_user_act, {
        kind: "fill_form",
        elements: [{ "ref" => "e1", "value" => "alice" }, { "ref" => "e2", "value" => "secret" }]
      })
      args = calls.find { |c| c[0] == "fill_form" }[1]
      expect(args[:elements]).to eq([
        { uid: "e1", value: "alice" },
        { uid: "e2", value: "secret" }
      ])
      expect(args[:includeSnapshot]).to be true
    end

    it "errors when elements is missing" do
      result = tool.send(:do_user_act, { kind: "fill_form" })
      expect(result[:error]).to match(/non-empty `elements`/)
    end

    it "errors when no entry carries a ref" do
      result = tool.send(:do_user_act, { kind: "fill_form", elements: [{ "value" => "x" }] })
      expect(result[:error]).to match(/must each have a `ref`/)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------
  describe "tool metadata" do
    it "has correct tool_name" do
      expect(described_class.tool_name).to eq("browser")
    end

    it "has required action parameter" do
      required = described_class.tool_parameters[:required]
      expect(required).to include("action")
    end

    it "does not expose a profile parameter (always uses the user's real browser)" do
      expect(described_class.tool_parameters.dig(:properties, :profile)).to be_nil
    end

    it "exposes snapshot query and offset params" do
      props = described_class.tool_parameters[:properties]
      expect(props[:query]).to be_a(Hash)
      expect(props[:offset]).to be_a(Hash)
    end

    it "documents evaluate as a JS expression in tool_description" do
      expect(described_class.tool_description).to include("JS expression")
    end

    it "exposes fill_form as an act kind" do
      kinds = described_class.tool_parameters.dig(:properties, :kind, :enum)
      expect(kinds).to include("fill_form")
    end

    it "exposes include_snapshot, submit_key and elements params" do
      props = described_class.tool_parameters[:properties]
      expect(props[:include_snapshot]).to be_a(Hash)
      expect(props[:submit_key]).to be_a(Hash)
      expect(props[:elements]).to be_a(Hash)
    end

    it "tells the AI not to snapshot right after an act" do
      expect(described_class.tool_description).to include("do NOT follow an act with a snapshot")
    end
  end

end
