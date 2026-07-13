# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "GET /api/local-image caching" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_local_image_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }
  let(:image_path) { File.join(tmpdir, "puppy.png") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmpdir) }

  # A response double that captures headers set via res["Key"] = value.
  def capturing_res
    res = double("res").as_null_object
    headers = {}
    allow(res).to receive(:status=) { |v| res.instance_variable_set(:@status, v) }
    allow(res).to receive(:body=)   { |v| res.instance_variable_set(:@body, v) }
    allow(res).to receive(:[]=)     { |k, v| headers[k] = v }
    allow(res).to receive(:[])      { |k| headers[k] }
    allow(res).to receive(:status)  { res.instance_variable_get(:@status) }
    allow(res).to receive(:body)    { res.instance_variable_get(:@body) }
    res
  end

  def request_image(server, headers: {})
    req = fake_req(
      method:       "GET",
      path:         "/api/local-image",
      query_string: "path=#{CGI.escape(image_path)}",
      headers:      headers
    )
    res = capturing_res
    dispatch(server, req, res)
    res
  end

  before { File.binwrite(image_path, "PNGDATA-v1") }

  it "returns 200 with an ETag and no-cache on first request" do
    with_server(agent_config: agent_config) do |server|
      res = request_image(server)
      expect(res.status).to eq(200)
      expect(res["ETag"]).to be_a(String).and(match(/\A\S+\z/))
      expect(res["Cache-Control"]).to eq("private, no-cache")
      expect(res.body).to eq("PNGDATA-v1")
    end
  end

  it "returns 304 with no body when If-None-Match matches the current ETag" do
    with_server(agent_config: agent_config) do |server|
      etag = request_image(server)["ETag"]
      res = request_image(server, headers: { "If-None-Match" => etag })
      expect(res.status).to eq(304)
      expect(res.body).to eq("")
    end
  end

  it "returns 200 with a new ETag when the same-name file is overwritten" do
    with_server(agent_config: agent_config) do |server|
      old_etag = request_image(server)["ETag"]

      # Overwrite with different content + size; bump mtime to guarantee change
      # even on coarse-grained filesystems.
      File.binwrite(image_path, "PNGDATA-version-2-longer")
      File.utime(Time.now + 2, Time.now + 2, image_path)

      res = request_image(server, headers: { "If-None-Match" => old_etag })
      expect(res.status).to eq(200)
      expect(res["ETag"]).not_to eq(old_etag)
      expect(res.body).to eq("PNGDATA-version-2-longer")
    end
  end
end
