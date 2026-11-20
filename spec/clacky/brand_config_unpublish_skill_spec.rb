# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Unpublishing a published skill from the cloud skills list.
#   platform: DELETE /api/v1/client/skills/:id  (id or name) → soft delete
#   client:   BrandConfig#delete_skill! / .forget_upload!
RSpec.describe Clacky::BrandConfig, "unpublish a skill" do
  let(:fake_client) { instance_double(Clacky::PlatformHttpClient) }
  let(:config)      { described_class.new("brand_name" => "X") }

  before do
    allow_any_instance_of(described_class).to receive(:platform_client).and_return(fake_client)
    config.instance_variable_set(:@license_user_id, 42)
    config.instance_variable_set(:@license_key, "KEY-123")
    config.instance_variable_set(:@device_id, "dev-abc")
  end

  describe "#delete_skill!" do
    it "refuses when the license is not activated" do
      allow(config).to receive(:activated?).and_return(false)

      result = config.delete_skill!("add-llm-model")
      expect(result[:success]).to be false
      expect(result[:error]).to match(/not activated/i)
    end

    it "refuses without a user license" do
      allow(config).to receive(:activated?).and_return(true)
      allow(config).to receive(:user_licensed?).and_return(false)

      result = config.delete_skill!("add-llm-model")
      expect(result[:success]).to be false
      expect(result[:error]).to match(/user license/i)
    end

    it "DELETEs by encoded name with the signed-request params in the query string" do
      allow(config).to receive(:activated?).and_return(true)
      allow(config).to receive(:user_licensed?).and_return(true)

      expect(fake_client).to receive(:delete) do |path|
        base, query = path.split("?", 2)
        expect(base).to eq("/api/v1/client/skills/add-llm-model")

        params = URI.decode_www_form(query).to_h
        expect(params.keys).to contain_exactly(
          "key_hash", "user_id", "device_id", "timestamp", "nonce", "signature"
        )
        expect(params["user_id"]).to eq("42")
        expect(params["device_id"]).to eq("dev-abc")
        expect(params["key_hash"]).to eq(Digest::SHA256.hexdigest("KEY-123"))
        expect(params["signature"]).to match(/\A[0-9a-f]{64}\z/)
        { success: true, data: {} }
      end

      expect(config.delete_skill!("add-llm-model")[:success]).to be true
    end

    it "surfaces the platform error message on failure" do
      allow(config).to receive(:activated?).and_return(true)
      allow(config).to receive(:user_licensed?).and_return(true)
      allow(fake_client).to receive(:delete).and_return({ success: false, error: "HTTP 404" })

      result = config.delete_skill!("gone")
      expect(result[:success]).to be false
      expect(result[:error]).to eq("HTTP 404")
    end
  end

  describe ".forget_upload!" do
    before do
      @tmpdir = Dir.mktmpdir
      stub_const("Clacky::BrandConfig::UPLOAD_META_FILE", File.join(@tmpdir, "upload_meta.json"))
    end

    after { FileUtils.remove_entry(@tmpdir) }

    it "drops only the named skill from the upload metadata" do
      described_class.record_upload!("keep-me", "1.0.0")
      described_class.record_upload!("drop-me", "1.0.0")

      described_class.forget_upload!("drop-me")

      meta = described_class.load_upload_meta
      expect(meta.keys).to eq(["keep-me"])
    end

    it "is a no-op for an unknown skill" do
      described_class.record_upload!("keep-me", "1.0.0")

      expect { described_class.forget_upload!("nope") }.not_to raise_error
      expect(described_class.load_upload_meta.keys).to eq(["keep-me"])
    end
  end
end
