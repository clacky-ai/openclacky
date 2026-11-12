# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "X-Lang request header" do
  include HttpServerSpecHelpers

  let(:config_dir) { Dir.mktmpdir("clacky_lang_spec_config") }
  let(:config_file) { File.join(config_dir, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  around do |example|
    Dir.mktmpdir("clacky_lang_spec_ext") do |dir|
      @ext_dir = dir
      File.write(File.join(dir, "README.md"), "# English guide")
      File.write(File.join(dir, "README.zh.md"), "# 中文说明")
      example.run
    end
  ensure
    Thread.current[:lang] = nil
    FileUtils.rm_rf(config_dir)
  end

  def readme_with(headers)
    with_server(agent_config: agent_config) do |server|
      allow(server).to receive(:extension_container).with("git")
        .and_return({ ext_id: "git", layer: :builtin, dir: @ext_dir, raw: {} })

      req = fake_req(method: "GET", path: "/api/store/extension", headers: headers)
      allow(req).to receive(:query).and_return({ "id" => "git" })
      res = fake_res
      dispatch(server, req, res)

      JSON.parse(res.body).dig("extension", "readme")
    end
  end

  it "uses the client language even when the process runs in English" do
    allow(Clacky::I18n).to receive(:env_locale).and_return("en")

    expect(readme_with("X-Lang" => "zh-CN")).to eq("# 中文说明")
  end

  it "collapses a regional variant instead of discarding it" do
    allow(Clacky::I18n).to receive(:env_locale).and_return("en")

    expect(readme_with("X-Lang" => "ZH_tw")).to eq("# 中文说明")
  end

  it "ignores an unsupported language and falls back to the process locale" do
    allow(Clacky::I18n).to receive(:env_locale).and_return("en")

    expect(readme_with("X-Lang" => "fr")).to eq("# English guide")
  end

  it "falls back to the process locale when the header is absent" do
    allow(Clacky::I18n).to receive(:env_locale).and_return("en")

    expect(readme_with({})).to eq("# English guide")
  end

  it "falls back to a Chinese process locale when the header is absent" do
    allow(Clacky::I18n).to receive(:env_locale).and_return("zh")

    expect(readme_with({})).to eq("# 中文说明")
  end
end
