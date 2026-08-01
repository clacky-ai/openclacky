# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"
require "clacky/agent_config"

RSpec.describe Clacky::Server::HttpServer, "extension panel visibility" do
  let(:builtin)   { Dir.mktmpdir }
  let(:installed) { Dir.mktmpdir }
  let(:local)     { Dir.mktmpdir }

  let(:server) do
    described_class.new(
      host:           "127.0.0.1",
      port:           0,
      agent_config:   instance_double(Clacky::AgentConfig),
      client_factory: -> { double("client") },
      sessions_dir:   Dir.mktmpdir
    )
  end

  after do
    [builtin, installed, local].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
    Clacky::ExtensionLoader.instance_variable_set(:@last_result, nil)
    Clacky::ExtensionLoader.instance_variable_set(:@last_fingerprint, nil)
  end

  def make_ext(root, ext_id, manifest, files = {})
    dir = File.join(root, ext_id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "ext.yml"), manifest)
    files.each do |rel, content|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  # Load the test fixture layers and pin the result so that the implementation's
  # internal `ExtensionLoader.load_all` (called without args from panel_agents_map)
  # doesn't blow away our test fixtures by rescanning the real default layers.
  def reload_layers
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: builtin, installed: installed, local: local },
      force: true
    )
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(result)
    result
  end

  def stub_agent_profiles(map)
    allow(server).to receive(:agent_profile_data).and_return(map)
  end

  it "attach: [<agent>] mounts the panel on that agent" do
    manifest = <<~YAML
      id: canvas-pack
      origin: self
      contributes:
        panels:
          - id: canvas
            view: panels/canvas/view.js
            attach: [designer]
    YAML
    make_ext(local, "canvas-pack", manifest, "panels/canvas/view.js" => "")

    reload_layers
    stub_agent_profiles("designer" => {}, "coding" => {})

    expect(server.send(:panel_agents_map)["canvas-pack/canvas"]).to eq(["designer"])
  end

  it 'attach: ["*"] makes the panel visible to every known agent' do
    manifest = <<~YAML
      id: meeting-pack
      origin: self
      contributes:
        panels:
          - id: meeting
            view: panels/meeting/view.js
            attach: ["*"]
    YAML
    make_ext(local, "meeting-pack", manifest, "panels/meeting/view.js" => "")

    reload_layers
    stub_agent_profiles("general" => {}, "coding" => {})

    expect(server.send(:panel_agents_map)["meeting-pack/meeting"]).to contain_exactly("general", "coding")
  end

  it "no attach and no agent reference — panel stays hidden" do
    manifest = <<~YAML
      id: canvas-pack
      origin: self
      contributes:
        panels:
          - id: canvas
            view: panels/canvas/view.js
    YAML
    make_ext(local, "canvas-pack", manifest, "panels/canvas/view.js" => "")

    reload_layers
    stub_agent_profiles("coding" => {})

    expect(server.send(:panel_agents_map)["canvas-pack/canvas"]).to eq([])
  end

  it "agent.panels reference alone mounts the panel (opt-in)" do
    manifest = <<~YAML
      id: canvas-pack
      origin: self
      contributes:
        panels:
          - id: canvas
            view: panels/canvas/view.js
    YAML
    make_ext(local, "canvas-pack", manifest, "panels/canvas/view.js" => "")

    reload_layers
    stub_agent_profiles("designer" => { "panels" => ["canvas-pack/canvas"] })

    expect(server.send(:panel_agents_map)["canvas-pack/canvas"]).to eq(["designer"])
  end

  it "attach + agent reference union without duplicates" do
    manifest = <<~YAML
      id: canvas-pack
      origin: self
      contributes:
        panels:
          - id: canvas
            view: panels/canvas/view.js
            attach: [designer]
    YAML
    make_ext(local, "canvas-pack", manifest, "panels/canvas/view.js" => "")

    reload_layers
    stub_agent_profiles(
      "designer" => { "panels" => ["canvas-pack/canvas"] },
      "coding"   => { "panels" => ["canvas-pack/canvas"] }
    )

    expect(server.send(:panel_agents_map)["canvas-pack/canvas"]).to contain_exactly("designer", "coding")
  end
end
