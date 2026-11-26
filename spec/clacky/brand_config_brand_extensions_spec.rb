# frozen_string_literal: true

require "spec_helper"

# Tests for the brand-extension catalog consumed by the extension panel:
#   #fetch_brand_extensions!
# Brand extensions are never installed automatically, so nothing here covers
# install/update/delete — only the license-HMAC fetch against
# POST /api/v1/licenses/extensions and the local install-state annotation.

RSpec.describe Clacky::BrandConfig, "brand extensions" do
  BRAND_EXT_KEY = "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4"

  def admin_config
    described_class.new(
      "brand_name"      => "X",
      "license_key"     => BRAND_EXT_KEY,
      "license_user_id" => "42"
    )
  end

  let(:fake_client) { instance_double(Clacky::PlatformHttpClient) }

  before do
    allow_any_instance_of(described_class).to receive(:platform_client).and_return(fake_client)
    allow(Clacky::ExtensionLoader).to receive(:load_all)
      .and_return(Clacky::ExtensionLoader::Result.new(containers: {}))
  end

  describe "#fetch_brand_extensions!" do
    it "returns error when not activated" do
      config = described_class.new("brand_name" => "X")
      result = config.fetch_brand_extensions!
      expect(result[:success]).to be false
      expect(result[:extensions]).to eq([])
    end

    it "POSTs a signed payload and annotates install state" do
      config = admin_config

      expect(fake_client).to receive(:post) do |path, payload|
        expect(path).to eq("/api/v1/licenses/extensions")
        expect(payload[:signature]).to be_a(String)
        expect(payload[:sort]).to eq("updated")
        { success: true, data: {
          "status"     => "success",
          "extensions" => [{ "name" => "meeting", "latest_version" => { "version" => "1.0.0" } }],
          "expires_at" => "2030-01-01T00:00:00Z"
        } }
      end

      result = config.fetch_brand_extensions!(sort: "updated")
      expect(result[:success]).to be true
      ext = result[:extensions].first
      expect(ext["name"]).to eq("meeting")
      expect(ext["installed_version"]).to be_nil
      expect(ext["needs_update"]).to be true
    end

    it "reads installed versions from the installed layer on disk" do
      config = admin_config
      containers = {
        "meeting" => { layer: :installed, version: "1.0.0" },
        "local-one" => { layer: :local, version: "9.9.9" }
      }
      allow(Clacky::ExtensionLoader).to receive(:load_all)
        .and_return(Clacky::ExtensionLoader::Result.new(containers: containers))

      allow(fake_client).to receive(:post).and_return(
        success: true,
        data: {
          "extensions" => [
            { "name" => "meeting", "latest_version" => { "version" => "1.2.0" } },
            { "name" => "local-one", "latest_version" => { "version" => "1.0.0" } }
          ]
        }
      )

      extensions = config.fetch_brand_extensions![:extensions]
      meeting = extensions.find { |e| e["name"] == "meeting" }
      local   = extensions.find { |e| e["name"] == "local-one" }

      expect(meeting["installed_version"]).to eq("1.0.0")
      expect(meeting["needs_update"]).to be true
      # Only the `installed` layer counts; a local/self-authored container is
      # not an installed brand extension.
      expect(local["installed_version"]).to be_nil
      expect(local["needs_update"]).to be true
    end
  end
end
