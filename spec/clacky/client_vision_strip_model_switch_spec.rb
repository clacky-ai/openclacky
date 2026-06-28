# frozen_string_literal: true

require "spec_helper"
require "clacky/client"

# Regression guard (C-5636): vision support must be resolved against the
# request's actual model, not the model the Client was constructed with.
#
# A Client built on a vision-capable model (qwen3.6-plus) used to cache
# @vision_supported = true at construction time. When the request was then
# sent with a non-vision model (qwen3.7-max) — via a runtime model switch or a
# fallback override — image_url blocks were NOT stripped, and the upstream
# rejected the request with:
#   400 InternalError.Algo.InvalidParameter: ... [Unexpected item type in content.]
RSpec.describe Clacky::Client, "vision strip follows request model" do
  let(:api_key)  { "sk-test" }
  let(:base_url) { "https://dashscope.aliyuncs.com/compatible-mode/v1" }

  let(:client) do
    described_class.new(api_key, base_url: base_url, model: "qwen3.6-plus")
  end

  let(:messages_with_image) do
    [
      { role: "user", content: [
        { type: "text", text: "what is this?" },
        { type: "image_url", image_url: { url: "data:image/png;base64,#{"A" * 64}" } }
      ] }
    ]
  end

  def capture_request_body(request_model)
    captured = nil
    fake_response = instance_double(
      Faraday::Response, status: 200,
      body: { "choices" => [{ "message" => { "content" => "ok" } }] }.to_json
    )
    fake_conn = instance_double(Faraday::Connection)
    allow(client).to receive(:openai_connection).and_return(fake_conn)
    allow(fake_conn).to receive(:post) do |&block|
      req = Struct.new(:body).new
      block.call(req)
      captured = JSON.parse(req.body)
      fake_response
    end

    client.send(:send_openai_request, messages_with_image, request_model, [], 1024, false)
    captured
  end

  it "strips image_url when the request model is non-vision (qwen3.7-max)" do
    body = capture_request_body("qwen3.7-max")
    content = body["messages"].last["content"]
    flat = content.is_a?(Array) ? content.map { |b| b.to_s }.join : content.to_s

    expect(flat).not_to include("image_url")
    expect(flat).to include("Image content removed")
  end

  it "keeps image_url when the request model is vision-capable (qwen3.6-plus)" do
    body = capture_request_body("qwen3.6-plus")
    content = body["messages"].last["content"]
    types = content.map { |b| b["type"] }

    expect(types).to include("image_url")
  end
end
