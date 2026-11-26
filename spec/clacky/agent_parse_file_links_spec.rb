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

  it "keeps a path with spaces whole" do
    result = parse("[with space.pdf](file:///tmp/a/with space.pdf)")
    expect(result[:files]).to eq([
      { name: "with space.pdf", path: "/tmp/a/with space.pdf", inline: false }
    ])
  end

  it "keeps paired parentheses in the path instead of stopping at the first one" do
    result = parse("![图](file:///tmp/a/%E5%A4%87%E4%BB%BD(%E6%97%A7).png)")
    expect(result[:files]).to eq([
      { name: "备份(旧).png", path: "/tmp/a/备份(旧).png", inline: true }
    ])
  end

  it "handles a path with both spaces and parentheses" do
    result = parse("[备份(旧) 副本.pdf](file:///tmp/a/备份(旧) 副本.pdf)")
    expect(result[:files].first[:path]).to eq("/tmp/a/备份(旧) 副本.pdf")
  end

  it "ignores a link whose path has an unbalanced parenthesis" do
    expect(parse("[x](file:///tmp/a/foo(1.pdf)")[:files]).to eq([])
  end

  it "extracts a link wrapped in angle brackets for a path with spaces" do
    result = parse("[with space.pdf](<file:///tmp/a/with space.pdf>)")
    expect(result[:files]).to eq([
      { name: "with space.pdf", path: "/tmp/a/with space.pdf", inline: false }
    ])
  end

  it "extracts an inline image wrapped in angle brackets" do
    result = parse("![备份(旧) 副本.png](<file:///tmp/a/备份(旧) 副本.png>)")
    expect(result[:files]).to eq([
      { name: "备份(旧) 副本.png", path: "/tmp/a/备份(旧) 副本.png", inline: true }
    ])
  end
end

RSpec.describe Clacky::Agent, "#emit_assistant_message file link rewriting" do
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

  it "normalizes file links inside the thinking block too" do
    with_tmp_file("备份(旧).pdf") do |path|
      received = nil
      attached = nil
      ui = double("ui")
      allow(ui).to receive(:show_assistant_message) do |content, files: [], **_kw|
        received = content
        attached = files
      end
      agent.instance_variable_set(:@ui, ui)

      agent.send(:emit_assistant_message, "答案",
                 reasoning_content: "考虑 [f](#{path}) 这个文件")

      expect(received).to start_with("<think>\n考虑 [f](file://#{path}) 这个文件\n</think>\n")
      expect(received).to end_with("答案")
      expect(attached).to be_empty
    end
  end
end
