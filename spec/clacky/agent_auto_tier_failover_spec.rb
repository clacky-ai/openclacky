# frozen_string_literal: true

require "spec_helper"

# Tier-attribution for auto routing: when a call routed to the upgrade tier
# fails, the retry must report agent_upgrade_fails so the gateway falls back
# to the floor — task keeps running instead of burning the whole retry
# budget on a dead upgrade lane. Floor failures keep feeding the existing
# agent_upstream_fails signal; failures without a tier (network layer) are
# not attributed to either lane.
RSpec.describe Clacky::Agent, "auto tier failover" do
  let(:config) do
    Clacky::AgentConfig.new(
      models: [
        {
          "type"             => "default",
          "model"            => "auto",
          "api_key"          => "clacky-test-key",
          "base_url"         => "https://api.openclacky.com/v1",
          "anthropic_format" => false
        }
      ],
      permission_mode: :auto_approve
    )
  end

  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "clacky-test-key")
      allow(c).to receive(:bedrock?).and_return(false)
      allow(c).to receive(:anthropic_format?).and_return(false)
      allow(c).to receive(:supports_prompt_caching?).and_return(false)
      allow(c).to receive(:format_tool_results).and_return([])
    end
  end

  let(:agent) do
    described_class.new(
      client, config,
      working_dir: Dir.pwd,
      ui: nil,
      profile: "coding",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )
  end

  before do
    allow_any_instance_of(described_class).to receive(:sleep)
    allow(Clacky::Shutdown).to receive(:sleep_interruptibly).and_return(false)
    Thread.current[:lang] = "en"
  end

  def tier_error(tier)
    Clacky::RetryableError.new("[LLM] Service Unavailable (503)", routed_tier: tier)
  end

  it "upgrade-tier failure is retried with agent_upgrade_fails reported" do
    sent = []
    call_count = 0
    allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **opts|
      call_count += 1
      sent << opts
      call_count == 1 ? raise(tier_error("upgrade")) : mock_api_response
    end

    agent.send(:call_llm)
    expect(call_count).to eq(2)
    expect(sent[1][:agent_upgrade_fails]).to eq(1)
    expect(agent.instance_variable_get(:@task_upgrade_fails)).to eq(1)
    expect(agent.instance_variable_get(:@task_upstream_fails).to_i).to eq(0)
  end

  it "upgrade-fails tally persists into the next call in the same task" do
    sent = []
    call_count = 0
    allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **opts|
      call_count += 1
      sent << opts
      call_count == 1 ? raise(tier_error("upgrade")) : mock_api_response
    end

    agent.send(:call_llm)
    tally = agent.instance_variable_get(:@task_upgrade_fails)
    agent.send(:call_llm, agent_upgrade_fails: tally)
    expect(sent.last[:agent_upgrade_fails]).to eq(1)
  end

  it "floor-tier failure keeps feeding agent_upstream_fails only" do
    sent = []
    call_count = 0
    allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **opts|
      call_count += 1
      sent << opts
      call_count == 1 ? raise(tier_error("floor")) : mock_api_response
    end

    agent.send(:call_llm)
    expect(sent[1][:agent_upstream_fails]).to eq(1)
    expect(sent[1][:agent_upgrade_fails].to_i).to eq(0)
    expect(agent.instance_variable_get(:@task_upstream_fails)).to eq(1)
    expect(agent.instance_variable_get(:@task_upgrade_fails).to_i).to eq(0)
  end

  it "unattributed failure charges neither lane" do
    sent = []
    call_count = 0
    allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **opts|
      call_count += 1
      sent << opts
      call_count == 1 ? raise(Clacky::RetryableError.new("Network failed")) : mock_api_response
    end

    agent.send(:call_llm)
    expect(sent[1][:agent_upstream_fails].to_i).to eq(0)
    expect(sent[1][:agent_upgrade_fails].to_i).to eq(0)
    expect(agent.instance_variable_get(:@task_upstream_fails).to_i).to eq(0)
    expect(agent.instance_variable_get(:@task_upgrade_fails).to_i).to eq(0)
  end

  it "task boundary resets the upgrade-fails tally" do
    sent = []
    call_count = 0
    allow(client).to receive(:send_messages_with_tools) do |_msgs, model:, **opts|
      call_count += 1
      sent << opts
      call_count == 1 ? raise(tier_error("upgrade")) : mock_api_response
    end

    agent.send(:call_llm)
    agent.instance_variable_set(:@task_upgrade_fails, 0)
    agent.send(:call_llm, agent_upgrade_fails: 0)
    expect(sent.last[:agent_upgrade_fails].to_i).to eq(0)
  end

  it "RetryableError defaults routed_tier to nil for message-only raises" do
    err = Clacky::RetryableError.new("boom")
    expect(err.routed_tier).to be_nil
    expect(err.message).to eq("boom")
  end
end
