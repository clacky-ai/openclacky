# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Agent, "extension tools" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end
  let(:config) do
    c = Clacky::AgentConfig.new(permission_mode: :auto_approve)
    c.add_model(
      model: "claude-sonnet-4.5",
      api_key: "test-api-key",
      base_url: "https://api.anthropic.com"
    )
    c
  end

  def build_agent
    described_class.new(client, config, working_dir: Dir.pwd, ui: nil, profile: "coding",
                       session_id: Clacky::SessionManager.generate_id, source: :manual)
  end

  # The agent reads result.agents (AgentProfile lookup) at init, so the stub
  # result always carries the `coding` agent unit — its `dir` becomes the
  # container dir, and its `tools:` declaration drives injection.
  def stub_extension_result(dir:, agent_tools: [])
    prompt_file = File.join(dir, "coding.md")
    File.write(prompt_file, "hi")
    agent_unit = Clacky::ExtensionLoader::Unit.new(
      kind: :agent, id: "coding", ext_id: "demo", layer: :local,
      origin: "self", dir: dir,
      spec: { "prompt" => "coding.md", "prompt_abs" => prompt_file, "tools" => agent_tools }
    )
    result = Clacky::ExtensionLoader::Result.new(
      panels: [], api: [], skills: [], agents: [agent_unit], channels: [],
      patches: [], hooks: [], tools: [], errors: [], overridden: [], containers: {}
    )
    allow(Clacky::ExtensionLoader).to receive(:last_result).and_return(result)
  end

  def write_tool(dir, file_name:, class_name:, tool_name:)
    path = File.join(dir, "tools", file_name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      module Clacky
        module Tools
          class #{class_name} < Base
            self.tool_name = "#{tool_name}"
            self.tool_description = "Test tool"
            self.tool_parameters = {
              type: "object",
              properties: { city: { type: "string" } },
              required: %w[city]
            }
            def execute(city:, **)
              { temperature: 22, city: city }
            end
          end
        end
      end
    RUBY
    path
  end

  # ExtensionLoader.last_result is process-global; ensure the real method is
  # restored even if an example fails mid-stub.
  after do
    allow(Clacky::ExtensionLoader).to receive(:last_result).and_call_original
  end

  it "injects a tool the agent declares via `tools:`" do
    Dir.mktmpdir do |dir|
      write_tool(dir, file_name: "weather.rb", class_name: "Weather", tool_name: "weather")
      stub_extension_result(dir: dir, agent_tools: ["weather"])
      agent = build_agent

      registry = agent.instance_variable_get(:@tool_registry)
      tool = registry.all.find { |t| t.name == "weather" }
      expect(tool).not_to be_nil
      expect(tool.execute(city: "Beijing")).to eq({ temperature: 22, city: "Beijing" })
      expect(registry.all_definitions.map { |d| d.dig(:function, :name) }).to include("weather")
    end
  end

  it "does not inject a tool the agent never declared" do
    Dir.mktmpdir do |dir|
      write_tool(dir, file_name: "weather.rb", class_name: "Weather", tool_name: "weather")
      stub_extension_result(dir: dir, agent_tools: [])
      agent = build_agent

      registry = agent.instance_variable_get(:@tool_registry)
      expect(registry.tool_names).not_to include("weather")
    end
  end

  it "skips a tool whose class name does not match its file name" do
    Dir.mktmpdir do |dir|
      write_tool(dir, file_name: "weather.rb", class_name: "WeatherWrong", tool_name: "weather_wrong")
      stub_extension_result(dir: dir, agent_tools: ["weather"])
      agent = build_agent

      registry = agent.instance_variable_get(:@tool_registry)
      expect(registry.tool_names).not_to include("weather_wrong")
    end
  end

  it "skips a broken tool file without blocking agent startup" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tools"))
      File.write(File.join(dir, "tools", "broken.rb"), "def this is not valid ruby")
      stub_extension_result(dir: dir, agent_tools: ["broken"])
      agent = build_agent

      registry = agent.instance_variable_get(:@tool_registry)
      expect(registry.tool_names).not_to include("broken")
      expect(registry.tool_names).to include("terminal")
    end
  end

  # Extension tools reach the host agent's public API (fan_out_labeled,
  # fork_subagent, skill_loader) through this handle; without it a tool that
  # wants to orchestrate subagents has no way in.
  it "hands the host agent to the tool at registration" do
    Dir.mktmpdir do |dir|
      write_tool(dir, file_name: "weather.rb", class_name: "Weather", tool_name: "weather")
      stub_extension_result(dir: dir, agent_tools: ["weather"])
      agent = build_agent

      tool = agent.instance_variable_get(:@tool_registry).all.find { |t| t.name == "weather" }
      expect(tool.agent).to be(agent)
      expect(tool.agent).to respond_to(:fan_out_labeled)
    end
  end
end
