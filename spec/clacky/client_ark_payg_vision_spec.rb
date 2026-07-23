# frozen_string_literal: true

require "spec_helper"
require "clacky/client"

# Regression guard: on Volcengine Ark's pay-as-you-go endpoint, display model
# names are swapped for versioned API ids (e.g. "glm-5.2" -> "glm-5-2-260617")
# before the request goes out. Vision support must still be judged against the
# *display* name — the capability table is keyed by short names, so feeding it
# the versioned id would miss the vision=false declaration and let image_url
# blocks leak into a text-only model, which the endpoint rejects.
RSpec.describe Clacky::Client, "Ark payg model-id mapping keeps vision judgement on display name" do
  let(:api_key)  { "ark-test" }
  let(:base_url) { "https://ark.cn-beijing.volces.com/api/v3" }

  let(:client) do
    described_class.new(api_key, base_url: base_url, model: "glm-5.2")
  end

  let(:messages_with_image) do
    [
      { role: "user", content: [
        { type: "text", text: "what is this?" },
        { type: "image_url", image_url: { url: "data:image/png;base64,#{"A" * 64}" } }
      ] }
    ]
  end

  def capture_request_body(api_model:, capability_model:)
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

    client.send(:send_openai_request, messages_with_image, api_model, [], 1024, false,
                capability_model: capability_model)
    captured
  end

  it "sends the versioned api id but strips images per the display-name vision judgement" do
    body = capture_request_body(api_model: "glm-5-2-260617", capability_model: "glm-5.2")

    expect(body["model"]).to eq("glm-5-2-260617")

    content = body["messages"].last["content"]
    flat = content.is_a?(Array) ? content.map { |b| b.to_s }.join : content.to_s
    expect(flat).not_to include("image_url")
    expect(flat).to include("Image content removed")
  end

  it "keeps images for a vision-capable display model even when the api id differs" do
    body = capture_request_body(api_model: "doubao-seed-2-0-pro-260215", capability_model: "doubao-seed-2.0-pro")

    expect(body["model"]).to eq("doubao-seed-2-0-pro-260215")

    content = body["messages"].last["content"]
    types = content.map { |b| b["type"] }
    expect(types).to include("image_url")
  end

  it "falls back to model for vision when capability_model is omitted" do
    body = capture_request_body(api_model: "glm-5.2", capability_model: nil)

    content = body["messages"].last["content"]
    flat = content.is_a?(Array) ? content.map { |b| b.to_s }.join : content.to_s
    expect(flat).not_to include("image_url")
  end
end
