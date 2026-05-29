# frozen_string_literal: true

# Regression tests for the "retrying progress stays on screen forever" bug.
#
# Repro in the wild: a user sees
#
#     Network failed: Net::OpenTimeout (1/10) [1/10]… (681s) (Ctrl+C to interrupt)
#
# long after the task has completed. The seconds counter keeps ticking,
# even though the agent is idle.
#
# Root cause: LlmCaller's transient-failure paths call
#
#     @ui.show_progress(..., progress_type: "retrying", phase: "active", ...)
#
# which, through UIController's legacy shim, allocates a *separate*
# :quiet ProgressHandle under the "retrying" slot. Once the retry
# eventually succeeds, nothing calls
#
#     show_progress(progress_type: "retrying", phase: "done")
#
# so the handle is never finished. Its ticker thread keeps running, its
# OutputBuffer entry stays live, and the user sees the stale seconds
# counter. A grep across the repo confirms there is no such "done" call
# anywhere — the slot is pure-fire-and-forget.
#
# These specs pin down the contract: whenever LlmCaller has opened a
# "retrying" progress slot during a call_llm invocation, that slot MUST
# be closed before the call returns (success) or propagates
# (unrecoverable failure). The agent-level ensure block is also expected
# to clean up any stray "retrying" slot as a defense-in-depth safety
# net, in case a future code path forgets.

RSpec.describe "retrying-progress cleanup on successful retry" do
  # Spy UI that records every show_progress call. Implements just enough
  # of UIInterface for Agent#run / Agent#think / LlmCaller to succeed.
  class ProgressSpyUI
    include Clacky::UIInterface

    attr_reader :progress_events

    def initialize
      @progress_events = []
    end

    def show_progress(message = nil, prefix_newline: true,
                      progress_type: "thinking", phase: "active", metadata: {})
      @progress_events << {
        message: message,
        progress_type: progress_type.to_s,
        phase: phase.to_s,
        metadata: metadata
      }
    end

    # Answer "yes" to every confirmation (we're in auto-approve tests anyway).
    def confirm_action(*); true; end
    def ask(*);           "";   end

    # Swallow all other output — we only care about progress events here.
    def method_missing(_name, *_args, **_kwargs, &_blk); end
    def respond_to_missing?(_name, _priv = false); true; end
  end

  let(:ui) { ProgressSpyUI.new }

  let(:config) do
    Clacky::AgentConfig.new(
      models: [
        {
          "type"             => "default",
          "model"            => "abs-claude-sonnet-4-6",
          "api_key"          => "absk-test",
          "base_url"         => "https://api.openclacky.com/v1",
          "anthropic_format" => true
        }
      ],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "absk-test")
      allow(c).to receive(:bedrock?).and_return(false)
      allow(c).to receive(:anthropic_format?).and_return(true)
      allow(c).to receive(:supports_prompt_caching?).and_return(false)
      allow(c).to receive(:format_tool_results).and_return([])
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

  before do
    # No real sleeping — retry loop runs instantly.
    allow_any_instance_of(Clacky::Agent).to receive(:sleep)
  end

  def active_retrying_events
    ui.progress_events.select do |e|
      e[:progress_type] == "retrying" && e[:phase] == "active"
    end
  end

  def done_retrying_events
    ui.progress_events.select do |e|
      e[:progress_type] == "retrying" && e[:phase] == "done"
    end
  end

  describe "after a transient Faraday::ConnectionFailed that succeeds on retry" do
    it "emits a matching retrying/done event so the UI stops the spinner" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          raise Faraday::ConnectionFailed, "Net::OpenTimeout"
        else
          mock_api_response(content: "ok")
        end
      end

      result = agent.run("hi")
      expect(result[:status]).to eq(:success)

      # We must have seen at least one active retrying event…
      expect(active_retrying_events).not_to be_empty,
        "expected a 'retrying' active event on the first connection failure"

      # …and at least one matching done event to close the slot.
      expect(done_retrying_events).not_to be_empty,
        "BUG: the retrying progress slot was opened (seen #{active_retrying_events.size} " \
        "active events) but NEVER closed with phase: 'done'. " \
        "The spinner will keep ticking forever after the task completes. " \
        "All progress events (in order):\n" +
        ui.progress_events.each_with_index
          .map { |e, i| "  [#{i}] #{e.inspect}" }
          .join("\n")
    end
  end

  describe "after a Faraday::TimeoutError that succeeds on retry" do
    it "emits a matching retrying/done event so the UI stops the spinner" do
      call_count = 0
      allow(client).to receive(:send_messages_with_tools) do |_msgs, **_opts|
        call_count += 1
        if call_count == 1
          raise Faraday::TimeoutError, "read timeout"
        else
          mock_api_response(content: "ok")
        end
      end

      result = agent.run("big task")
      expect(result[:status]).to eq(:success)

      expect(active_retrying_events).not_to be_empty
      expect(done_retrying_events).not_to be_empty,
        "BUG: timeout retry opened a 'retrying' slot that was never closed. " \
        "Events:\n" +
        ui.progress_events.each_with_index
          .map { |e, i| "  [#{i}] #{e.inspect}" }
          .join("\n")
    end
  end
end
