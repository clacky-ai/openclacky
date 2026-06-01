# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/agent_config"
require "clacky/media/generator"

require_relative "http_server_spec"

RSpec.describe Clacky::Server::HttpServer, "media routes" do
  include HttpServerSpecHelpers

  let(:tmpdir) { Dir.mktmpdir("clacky_http_media_spec") }
  let(:config_file) { File.join(tmpdir, "config.yml") }

  after { FileUtils.rm_rf(tmpdir) }

  def build_config(models)
    cfg = Clacky::AgentConfig.new(models: models)
    stub_const("Clacky::AgentConfig::CONFIG_FILE", config_file)
    cfg
  end

  describe "GET /api/media/types" do
    it "reports configured=false for every modality when no media model exists" do
      cfg = build_config([
        { "model" => "some-chat-model", "api_key" => "k",
          "base_url" => "https://example.invalid/v1", "type" => "default" }
      ])
      with_server(agent_config: cfg) do |server|
        req = fake_req(method: "GET", path: "/api/media/types")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(200)
        body = parsed_body(res)
        %w[image video audio].each do |t|
          expect(body[t]).to eq("configured" => false, "source" => "off")
        end
      end
    end

    it "reports the configured image model" do
      cfg = build_config([
        { "model" => "some-chat-model", "api_key" => "k",
          "base_url" => "https://example.invalid/v1", "type" => "default" },
        { "model" => "or-gpt-image-1", "api_key" => "clacky-x",
          "base_url" => "https://api.openclacky.com", "type" => "image" }
      ])
      with_server(agent_config: cfg) do |server|
        req = fake_req(method: "GET", path: "/api/media/types")
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["image"]).to include(
          "configured" => true,
          "model"      => "or-gpt-image-1",
          "base_url"   => "https://api.openclacky.com"
        )
        expect(body["video"]).to eq("configured" => false, "source" => "off")
        expect(body["audio"]).to eq("configured" => false, "source" => "off")
      end
    end
  end

  describe "POST /api/media/image" do
    let(:image_models) do
      [
        { "model" => "abs-claude-sonnet-4-6", "api_key" => "clacky-x",
          "base_url" => "https://api.openclacky.com", "type" => "default" },
        { "model" => "or-gpt-image-1", "api_key" => "clacky-x",
          "base_url" => "https://api.openclacky.com", "type" => "image" }
      ]
    end

    it "rejects an empty prompt with 422" do
      cfg = build_config(image_models)
      with_server(agent_config: cfg) do |server|
        req = fake_req(method: "POST", path: "/api/media/image",
                       body: { "prompt" => "  " })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
        expect(parsed_body(res)).to include("error")
      end
    end

    it "rejects malformed JSON as a missing prompt (422)" do
      cfg = build_config(image_models)
      with_server(agent_config: cfg) do |server|
        req = double("req",
          request_method: "POST",
          path:           "/api/media/image",
          body:           "not json{",
          query_string:   "",
          "[]":           nil
        )
        allow(req).to receive(:instance_variable_get).and_return(nil)
        allow(req).to receive(:[]).and_return(nil)
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
        expect(parsed_body(res)["error"]).to include("prompt")
      end
    end

    it "returns 422 with not_configured when no type=image model is set" do
      cfg = build_config([
        { "model" => "some-chat-model", "api_key" => "k",
          "base_url" => "https://example.invalid/v1", "type" => "default" }
      ])
      with_server(agent_config: cfg) do |server|
        req = fake_req(method: "POST", path: "/api/media/image",
                       body: { "prompt" => "a cat" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
        body = parsed_body(res)
        expect(body["success"]).to be false
        expect(body["error_type"]).to eq("not_configured")
      end
    end

    it "delegates to the Generator and returns 200 on success" do
      cfg = build_config(image_models)
      fake_result = {
        "success"      => true,
        "image"        => "/tmp/work/assets/generated/img.png",
        "model"        => "or-gpt-image-1",
        "provider"     => "openclacky",
        "prompt"       => "a cat",
        "aspect_ratio" => "square",
        "size"         => "1024x1024"
      }
      expect_any_instance_of(Clacky::Media::Generator).to receive(:generate_image) do |_, **kwargs|
        expect(kwargs[:prompt]).to eq("a cat")
        expect(kwargs[:aspect_ratio]).to eq("square")
        expect(kwargs[:output_dir]).to be_a(String)
        fake_result
      end

      with_server(agent_config: cfg) do |server|
        req = fake_req(
          method: "POST",
          path:   "/api/media/image",
          body:   { "prompt" => "a cat", "aspect_ratio" => "square" }
        )
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(200)
        body = parsed_body(res)
        expect(body["success"]).to be true
        expect(body["image"]).to eq("/tmp/work/assets/generated/img.png")
      end
    end

    it "passes through a caller-supplied output_dir" do
      cfg = build_config(image_models)
      Dir.mktmpdir do |out|
        captured = nil
        expect_any_instance_of(Clacky::Media::Generator).to receive(:generate_image) do |_, **kwargs|
          captured = kwargs[:output_dir]
          { "success" => true, "image" => "x" }
        end

        with_server(agent_config: cfg) do |server|
          req = fake_req(
            method: "POST",
            path:   "/api/media/image",
            body:   { "prompt" => "x", "output_dir" => out }
          )
          res = fake_res
          dispatch(server, req, res)
          expect(captured).to eq(out)
        end
      end
    end

    it "defaults aspect_ratio to landscape when omitted" do
      cfg = build_config(image_models)
      captured = nil
      expect_any_instance_of(Clacky::Media::Generator).to receive(:generate_image) do |_, **kwargs|
        captured = kwargs[:aspect_ratio]
        { "success" => true, "image" => "x" }
      end

      with_server(agent_config: cfg) do |server|
        req = fake_req(method: "POST", path: "/api/media/image",
                       body: { "prompt" => "x" })
        res = fake_res
        dispatch(server, req, res)
        expect(captured).to eq("landscape")
      end
    end

    it "returns 422 with error body when the Generator fails" do
      cfg = build_config(image_models)
      expect_any_instance_of(Clacky::Media::Generator).to receive(:generate_image).and_return(
        "success"    => false,
        "image"      => nil,
        "error"      => "Upstream 401: bad key",
        "error_type" => "api_error"
      )

      with_server(agent_config: cfg) do |server|
        req = fake_req(method: "POST", path: "/api/media/image",
                       body: { "prompt" => "x" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(422)
        body = parsed_body(res)
        expect(body["success"]).to be false
        expect(body["error_type"]).to eq("api_error")
      end
    end

    it "returns 500 when Generator raises an unexpected exception" do
      cfg = build_config(image_models)
      expect_any_instance_of(Clacky::Media::Generator).to receive(:generate_image)
        .and_raise(RuntimeError.new("boom"))

      with_server(agent_config: cfg) do |server|
        req = fake_req(method: "POST", path: "/api/media/image",
                       body: { "prompt" => "x" })
        res = fake_res
        dispatch(server, req, res)
        expect(res.status).to eq(500)
        expect(parsed_body(res)["error"]).to include("boom")
      end
    end
  end
end
