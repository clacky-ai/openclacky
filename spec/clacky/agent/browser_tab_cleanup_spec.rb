# frozen_string_literal: true
require "spec_helper"

RSpec.describe Clacky::Agent, "background browser tab cleanup" do
  let(:config) { Clacky::AgentConfig.new(memory_update_enabled: false, skill_evolution: { enabled: false }) }
  let(:client) { Clacky::Client.new("test", base_url: "https://unused.invalid", model: "test") }
  let(:agent) do
    described_class.new(client, config, working_dir: Dir.pwd, ui: double("ui").as_null_object,
                       profile: "coding", session_id: "test-session", source: :web)
  end

  before do
    allow(agent).to receive(:think).and_return(content: "done", tool_calls: [])
    allow(agent).to receive(:run_skill_evolution_hooks)
    allow(agent).to receive(:run_memory_update_subagent)
  end

  it "closes the background tabs it opened when the run ends" do
    expect(Clacky::BrowserManager.instance).to receive(:release).with(agent)

    agent.run("hello")
  end

  it "still cleans up when the run fails" do
    allow(agent).to receive(:think).and_raise(Clacky::AgentInterrupted)
    expect(Clacky::BrowserManager.instance).to receive(:release).with(agent)

    expect { agent.run("hello") }.to raise_error(Clacky::AgentInterrupted)
  end

  it "gives the browser tool its owner so tabs can be attributed" do
    browser = agent.tool_registry.get("browser")

    expect(browser.agent).to be(agent)
  end
end
