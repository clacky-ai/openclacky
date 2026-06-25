# frozen_string_literal: true

# Regression tests for "Broken pipe" errors after prolonged sessions.
#
# Root cause: after idle time, the server closes the TCP connection.
# The next request raises Errno::EPIPE when writing to the dead socket.
# Two failure modes:
#
#   1. Non-streaming path: Faraday wraps Errno::EPIPE as
#      Faraday::ConnectionFailed. The original rescue list omitted
#      Errno::EPIPE, so this was already caught — but retry reused the
#      same cached Faraday connection object (same dead socket), causing
#      all 10 retries to fail with the same error.
#
#   2. Streaming path (on_data callback): Faraday's net_http adapter
#      wraps NET_HTTP_EXCEPTIONS only inside perform_request > call(),
#      but stream_response? takes a different code path where the
#      exception escapes unwrapped as a raw Errno::EPIPE. The rescue
#      list didn't include the bare Errno::EPIPE class at all.
#
# Fix: add Errno::EPIPE to the rescue clause AND call
# client.reset_connections! so the next retry opens a fresh socket.

RSpec.describe "Broken pipe (Errno::EPIPE) recovery in LlmCaller" do
  class BrokenPipeSpyUI
    include Clacky::UIInterface

    attr_reader :progress_events, :warnings

    def initialize
      @progress_events = []
      @warnings = []
    end

    def show_progress(message = nil, prefix_newline: true,
                      progress_type: "thinking", phase: "active", metadata: {})
      @progress_events << { message: message, progress_type: progress_type.to_s, phase: phase.to_s }
    end

    def show_warning(msg)
      @warnings << msg
    end

    def confirm_action(*); true; end
    def ask(*); ""; end
    def method_missing(_name, *_args, **_kwargs, &_blk); end
    def respond_to_missing?(_name, _priv = false); true; end
  end

  let(:ui) { BrokenPipeSpyUI.new }

  let(:config) do
    Clacky::AgentConfig.new(
      models: [
        {
          "type"        => "default",
          "model"       => "gpt-4o",
          "api_key"     => "sk-test",
          "base_url"    => "https://api.openai.com/v1"
        }
      ],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      allow(c).to receive(:instance_variable_get).with(:@api_key).and_return("sk-test")
      allow(c).to receive(:bedrock?).and_return(false)
      allow(c).to receive(:anthropic_format?).and_return(false)
      allow(c).to receive(:supports_prompt_caching?).and_return(false)
      allow(c).to receive(:format_tool_results).and_return([])
      allow(c).to receive(:reset_connections!)
    end
  end

  let(:agent) do
    Clacky::Agent.new(
      client, config,
      working_dir: Dir.pwd,
      ui: ui,
      profile: "coding",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )
  end

  before { allow_any_instance_of(Clacky::Agent).to receive(:sleep) }
  before { Thread.current[:lang] = "en" }

  # ── Streaming path: bare Errno::EPIPE escapes Faraday unwrapped ──────────

  describe "bare Errno::EPIPE from streaming on_data callback" do
    it "retries and succeeds after the first broken-pipe failure" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do
        call_count += 1
        raise Errno::EPIPE, "Broken pipe" if call_count == 1
        mock_api_response(content: "recovered")
      end

      result = agent.run("hello")
      expect(result[:status]).to eq(:success)
    end

    it "calls reset_connections! to drop the dead socket before retrying" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do
        call_count += 1
        raise Errno::EPIPE, "Broken pipe" if call_count == 1
        mock_api_response(content: "ok")
      end

      agent.run("hello")
      expect(client).to have_received(:reset_connections!).at_least(:once)
    end

    it "raises AgentError after max retries are exhausted" do
      allow(client).to receive(:send_messages_with_tools)
        .and_raise(Errno::EPIPE, "Broken pipe")

      expect { agent.run("hello") }
        .to raise_error(Clacky::AgentError, /Network connection failed after \d+ retries/)
    end
  end

  # ── Non-streaming path: Faraday wraps EPIPE as ConnectionFailed ──────────

  describe "Faraday::ConnectionFailed wrapping Errno::EPIPE" do
    it "retries and succeeds" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do
        call_count += 1
        if call_count == 1
          raise Faraday::ConnectionFailed.new(Errno::EPIPE.new("Broken pipe"))
        end
        mock_api_response(content: "recovered")
      end

      result = agent.run("hello")
      expect(result[:status]).to eq(:success)
    end

    it "calls reset_connections! when the wrapped exception is Errno::EPIPE" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do
        call_count += 1
        if call_count == 1
          raise Faraday::ConnectionFailed.new(Errno::EPIPE.new("Broken pipe"))
        end
        mock_api_response(content: "ok")
      end

      agent.run("hello")
      expect(client).to have_received(:reset_connections!).at_least(:once)
    end

    it "does NOT call reset_connections! for unrelated ConnectionFailed errors" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do
        call_count += 1
        if call_count == 1
          raise Faraday::ConnectionFailed.new(RuntimeError.new("DNS lookup failed"))
        end
        mock_api_response(content: "ok")
      end

      agent.run("hello")
      expect(client).not_to have_received(:reset_connections!)
    end
  end

  # ── Progress slot is always cleaned up ───────────────────────────────────

  describe "retrying progress slot lifecycle" do
    it "closes the retrying slot after successful recovery from EPIPE" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do
        call_count += 1
        raise Errno::EPIPE, "Broken pipe" if call_count == 1
        mock_api_response(content: "ok")
      end

      agent.run("hello")

      active = ui.progress_events.select { |e| e[:progress_type] == "retrying" && e[:phase] == "active" }
      done   = ui.progress_events.select { |e| e[:progress_type] == "retrying" && e[:phase] == "done" }
      expect(active).not_to be_empty
      expect(done).not_to be_empty
    end

    it "closes the retrying slot even when all retries fail" do
      allow(client).to receive(:send_messages_with_tools)
        .and_raise(Errno::EPIPE, "Broken pipe")

      expect { agent.run("hello") }.to raise_error(Clacky::AgentError)

      active = ui.progress_events.select { |e| e[:progress_type] == "retrying" && e[:phase] == "active" }
      done   = ui.progress_events.select { |e| e[:progress_type] == "retrying" && e[:phase] == "done" }
      expect(active).not_to be_empty
      expect(done).not_to be_empty
    end
  end
end
