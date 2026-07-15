# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require "clacky/utils/environment_detector"

require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "POST /api/file-action" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_file_action_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:target_file) { File.join(tmpdir, "test_presentation.pptx") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  before { File.write(target_file, "deck") }
  after { FileUtils.rm_rf(tmpdir) }

  def file_action(server, path:, action: "open")
    req = fake_req(method: "POST", path: "/api/file-action", body: { path: path, action: action })
    res = fake_res
    dispatch(server, req, res)
    res
  end

  it "opens a Windows drive-letter path on WSL (does not corrupt it via expand_path)" do
    allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:wsl)
    # Remap the drive-letter path onto the real tmp file so File.exist? passes.
    allow(Clacky::Utils::EnvironmentDetector)
      .to receive(:win_to_linux_path)
      .and_wrap_original { |orig, arg| arg.match?(%r{\A[A-Za-z]:[/\\]}) ? target_file : orig.call(arg) }
    captured = nil
    allow(Clacky::Utils::EnvironmentDetector).to receive(:open_file) { |p| captured = p; true }

    with_server(agent_config: agent_config) do |server|
      res = file_action(server, path: "C:/Users/liuzh/Desktop/test_presentation.pptx")
      expect(res.status).to eq(200)
      expect(captured).to eq(target_file)
    end
  end

  it "still opens a WSL mount path (/mnt/c/...) — regression guard" do
    allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:wsl)
    captured = nil
    allow(Clacky::Utils::EnvironmentDetector).to receive(:open_file) { |p| captured = p; true }

    with_server(agent_config: agent_config) do |server|
      res = file_action(server, path: target_file)
      expect(res.status).to eq(200)
      expect(captured).to eq(target_file)
    end
  end

  it "expands ~ for a home-relative path" do
    allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:linux)
    captured = nil
    allow(Clacky::Utils::EnvironmentDetector).to receive(:open_file) { |p| captured = p; true }
    allow(File).to receive(:expand_path).and_wrap_original do |orig, arg, *rest|
      arg == "~/deck.pptx" ? target_file : orig.call(arg, *rest)
    end

    with_server(agent_config: agent_config) do |server|
      res = file_action(server, path: "~/deck.pptx")
      expect(res.status).to eq(200)
      expect(captured).to eq(target_file)
    end
  end

  it "returns 404 when the file does not exist" do
    allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:linux)

    with_server(agent_config: agent_config) do |server|
      res = file_action(server, path: File.join(tmpdir, "missing.pptx"))
      expect(res.status).to eq(404)
    end
  end
end
