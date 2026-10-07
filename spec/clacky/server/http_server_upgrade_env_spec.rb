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

  describe "#upgrade_via_oss_cdn fallback (issue #583)" do
    let(:commands) { [] }

    # Runs the CDN upgrade with stubbed latest.txt and curl results.
    # Returns every shell command the upgrade ran, in order.
    def run_cdn_upgrade(latest, curl_result = ["", 0])
      cfg = agent_config
      with_server(agent_config: cfg) do |server|
        allow(server).to receive_messages(fetch_oss_latest_version: latest, broadcast_all: nil, finish_upgrade: nil)
        allow(server).to receive(:run_shell) do |cmd, **_opts|
          commands << cmd
          cmd.start_with?("curl") ? curl_result : ["ok", 0]
        end
        server.send(:upgrade_via_oss_cdn)
        commands
      end
    end

    it "runs gem update and logs a WARN when latest.txt cannot be fetched" do
      expect(Clacky::Logger).to receive(:warn).with(a_string_including("[Upgrade] OSS CDN latest.txt"))
      expect(run_cdn_upgrade(nil)).to eq(["gem update openclacky --no-document"])
    end

    it "runs gem update instead of gem install and logs a WARN when the .gem download fails" do
      expect(Clacky::Logger).to receive(:warn).with(a_string_including("(exit 28): curl: (28)"))
      expect(run_cdn_upgrade("99.0.0", ["curl: (28) Operation timed out", 28]).drop(1))
        .to eq(["gem update openclacky --no-document"])
    end

    it "bounds the curl download with connect and total timeouts" do
      expect(run_cdn_upgrade("99.0.0").first).to include("--connect-timeout 15", "--max-time 240")
    end
  end
end
