# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent, "#partition_files" do
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

  def partition(files)
    agent.send(:partition_files, files)
  end

  it "routes vision-supported images to the vision pipeline" do
    png = { name: "a.png", mime_type: "image/png", path: "/tmp/a.png" }
    images, others = partition([png])
    expect(images).to eq([png])
    expect(others).to be_empty
  end

  it "keeps data_url images on the vision pipeline regardless of mime" do
    pasted = { "name" => "p.png", "data_url" => "data:image/png;base64,AA==" }
    images, = partition([pasted])
    expect(images).to eq([pasted])
  end

  it "routes image formats vision APIs reject to disk files" do
    svg = { name: "logo.svg", mime_type: "image/svg+xml", path: "/tmp/logo.svg" }
    bmp = { name: "scan.bmp", mime_type: "image/bmp", path: "/tmp/scan.bmp" }
    images, others = partition([svg, bmp])
    expect(images).to be_empty
    expect(others).to eq([svg, bmp])
  end
end
