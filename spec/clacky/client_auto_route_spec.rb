# frozen_string_literal: true

require "spec_helper"
require "clacky/client"
require "webrick"

# End-to-end guard for the "auto" gateway alias: the platform rewrites the
# model economy-first and reports the concrete model via the
# X-Clacky-Routed-Model response header. The client must surface it as
# response[:routed_model] and report it in the latency hash (status bar /
# cost tracking both key off latency.model).
RSpec.describe Clacky::Client, "auto alias routed model" do
  let(:routed_model) { "dsk-deepseek-flash" }
  let(:completion_body) do
    {
      "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
      "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6 }
    }.to_json
  end

  def with_stub_server(response_block)
    server = WEBrick::HTTPServer.new(Port: 0, AccessLog: [], Logger: WEBrick::Log.new(IO::NULL, WEBrick::Log::FATAL))
    server.mount_proc("/chat/completions") do |req, res|
      response_block.call(req, res)
    end
    t = Thread.new { server.start }
    port = server[:Port]
    yield "http://127.0.0.1:#{port}"
  ensure
    server&.shutdown
    t&.join(2)
  end

  def client_for(base_url)
    described_class.new("k", base_url: base_url, model: "auto")
  end

  it "non-streaming: captures routed model header and reports it as latency model" do
    with_stub_server(proc { |_req, res|
      res["X-Clacky-Routed-Model"] = routed_model
      res["Content-Type"] = "application/json"
      res.body = completion_body
    }) do |base_url|
      client = client_for(base_url)
      response = client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64
      )
      expect(response[:routed_model]).to eq(routed_model)
      expect(response[:latency][:model]).to eq(routed_model)
    end
  end

  it "streaming: captures routed model header" do
    frames = [
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}\n\n",
      "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1,\"total_tokens\":6}}\n\n",
      "data: [DONE]\n\n"
    ].join

    with_stub_server(proc { |_req, res|
      res["X-Clacky-Routed-Model"] = routed_model
      res["Content-Type"] = "text/event-stream"
      res.body = frames
    }) do |base_url|
      client = client_for(base_url)
      response = client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64,
        on_chunk: proc { |**| }
      )
      expect(response[:routed_model]).to eq(routed_model)
      expect(response[:latency][:model]).to eq(routed_model)
    end
  end

  it "non-streaming: sends retry signal headers when provided" do
    seen = {}
    with_stub_server(proc { |req, res|
      seen[:iteration] = req.header["x-clacky-agent-iteration"]
      seen[:retries] = req.header["x-clacky-agent-retries"]&.first
      seen[:upstream_fails] = req.header["x-clacky-agent-upstream-fails"]&.first
      seen[:role] = req.header["x-clacky-agent-role"]&.first
      res["Content-Type"] = "application/json"
      res.body = completion_body
    }) do |base_url|
      client = client_for(base_url)
      client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64,
        agent_retries: 2, agent_upstream_fails: 1
      )
      expect(seen[:retries]).to eq("2")
      expect(seen[:upstream_fails]).to eq("1")
      expect(seen[:role]).to be_nil
      expect(seen[:iteration]).to be_empty
    end
  end

  it "streaming: sends retry signal headers when provided" do
    frames = [
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}\n\n",
      "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1,\"total_tokens\":6}}\n\n",
      "data: [DONE]\n\n"
    ].join

    seen = {}
    with_stub_server(proc { |req, res|
      seen[:iteration] = req.header["x-clacky-agent-iteration"]
      seen[:retries] = req.header["x-clacky-agent-retries"]&.first
      seen[:upstream_fails] = req.header["x-clacky-agent-upstream-fails"]&.first
      res["Content-Type"] = "text/event-stream"
      res.body = frames
    }) do |base_url|
      client = client_for(base_url)
      client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64,
        on_chunk: proc { |**| }, agent_retries: 1, agent_upstream_fails: 2
      )
      expect(seen[:iteration]).to be_empty
      expect(seen[:retries]).to eq("1")
      expect(seen[:upstream_fails]).to eq("2")
    end
  end

  it "without routed model header: latency model falls back to the request model" do
    with_stub_server(proc { |_req, res|
      res["Content-Type"] = "application/json"
      res.body = completion_body
    }) do |base_url|
      client = client_for(base_url)
      response = client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64
      )
      expect(response[:routed_model]).to be_nil
      expect(response[:latency][:model]).to eq("auto")
    end
  end

  it "non-streaming: captures routed tier header" do
    with_stub_server(proc { |_req, res|
      res["X-Clacky-Routed-Model"] = "or-gemini-3-8-flash"
      res["X-Clacky-Routed-Tier"] = "upgrade"
      res["Content-Type"] = "application/json"
      res.body = completion_body
    }) do |base_url|
      client = client_for(base_url)
      response = client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64
      )
      expect(response[:routed_tier]).to eq("upgrade")
    end
  end

  it "streaming: captures routed tier header" do
    frames = [
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}\n\n",
      "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
      "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1,\"total_tokens\":6}}\n\n",
      "data: [DONE]\n\n"
    ].join

    with_stub_server(proc { |_req, res|
      res["X-Clacky-Routed-Tier"] = "floor"
      res["Content-Type"] = "text/event-stream"
      res.body = frames
    }) do |base_url|
      client = client_for(base_url)
      response = client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64,
        on_chunk: proc { |**| }
      )
      expect(response[:routed_tier]).to eq("floor")
    end
  end

  it "non-streaming: sends upgrade-fails header when provided" do
    seen = {}
    with_stub_server(proc { |req, res|
      seen[:upgrade_fails] = req.header["x-clacky-agent-upgrade-fails"]&.first
      res["Content-Type"] = "application/json"
      res.body = completion_body
    }) do |base_url|
      client = client_for(base_url)
      client.send_messages_with_tools(
        [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64,
        agent_upgrade_fails: 1
      )
      expect(seen[:upgrade_fails]).to eq("1")
    end
  end

  it "non-streaming: server error carries routed tier on the raised RetryableError" do
    with_stub_server(proc { |_req, res|
      res.status = 503
      res["X-Clacky-Routed-Tier"] = "upgrade"
      res["Content-Type"] = "application/json"
      res.body = { "error" => { "message" => "upstream unavailable" } }.to_json
    }) do |base_url|
      client = client_for(base_url)
      expect {
        client.send_messages_with_tools(
          [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64
        )
      }.to raise_error(Clacky::RetryableError) { |e|
        expect(e.routed_tier).to eq("upgrade")
      }
    end
  end

  it "non-streaming: server error without tier header raises unattributed" do
    with_stub_server(proc { |_req, res|
      res.status = 429
      res["Content-Type"] = "application/json"
      res.body = { "error" => { "message" => "rate limited" } }.to_json
    }) do |base_url|
      client = client_for(base_url)
      expect {
        client.send_messages_with_tools(
          [{ role: "user", content: "hi" }], model: "auto", tools: [], max_tokens: 64
        )
      }.to raise_error(Clacky::RetryableError) { |e|
        expect(e.routed_tier).to be_nil
      }
    end
  end
end
