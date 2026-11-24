# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

# The skills panel launches a session when the user clicks a skill's ✓. A skill
# pinned to one agent (ext-develop → ext-developer) is invisible to any other
# agent's session, so the payload must carry that scope or the launch fails.
RSpec.describe "GET /api/skills payload" do
  let(:tmpdir) { Dir.mktmpdir("clacky_skills_api_spec") }
  let(:res) do
    Struct.new(:status, :content_type, :body) do
      def []=(_key, _value); end
    end.new
  end
  let(:server) do
    Clacky::Server::HttpServer.new(
      agent_config:   Clacky::AgentConfig.new(models: []),
      client_factory: -> { double("client") },
      sessions_dir:   tmpdir
    )
  end

  before { allow(Clacky::BrandConfig).to receive(:load_upload_meta).and_return({}) }
  after  { FileUtils.rm_rf(tmpdir) }

  def skills_by_name
    server.send(:api_list_skills, res)
    JSON.parse(res.body)["skills"].each_with_object({}) { |s, h| h[s["name"]] = s }
  end

  it "exposes the agent scope of an agent-pinned skill" do
    ext = skills_by_name.fetch("ext-develop")

    expect(ext["agents"]).to eq(["ext-developer"])
  end

  it "omits skills the user cannot invoke" do
    expect(skills_by_name).not_to have_key("recall-memory")
  end

  it "defaults unconstrained skills to every agent" do
    expect(skills_by_name.fetch("search-skills")["agents"]).to eq(["all"])
  end
end
