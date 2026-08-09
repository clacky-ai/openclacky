# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "../../support/http_server_spec_helpers"

RSpec.describe Clacky::Server::HttpServer, "search routes" do
  include HttpServerSpecHelpers

  let(:agent_config) do
    Clacky::AgentConfig.new(models: [
      { "model" => "m", "api_key" => "k", "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
  end

  before do
    @dir = Dir.mktmpdir("clacky_http_search_spec")
    FileUtils.mkdir_p(File.join(@dir, "searchers"))
    stub_const("Clacky::SearchConfig::CONFIG_PATH", File.join(@dir, "search.yml"))
    stub_const("Clacky::Utils::SearcherManager::SEARCHERS_DIR", File.join(@dir, "searchers"))
  end

  after { FileUtils.rm_rf(@dir) }

  def install_searcher(name, body)
    File.write(File.join(@dir, "searchers", "#{name}.rb"), body)
  end

  def call(method, path, body = nil)
    with_server(agent_config: agent_config) do |server|
      req = fake_req(method: method, path: path, body: body)
      res = fake_res
      dispatch(server, req, res)
      [res.status, parsed_body(res)]
    end
  end

  describe "GET /api/config/search" do
    it "reports an unconfigured provider and lists installed searchers" do
      install_searcher("tavily", "puts '[]'")

      status, body = call("GET", "/api/config/search")

      expect(status).to eq(200)
      expect(body["provider"]).to eq("")
      expect(body["key_masked"]).to be_nil
      expect(body["available"]).to eq(["tavily"])
    end

    it "masks the stored key" do
      install_searcher("tavily", "puts '[]'")
      Clacky::SearchConfig.save(provider: "tavily", key: "tvly-abcdefghijklmnop")

      _status, body = call("GET", "/api/config/search")

      expect(body["provider"]).to eq("tavily")
      expect(body["key_masked"]).to include("****")
      expect(body["key_masked"]).not_to include("abcdefghijklmnop")
    end
  end

  describe "PATCH /api/config/search" do
    it "saves provider and key" do
      install_searcher("tavily", "puts '[]'")

      status, body = call("PATCH", "/api/config/search", { provider: "tavily", key: "k1" })

      expect(status).to eq(200)
      expect(body["ok"]).to be true
      expect(Clacky::SearchConfig.load).to eq("provider" => "tavily", "key" => "k1")
    end

    it "rejects an unknown provider" do
      status, body = call("PATCH", "/api/config/search", { provider: "ghost" })

      expect(status).to eq(422)
      expect(body["error"]).to include("Unknown search provider")
    end

    it "accepts a blank provider to fall back to the built-in engines" do
      install_searcher("tavily", "puts '[]'")
      Clacky::SearchConfig.save(provider: "tavily", key: "k1")

      status, _body = call("PATCH", "/api/config/search", { provider: "" })

      expect(status).to eq(200)
      expect(Clacky::SearchConfig.load["provider"]).to eq("")
    end

    it "keeps the stored key when the masked value is sent back" do
      install_searcher("tavily", "puts '[]'")
      Clacky::SearchConfig.save(provider: "tavily", key: "tvly-original")

      call("PATCH", "/api/config/search", { provider: "tavily", key: "tvly-ori****inal" })

      expect(Clacky::SearchConfig.load["key"]).to eq("tvly-original")
    end
  end

  describe "POST /api/config/search/test" do
    it "reports success with the result count" do
      install_searcher("tavily", <<~RUBY)
        require "json"
        puts JSON.generate([{ "title" => "t", "url" => "https://example.com" }])
      RUBY

      status, body = call("POST", "/api/config/search/test", { provider: "tavily", key: "k1" })

      expect(status).to eq(200)
      expect(body["ok"]).to be true
      expect(body["message"]).to include("1 result")
    end

    it "surfaces the searcher's error message" do
      install_searcher("tavily", "warn 'Tavily API key is not configured'\nexit 1\n")

      _status, body = call("POST", "/api/config/search/test", { provider: "tavily", key: "bad" })

      expect(body["ok"]).to be false
      expect(body["message"]).to include("not configured")
    end

    it "fails when the searcher is not installed" do
      _status, body = call("POST", "/api/config/search/test", { provider: "ghost" })

      expect(body["ok"]).to be false
      expect(body["message"]).to include("not found")
    end

    it "fails when the searcher does not output a JSON array" do
      install_searcher("tavily", "puts 'nope'\n")

      _status, body = call("POST", "/api/config/search/test", { provider: "tavily", key: "k" })

      expect(body["ok"]).to be false
      expect(body["message"]).to include("JSON array")
    end
  end
end
