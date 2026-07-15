# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "#parse_file_links" do
  let(:client) do
    instance_double(Clacky::Client).tap { |c| c.instance_variable_set(:@api_key, "k") }
  end
  let(:config) do
    c = Clacky::AgentConfig.new(permission_mode: :auto_approve)
    c.add_model(model: "claude-sonnet-4.5", api_key: "k", base_url: "https://api.anthropic.com")
    c
  end
  let(:agent) do
    described_class.new(client, config, working_dir: Dir.pwd, ui: nil,
                        profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual)
  end

  def parse(content)
    agent.send(:parse_file_links, content)
  end

  it "extracts an inline image with the resolved path and basename" do
    result = parse("![chart](file:///Users/foo/chart.png)")
    expect(result[:files]).to eq([
      { name: "chart.png", path: "/Users/foo/chart.png", inline: true }
    ])
  end

  it "extracts a non-inline download link" do
    result = parse("[report](file:///Users/foo/report.pdf)")
    expect(result[:files].first).to include(name: "report.pdf", inline: false)
  end

  it "percent-decodes non-ASCII filenames" do
    result = parse("![p](file:///Users/foo/%E4%B8%AD%E6%96%87.png)")
    expect(result[:files].first[:path]).to eq("/Users/foo/中文.png")
    expect(result[:files].first[:name]).to eq("中文.png")
  end

  it "routes the raw path through EnvironmentDetector.resolve_local_path" do
    allow(Clacky::Utils::EnvironmentDetector)
      .to receive(:resolve_local_path).with("/C:/Users/foo/a.png").and_return("/mnt/c/Users/foo/a.png")

    result = parse("![a](file:///C:/Users/foo/a.png)")
    expect(result[:files].first).to include(name: "a.png", path: "/mnt/c/Users/foo/a.png")
  end

  it "returns text unchanged and empty files for content without links" do
    expect(parse("no links here")).to eq(text: "no links here", files: [])
  end
end
