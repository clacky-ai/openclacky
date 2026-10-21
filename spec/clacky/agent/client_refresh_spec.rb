# frozen_string_literal: true

require "spec_helper"

# Sessions share model cards with the server config (AgentConfig#deep_copy),
# so editing a card in Settings must reach the session's Client on its next call.
RSpec.describe Clacky::Agent, "client refresh on model card edit" do
  let(:shared_config) do
    Clacky::AgentConfig.new(
      models: [
        {
          "type"     => "default",
          "model"    => "dsk-deepseek-flash",
          "api_key"  => "clacky-old-key",
          "base_url" => "https://api.openclacky.com",
          "anthropic_format" => false
        }
      ],
      permission_mode: :auto_approve
    )
  end

  let(:config) { shared_config.deep_copy }
  let(:card) { shared_config.models.first }

  let(:agent) do
    described_class.new(
      Clacky::Client.new(config.api_key, **config.client_options.reject { |k, _| k == :api_key }),
      config,
      working_dir: Dir.pwd,
      ui: nil,
      profile: "coding",
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )
  end

  let(:sent_by) { [] }

  before do
    Thread.current[:lang] = "en"
    calls = sent_by
    allow_any_instance_of(Clacky::Client).to receive(:send_messages_with_tools) do |client, *_args, **_opts|
      calls << client
      mock_api_response
    end
  end

  def client_of(agent)
    agent.instance_variable_get(:@client)
  end

  it "routes an old session through Bedrock after the card becomes an abs- model" do
    agent.send(:call_llm)
    expect(sent_by.last.bedrock?).to be false

    card["model"] = "abs-claude-opus-5-5"
    agent.send(:call_llm)

    expect(sent_by.last.bedrock?).to be true
    expect(sent_by.last.instance_variable_get(:@model)).to eq("abs-claude-opus-5-5")
  end

  it "picks up an edited api_key and base_url" do
    agent.send(:call_llm)

    card["api_key"] = "clacky-new-key"
    card["base_url"] = "https://proxy.example.com"
    agent.send(:call_llm)

    expect(sent_by.last.instance_variable_get(:@api_key)).to eq("clacky-new-key")
    expect(sent_by.last.instance_variable_get(:@base_url)).to eq("https://proxy.example.com")
  end

  it "keeps the same client while the card is unchanged" do
    original = client_of(agent)
    agent.send(:call_llm)
    agent.send(:call_llm)

    expect(sent_by).to all(equal(original))
  end

  it "does not inject a session context message when refreshing" do
    agent.history.append({ role: "system", content: "sys" })
    agent.send(:call_llm)
    count = agent.history.to_a.size

    card["model"] = "abs-claude-opus-5-5"
    agent.send(:call_llm)

    expect(agent.history.to_a.size).to eq(count)
  end
end
