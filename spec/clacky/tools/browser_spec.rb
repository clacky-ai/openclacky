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
  describe "#find_node_binary" do
    it "returns a string path or nil" do
      result = tool.send(:find_node_binary)
      expect(result).to satisfy { |r| r.nil? || (r.is_a?(String) && !r.empty?) }
    end

    it "returns a path to an executable file when found" do
      result = tool.send(:find_node_binary)
      if result
        expect(File.executable?(result)).to be true
      end
    end
  end

  describe "#node_error" do
    it "returns nil when node is installed and version is sufficient" do
      allow(tool).to receive(:node_major_version).and_return(22)
      expect(tool.send(:node_error)).to be_nil
    end

    it "returns an error hash when node is not installed" do
      allow(tool).to receive(:node_major_version).and_return(nil)
      result = tool.send(:node_error)
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("Node.js")
      expect(result[:error]).to include("nodejs.org")
    end

    it "returns an error hash when node version is too old" do
      allow(tool).to receive(:node_major_version).and_return(18)
      result = tool.send(:node_error)
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("版本过低")
      expect(result[:error]).to include("v18")
    end
  end

  describe "#build_mcp_command" do
    it "returns an array starting with npx" do
      cmd = tool.send(:build_mcp_command)
      expect(cmd).to be_an(Array)
      expect(cmd.first).to eq("npx")
    end

    it "includes --userDataDir when user_data_dir is provided" do
      cmd = tool.send(:build_mcp_command, user_data_dir: "/tmp/profile")
      expect(cmd).to include("--userDataDir", "/tmp/profile")
    end

    it "excludes --userDataDir when user_data_dir is nil" do
      cmd = tool.send(:build_mcp_command)
      expect(cmd).not_to include("--userDataDir")
    end
  end

  describe "#mcp_json_rpc" do
    it "builds a valid JSON-RPC 2.0 message" do
      msg = tool.send(:mcp_json_rpc, "tools/call", { name: "list_pages" }, id: 42)
      parsed = JSON.parse(msg)
      expect(parsed["jsonrpc"]).to eq("2.0")
      expect(parsed["id"]).to eq(42)
      expect(parsed["method"]).to eq("tools/call")
      expect(parsed["params"]["name"]).to eq("list_pages")
    end
  end

  describe "#mcp_read_response" do
    it "reads matching JSON response from a mock IO" do
      json_line = JSON.generate({ "jsonrpc" => "2.0", "id" => 2, "result" => { "ok" => true } })
      io = StringIO.new(json_line + "\n")
      result = tool.send(:mcp_read_response, io, target_id: 2, timeout: 2)
      expect(result).to be_a(Hash)
      expect(result["id"]).to eq(2)
      expect(result["result"]["ok"]).to be true
    end

    it "skips non-matching ids" do
      line1 = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "result" => {} })
      line2 = JSON.generate({ "jsonrpc" => "2.0", "id" => 2, "result" => { "found" => true } })
      io = StringIO.new("#{line1}\n#{line2}\n")
      result = tool.send(:mcp_read_response, io, target_id: 2, timeout: 2)
      expect(result["result"]["found"]).to be true
    end

    it "returns nil when no matching message and IO closes" do
      io = StringIO.new("")
      result = tool.send(:mcp_read_response, io, target_id: 99, timeout: 1)
      expect(result).to be_nil
    end

    it "returns nil on timeout" do
      read_io, write_io = IO.pipe
      write_io.close  # Nothing to read → EOF immediately
      result = tool.send(:mcp_read_response, read_io, target_id: 99, timeout: 1)
      expect(result).to be_nil
      read_io.close
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

    it "supports only the user profile" do
      profile_enum = described_class.tool_parameters.dig(:properties, :profile, :enum)
      expect(profile_enum).to eq(%w[user])
      expect(profile_enum).not_to include("sandbox")
    end
  end

  # ---------------------------------------------------------------------------
  # Daemon process management
  # ---------------------------------------------------------------------------
  describe "persistent MCP daemon" do
    # Helpers to read/write daemon class variables without @@-syntax conflicts
    def set_proc(val)
      Clacky::Tools::Browser.class_variable_set(:@@mcp_process, val)
    end

    def get_proc
      Clacky::Tools::Browser.class_variable_get(:@@mcp_process)
    end

    def set_call_id(val)
      Clacky::Tools::Browser.class_variable_set(:@@mcp_call_id, val)
    end

    def get_call_id
      Clacky::Tools::Browser.class_variable_get(:@@mcp_call_id)
    end

    # Reset daemon state before and after each example to avoid cross-test pollution
    before do
      Clacky::Tools::Browser.stop_mcp_process!
      set_call_id(2)
    end

    after do
      Clacky::Tools::Browser.stop_mcp_process!
    end

    # ------------------------------------------------------------------
    describe ".stop_mcp_process!" do
      it "is a no-op when no daemon is running" do
        expect { Clacky::Tools::Browser.stop_mcp_process! }.not_to raise_error
      end

      it "clears @@mcp_process" do
        set_proc({ stdin: StringIO.new, stdout: StringIO.new, pid: 99_999_999, wait_thr: nil })
        Clacky::Tools::Browser.stop_mcp_process!
        expect(get_proc).to be_nil
      end
    end

    # ------------------------------------------------------------------
    describe "#mcp_process_alive?" do
      it "returns false when @@mcp_process is nil" do
        set_proc(nil)
        expect(tool.send(:mcp_process_alive?)).to be false
      end

      it "returns false and clears state when PID does not exist" do
        set_proc({ stdin: StringIO.new, stdout: StringIO.new, pid: 99_999_999, wait_thr: nil })
        expect(tool.send(:mcp_process_alive?)).to be false
        expect(get_proc).to be_nil
      end

      it "returns true when process is alive and IOs are open" do
        # Mock Process.kill so we can use an arbitrary PID without side effects.
        # kill(0, pid) is used as a liveness probe — returning nil means alive.
        # We also stub kill(TERM, ...) so that stop_mcp_process! in the after-hook
        # does not accidentally signal the current Ruby process.
        allow(Process).to receive(:kill).and_return(nil)
        set_proc({ stdin: StringIO.new, stdout: StringIO.new, pid: 99_888, wait_thr: nil })
        expect(tool.send(:mcp_process_alive?)).to be true
      end
    end

    # ------------------------------------------------------------------
    describe "#kill_mcp_process!" do
      it "clears @@mcp_process" do
        set_proc({ stdin: StringIO.new, stdout: StringIO.new, pid: 99_999_999, wait_thr: nil })
        tool.send(:kill_mcp_process!)
        expect(get_proc).to be_nil
      end

      it "is safe when @@mcp_process is nil" do
        set_proc(nil)
        expect { tool.send(:kill_mcp_process!) }.not_to raise_error
      end
    end

    # ------------------------------------------------------------------
    describe "#ensure_mcp_process!" do
      it "does nothing if the process is already alive" do
        # Stub Process.kill to avoid accidentally signalling the current process
        allow(Process).to receive(:kill).and_return(nil)
        set_proc({ stdin: StringIO.new, stdout: StringIO.new, pid: 99_888, wait_thr: nil })
        expect(Open3).not_to receive(:popen3)
        tool.send(:ensure_mcp_process!)
        expect(get_proc[:pid]).to eq(99_888)
      end

      it "starts a new process and completes the MCP handshake" do
        set_proc(nil)

        init_resp = JSON.generate({
          "jsonrpc" => "2.0", "id" => 1,
          "result"  => { "protocolVersion" => "2024-11-05", "capabilities" => {} }
        })
        fake_stdin  = StringIO.new
        fake_stdout = StringIO.new(init_resp + "\n")
        fake_wait   = double("wait_thr", pid: 12_345)
        fake_stderr = StringIO.new

        allow(Open3).to receive(:popen3).and_return([fake_stdin, fake_stdout, fake_stderr, fake_wait])
        allow(tool).to receive(:build_mcp_command).and_return(["env", "npx"])

        tool.send(:ensure_mcp_process!)

        ps = get_proc
        expect(ps).not_to be_nil
        expect(ps[:pid]).to eq(12_345)
        expect(fake_stdin.string).to include("notifications/initialized")
      end

      it "raises when the initialize handshake times out" do
        set_proc(nil)

        fake_stdin  = StringIO.new
        fake_stderr = StringIO.new
        fake_wait   = double("wait_thr", pid: 12_346)

        allow(Open3).to receive(:popen3).and_return([fake_stdin, StringIO.new, fake_stderr, fake_wait])
        allow(tool).to receive(:build_mcp_command).and_return(["env", "npx"])
        allow(tool).to receive(:mcp_read_response).and_return(nil)

        expect { tool.send(:ensure_mcp_process!) }
          .to raise_error(/initialize handshake timed out/)
      end
    end

    # ------------------------------------------------------------------
    describe "#mcp_call (daemon mode)" do
      # Inject a fake alive daemon with pre-loaded stdout responses.
      # Uses PID 99_888 and stubs Process.kill to avoid signalling the real process.
      def inject_daemon(responses)
        all_output  = responses.map { |r| r + "\n" }.join
        fake_stdin  = StringIO.new
        fake_stdout = StringIO.new(all_output)
        set_proc({ stdin: fake_stdin, stdout: fake_stdout, pid: 99_888, wait_thr: nil })
        allow(Process).to receive(:kill).and_return(nil)
        [fake_stdin, fake_stdout]
      end

      it "reuses the existing daemon and writes a tools/call message" do
        call_id = get_call_id
        tool_resp = JSON.generate({
          "jsonrpc" => "2.0", "id" => call_id,
          "result"  => { "structuredContent" => { "pages" => [] } }
        })
        fake_stdin, = inject_daemon([tool_resp])

        result = tool.send(:mcp_call, "list_pages", {})

        expect(result).to be_a(Hash)
        expect(fake_stdin.string).to include('"tools/call"')
        expect(fake_stdin.string).to include('"list_pages"')
      end

      it "raises on timeout and clears the daemon state" do
        inject_daemon([])  # empty stdout → timeout
        allow(tool).to receive(:mcp_read_response).and_return(nil)

        expect { tool.send(:mcp_call, "list_pages", {}) }.to raise_error(/timed out/)
        expect(get_proc).to be_nil
      end

      it "raises on a JSON-RPC error response" do
        call_id  = get_call_id
        err_resp = JSON.generate({
          "jsonrpc" => "2.0", "id" => call_id,
          "error"   => { "message" => "some rpc error" }
        })
        inject_daemon([err_resp])

        expect { tool.send(:mcp_call, "list_pages", {}) }.to raise_error(/some rpc error/)
      end
    end
  end
end
