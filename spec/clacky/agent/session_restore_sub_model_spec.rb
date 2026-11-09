# frozen_string_literal: true

RSpec.describe "Agent#restore_session sub-model pin" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end

  let(:config) do
    Clacky::AgentConfig.new(
      permission_mode: :auto_approve,
      models: [
        { "type" => "default", "model" => "glm-5.3", "base_url" => "https://ark.example.com", "api_key" => "ark-key" },
        { "model" => "auto", "base_url" => "https://api.openclacky.com", "api_key" => "oc-key" }
      ]
    )
  end

  def session_data(model_name:, base_url:, sub_model:)
    {
      session_id: "test-session-sub-model",
      working_dir: Dir.pwd,
      created_at: Time.now.iso8601,
      todos: [],
      messages: [{ role: "system", content: "old system prompt" }],
      stats: { total_tasks: 0, total_iterations: 0, total_cost_usd: 0, last_status: "success" },
      time_machine: { task_parents: {}, current_task_id: 0, active_task_id: 0 },
      config: { model_name: model_name, model_base_url: base_url, sub_model: sub_model }
    }
  end

  def build_agent
    Clacky::Agent.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "general",
                      session_id: Clacky::SessionManager.generate_id, source: :manual)
  end

  it "re-applies the sub-model when the saved card still exists" do
    agent = build_agent
    agent.restore_session(session_data(model_name: "auto", base_url: "https://api.openclacky.com",
                                       sub_model: "abs-claude-opus-5-5"))

    info = agent.current_model_info
    expect(info[:base_url]).to eq("https://api.openclacky.com")
    expect(info[:model]).to eq("abs-claude-opus-5-5")
  end

  it "drops the sub-model when the saved card was deleted" do
    agent = build_agent
    agent.restore_session(session_data(model_name: "removed-card", base_url: "https://api.openclacky.com",
                                       sub_model: "abs-claude-opus-5-5"))

    info = agent.current_model_info
    expect(info[:base_url]).to eq("https://ark.example.com")
    expect(info[:model]).to eq("glm-5.3")
    expect(info[:sub_model]).to be_nil
  end

  it "drops the sub-model when the saved card's model name no longer matches" do
    agent = build_agent
    agent.restore_session(session_data(model_name: "auto-old", base_url: "https://api.openclacky.com",
                                       sub_model: "dsk-deepseek-flash"))

    info = agent.current_model_info
    expect(info[:model]).to eq("glm-5.3")
    expect(info[:sub_model]).to be_nil
  end

  it "drops the sub-model when the active card is deleted under a live session" do
    agent = build_agent
    oc_card = config.models.find { |m| m["base_url"] == "https://api.openclacky.com" }
    agent.switch_model_by_id(oc_card["id"])
    agent.set_session_sub_model("abs-claude-fable-5")

    config.models.delete(oc_card)

    info = agent.current_model_info
    expect(info[:base_url]).to eq("https://ark.example.com")
    expect(info[:model]).to eq("glm-5.3")
    expect(info[:sub_model]).to be_nil
    expect(agent.to_session_data[:config][:sub_model]).to be_nil
  end
end
