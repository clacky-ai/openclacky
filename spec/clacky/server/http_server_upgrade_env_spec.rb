# frozen_string_literal: true

require "spec_helper"
require "clacky/server/http_server"
require "clacky/agent_config"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_upgrade_env_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      {
        "model"            => "test-model",
        "api_key"          => "sk-testkey1234567890abcd",
        "base_url"         => "https://api.example.com",
        "anthropic_format" => true,
        "type"             => "default"
      }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#gem_install_env" do
    it "derives GEM_HOME from the running gem path (Homebrew Ruby)" do
      with_server(agent_config: agent_config) do |server|
        spec = double("spec", base_dir: "/opt/homebrew/lib/ruby/gems/3.4.0")
        allow(Gem).to receive(:loaded_specs).and_return("openclacky" => spec)

        env = server.send(:gem_install_env)

        expect(env["GEM_HOME"]).to eq("/opt/homebrew/lib/ruby/gems/3.4.0")
      end
    end

    it "derives GEM_HOME from the user gem dir (system Ruby 2.6)" do
      with_server(agent_config: agent_config) do |server|
        spec = double("spec", base_dir: "/Users/alice/.gem/ruby/2.6.0")
        allow(Gem).to receive(:loaded_specs).and_return("openclacky" => spec)

        env = server.send(:gem_install_env)

        expect(env["GEM_HOME"]).to eq("/Users/alice/.gem/ruby/2.6.0")
      end
    end

    it "falls back to Gem.dir when the spec is missing" do
      with_server(agent_config: agent_config) do |server|
        allow(Gem).to receive(:loaded_specs).and_return({})
        allow(Gem).to receive(:dir).and_return("/fallback/gem/dir")

        env = server.send(:gem_install_env)

        expect(env["GEM_HOME"]).to eq("/fallback/gem/dir")
      end
    end
  end

  describe "#upgrade_via_gem_update" do
    it "passes gem_install_env to run_shell" do
      with_server(agent_config: agent_config) do |server|
        env = { "GEM_HOME" => "/real/gem/home", "GEM_PATH" => "/a:/b" }
        allow(server).to receive(:gem_install_env).and_return(env)
        allow(server).to receive(:broadcast_all)
        allow(server).to receive(:finish_upgrade)

        expect(server).to receive(:run_shell)
          .with("gem update openclacky --no-document", timeout: 600, env: env)
          .and_return(["ok", 0])

        server.send(:upgrade_via_gem_update)
      end
    end
  end

  describe "#upgrade_via_oss_cdn" do
    it "passes gem_install_env to the install step (not the curl download)" do
      with_server(agent_config: agent_config) do |server|
        env = { "GEM_HOME" => "/real/gem/home", "GEM_PATH" => "/a:/b" }
        allow(server).to receive(:fetch_oss_latest_version).and_return("9.9.9")
        allow(server).to receive(:version_older?).and_return(true)
        allow(server).to receive(:gem_install_env).and_return(env)
        allow(server).to receive(:broadcast_all)
        allow(server).to receive(:finish_upgrade)

        expect(server).to receive(:run_shell)
          .with(a_string_including("curl"), timeout: 300)
          .and_return(["", 0])
          .ordered
        expect(server).to receive(:run_shell)
          .with(a_string_including("gem install"), timeout: 600, env: env)
          .and_return(["ok", 0])
          .ordered

        server.send(:upgrade_via_oss_cdn)
      end
    end
  end
end
