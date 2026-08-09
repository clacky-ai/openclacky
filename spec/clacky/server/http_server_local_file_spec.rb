# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"

require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "GET /api/local-file" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_local_file_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }

  let(:agent_config) do
    cfg = Clacky::AgentConfig.new(models: [
      { "model" => "test-model", "api_key" => "k",
        "base_url" => "https://example.invalid/v1", "type" => "default" }
    ])
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  after { FileUtils.rm_rf(tmpdir) }

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

  def request_file(server, path_str)
    req = fake_req(
      method:       "GET",
      path:         "/api/local-file",
      query_string: "path=#{CGI.escape(path_str)}",
      headers:      {}
    )
    res = capturing_res
    dispatch(server, req, res)
    res
  end

  describe "Markdown files" do
    it "returns 200 with text/html content-type" do
      md = File.join(tmpdir, "report.md")
      File.write(md, "# Hello")

      with_server(agent_config: agent_config) do |server|
        res = request_file(server, md)
        expect(res.status).to eq(200)
        expect(res["Content-Type"]).to start_with("text/html")
      end
    end

    it "returns an HTML page containing the marked.js render call" do
      md = File.join(tmpdir, "report.md")
      File.write(md, "# Title\n\n- item")

      with_server(agent_config: agent_config) do |server|
        res = request_file(server, md)
        expect(res.body).to include("marked.parse")
        expect(res.body).to include("# Title")
      end
    end

    it "safely JSON-encodes content to prevent XSS" do
      md = File.join(tmpdir, "xss.md")
      File.write(md, '<script>alert("xss")</script>')

      with_server(agent_config: agent_config) do |server|
        res = request_file(server, md)
        # Raw <script> tag must not appear unescaped in the HTML body
        expect(res.body).not_to include("<script>alert")
        # JSON-encoded form should be present
        expect(res.body).to include("\\u003cscript\\u003e")
      end
    end
  end

  describe "plain-text files" do
    it "returns 200 with text/plain for .txt files" do
      txt = File.join(tmpdir, "notes.txt")
      File.write(txt, "just text")

      with_server(agent_config: agent_config) do |server|
        res = request_file(server, txt)
        expect(res.status).to eq(200)
        expect(res["Content-Type"]).to start_with("text/plain")
        expect(res.body).to eq("just text")
      end
    end

    it "returns 200 with text/plain for .json files" do
      json = File.join(tmpdir, "data.json")
      File.write(json, '{"key":"value"}')

      with_server(agent_config: agent_config) do |server|
        res = request_file(server, json)
        expect(res.status).to eq(200)
        expect(res["Content-Type"]).to start_with("text/plain")
      end
    end
  end

  describe "error handling" do
    it "returns 400 when path is missing" do
      with_server(agent_config: agent_config) do |server|
        req = fake_req(method: "GET", path: "/api/local-file", query_string: "", headers: {})
        res = capturing_res
        dispatch(server, req, res)
        expect(res.status).to eq(400)
      end
    end

    it "returns 403 for unsupported extensions" do
      pdf = File.join(tmpdir, "doc.pdf")
      File.binwrite(pdf, "%PDF")

      with_server(agent_config: agent_config) do |server|
        res = request_file(server, pdf)
        expect(res.status).to eq(403)
      end
    end

    it "returns 404 when the file does not exist" do
      with_server(agent_config: agent_config) do |server|
        res = request_file(server, File.join(tmpdir, "missing.md"))
        expect(res.status).to eq(404)
      end
    end
  end
end
