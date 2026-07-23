# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::BrandConfig, "enterprise knowledge" do
  LICENSE_KEY = "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4"
  DEVICE_ID = "knowledge-device"

  let(:config) do
    described_class.new(
      "product_name" => "Acme",
      "license_key" => LICENSE_KEY,
      "device_id" => DEVICE_ID
    )
  end
  let(:client) { instance_double(Clacky::PlatformHttpClient) }

  before do
    allow_any_instance_of(described_class).to receive(:platform_client).and_return(client)
    allow(Time).to receive_message_chain(:now, :utc, :to_i).and_return(1_700_000_000)
    allow(SecureRandom).to receive(:hex).with(16).and_return("fixed-nonce")
  end

  it "lists knowledge bases with the standard License HMAC payload" do
    expect(client).to receive(:post) do |path, payload|
      expect(path).to eq("/api/v1/licenses/knowledge_bases")
      expect(payload).to include(
        key_hash: Digest::SHA256.hexdigest(LICENSE_KEY),
        user_id: "42",
        device_id: DEVICE_ID,
        timestamp: "1700000000",
        nonce: "fixed-nonce"
      )
      message = "42:#{DEVICE_ID}:1700000000:fixed-nonce"
      expect(payload[:signature]).to eq(OpenSSL::HMAC.hexdigest("SHA256", LICENSE_KEY, message))
      { success: true, data: { "knowledge_bases" => [{ "id" => 9, "name" => "Handbook" }] } }
    end

    expect(config.knowledge_list).to eq(
      success: true,
      knowledge_bases: [{ "id" => 9, "name" => "Handbook" }]
    )
  end

  it "requests a knowledge tree" do
    expect(client).to receive(:post).with(
      "/api/v1/licenses/knowledge/tree",
      hash_including(knowledge_base_id: 9)
    ).and_return(success: true, data: { "tree" => [{ "name" => "policies" }] })

    expect(config.knowledge_tree(knowledge_base_id: 9)).to eq(
      success: true,
      tree: [{ "name" => "policies" }]
    )
  end

  it "searches with a bounded limit" do
    expect(client).to receive(:post).with(
      "/api/v1/licenses/knowledge/search",
      hash_including(knowledge_base_id: 9, query: "travel", limit: 50)
    ).and_return(success: true, data: { "results" => [{ "uri" => "viking://travel.md" }] })

    expect(config.knowledge_search(knowledge_base_id: 9, query: "travel", limit: 100)).to eq(
      success: true,
      results: [{ "uri" => "viking://travel.md" }]
    )
  end

  it "reads content by URI" do
    uri = "viking://resources/knowledge-bases/9/travel.md"
    expect(client).to receive(:post).with(
      "/api/v1/licenses/knowledge/read",
      hash_including(knowledge_base_id: 9, uri:)
    ).and_return(success: true, data: { "uri" => uri, "content" => "Policy text" })

    expect(config.knowledge_read(knowledge_base_id: 9, uri:)).to eq(
      success: true,
      uri:,
      content: "Policy text"
    )
  end

  it "returns a structured error when the License is not activated" do
    result = described_class.new("device_id" => DEVICE_ID).knowledge_list

    expect(result).to eq(success: false, error: "License not activated")
  end

  it "does not expose the License key in transport errors" do
    allow(client).to receive(:post).and_raise(StandardError, "timeout for #{LICENSE_KEY}")

    result = config.knowledge_search(knowledge_base_id: 9, query: "travel")

    expect(result[:success]).to be false
    expect(result[:error]).not_to include(LICENSE_KEY)
  end
end
