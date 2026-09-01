# frozen_string_literal: true

require "spec_helper"

# Tests for the brand-extension download/consume methods on BrandConfig:
#   #fetch_brand_extensions! / #install_brand_extension! / #installed_brand_extensions
#   #delete_brand_extension!
# These parallel the brand-skill download path and use the license-HMAC scheme
# against POST /api/v1/licenses/extensions.

RSpec.describe Clacky::BrandConfig, "brand extensions" do
  BRAND_EXT_KEY = "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4"

  def admin_config
    described_class.new(
      "brand_name"      => "X",
      "license_key"     => BRAND_EXT_KEY,
      "license_user_id" => "42"
    )
  end

  def consumer_config
    described_class.new(
      "brand_name"  => "X",
      "license_key" => BRAND_EXT_KEY
    )
  end

  def without_clacky_test
    previous = ENV.delete("CLACKY_TEST")
    yield
  ensure
    ENV["CLACKY_TEST"] = previous
  end

  let(:fake_client) { instance_double(Clacky::PlatformHttpClient) }
  let(:tmp_installed) { Dir.mktmpdir("clacky-brand-ext") }

  before do
    allow_any_instance_of(described_class).to receive(:platform_client).and_return(fake_client)
    stub_const("Clacky::ExtensionLoader::INSTALLED_DIR", tmp_installed)
  end

  after do
    FileUtils.rm_rf(tmp_installed)
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
        { success: true, data: {
          "status"     => "success",
          "extensions" => [{ "name" => "meeting", "latest_version" => { "version" => "1.0.0" } }],
          "expires_at" => "2030-01-01T00:00:00Z"
        } }
      end

      result = config.fetch_brand_extensions!
      expect(result[:success]).to be true
      ext = result[:extensions].first
      expect(ext["name"]).to eq("meeting")
      expect(ext["installed_version"]).to be_nil
      expect(ext["needs_update"]).to be true
    end
  end

  describe "#install_brand_extension! + #installed_brand_extensions" do
    it "installs via the packager and records the version" do
      config   = admin_config
      ext_info = { "name" => "meeting", "latest_version" => { "version" => "1.2.0", "download_url" => "https://x/meeting.zip" } }

      expect(Clacky::ExtensionPackager).to receive(:install).with("https://x/meeting.zip", force: true)
      # Simulate the container the packager would have written.
      FileUtils.mkdir_p(File.join(tmp_installed, "meeting"))

      result = config.install_brand_extension!(ext_info)
      expect(result[:success]).to be true
      expect(result[:version]).to eq("1.2.0")

      installed = config.installed_brand_extensions
      expect(installed["meeting"]["version"]).to eq("1.2.0")
    end

    it "fails cleanly when no download URL is present" do
      config = admin_config
      result = config.install_brand_extension!("name" => "meeting", "latest_version" => {})
      expect(result[:success]).to be false
      expect(result[:error]).to match(/download URL/i)
    end
  end

  describe "#delete_brand_extension!" do
    it "removes the container and the registry entry" do
      config = admin_config
      FileUtils.mkdir_p(File.join(tmp_installed, "meeting"))
      File.write(config.brand_extensions_registry_path, JSON.generate("meeting" => { "version" => "1.0.0" }))

      config.delete_brand_extension!("meeting")

      expect(Dir.exist?(File.join(tmp_installed, "meeting"))).to be false
      expect(config.installed_brand_extensions).not_to have_key("meeting")
    end
  end

  describe "#installed_brand_extensions" do
    it "prunes entries whose container is gone" do
      config = admin_config
      File.write(config.brand_extensions_registry_path, JSON.generate("gone" => { "version" => "1.0.0" }))
      expect(config.installed_brand_extensions).to eq({})
    end
  end

  describe "#sync_brand_extensions_async!" do
    it "skips automatic sync for brand administrators" do
      config = admin_config

      without_clacky_test do
        expect(Clacky::ThreadRegistry).not_to receive(:spawn)
        expect(config.sync_brand_extensions_async!).to be_nil
      end
    end

    it "keeps automatic sync enabled for consumer licenses" do
      config = consumer_config
      thread = instance_double(Thread)

      without_clacky_test do
        expect(Clacky::ThreadRegistry).to receive(:spawn)
          .with(name: "brand-fetch-extensions")
          .and_return(thread)
        expect(config.sync_brand_extensions_async!).to be(thread)
      end
    end
  end
end
