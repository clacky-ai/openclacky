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

RSpec.describe Clacky::Agent, "#normalize_file_links" do
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

  def normalize(content)
    agent.send(:normalize_file_links, content)
  end

  def with_tmp_file(name)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, "x")
      yield path
    end
  end

  def project_ref(decoded)
    "/workspace/projects/#{Base64.urlsafe_encode64(decoded, padding: false)}"
  end

  it "decodes a hosted-platform project ref back to a file:// link" do
    with_tmp_file("报告.pdf") do |path|
      expect(normalize("[报告](#{project_ref("cch1:file://#{path}")})"))
        .to eq("[报告](file://#{path})")
    end
  end

  it "decodes a project ref wrapped in the local server origin" do
    with_tmp_file("report.pdf") do |path|
      ref = project_ref("cch1:file://#{path}")
      expect(normalize("[report](http://127.0.0.1:7070#{ref})"))
        .to eq("[report](file://#{path})")
    end
  end

  it "prefixes a bare absolute path with file://" do
    with_tmp_file("report.pdf") do |path|
      expect(normalize("[report](#{path})")).to eq("[report](file://#{path})")
    end
  end

  it "leaves an existing file:// link untouched" do
    with_tmp_file("report.pdf") do |path|
      expect(normalize("[report](file://#{path})")).to eq("[report](file://#{path})")
    end
  end

  it "leaves paths that do not exist locally untouched" do
    content = "[x](/tmp/definitely-missing-#{SecureRandom.hex(6)}.pdf)"
    expect(normalize(content)).to eq(content)
  end

  it "does not touch site routes or external links" do
    content = "[api](/api/sessions) [docs](/docs/getting-started) [web](https://example.com/a) [mail](mailto:a@b.c)"
    expect(normalize(content)).to eq(content)
  end

  it "keeps a malformed project ref as-is" do
    content = "[x](/workspace/projects/!!!not-base64)"
    expect(normalize(content)).to eq(content)
  end

  it "normalizes links before the message leaves the agent" do
    with_tmp_file("report.pdf") do |path|
      received = nil
      ui = double("ui")
      allow(ui).to receive(:show_assistant_message) { |content, **_kw| received = content }
      agent.instance_variable_set(:@ui, ui)

      agent.send(:emit_assistant_message, "[report](#{project_ref("cch1:file://#{path}")})")

      expect(received).to eq("[report](file://#{path})")
    end
  end
end
