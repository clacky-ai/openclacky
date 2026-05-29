# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe Clacky::BrandConfig do
  def with_temp_brand_file(data = nil)
    tmp_dir    = Dir.mktmpdir
    brand_file = File.join(tmp_dir, "brand.yml")

    File.write(brand_file, YAML.dump(data)) if data

    stub_const("Clacky::BrandConfig::BRAND_FILE", brand_file)
    stub_const("Clacky::BrandConfig::CONFIG_DIR",  tmp_dir)

    yield brand_file
  ensure
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#fetch_free_skills!" do
    let(:fake_client) { instance_double(Clacky::PlatformHttpClient) }

    before do
      allow(Clacky::PlatformHttpClient).to receive(:new).and_return(fake_client)
    end

    it "returns an error when not branded" do
      with_temp_brand_file do
        config = described_class.new({})
        result = config.fetch_free_skills!

        expect(result[:success]).to be false
        expect(result[:skills]).to eq([])
      end
    end

    it "returns an error when package_name is blank" do
      with_temp_brand_file do
        config = described_class.new("product_name" => "JohnAI")
        result = config.fetch_free_skills!

        expect(result[:success]).to be false
        expect(result[:error]).to match(/package_name/i)
      end
    end

    it "returns the skills list when the API succeeds" do
      with_temp_brand_file do
        config = described_class.new(
          "product_name" => "JohnAI",
          "package_name" => "johnai"
        )

        allow(fake_client).to receive(:get).with("/api/v1/distributions/free_skills?package_name=johnai").and_return(
          success: true,
          data: {
            "skills" => [
              {
                "name"           => "free-tool",
                "description"    => "A free tool",
                "latest_version" => { "version" => "1.0.0", "download_url" => "https://example.com/free-tool.zip" }
              }
            ],
            "paid_skills_count" => 3
          }
        )

        result = config.fetch_free_skills!
        expect(result[:success]).to be true
        expect(result[:skills].length).to eq(1)
        expect(result[:skills].first["name"]).to eq("free-tool")
        expect(result[:skills].first["needs_update"]).to be false
        expect(result[:skills].first["installed_version"]).to be_nil
        expect(result[:paid_skills_count]).to eq(3)
      end
    end

    it "URL-encodes package_name" do
      with_temp_brand_file do
        config = described_class.new(
          "product_name" => "JohnAI",
          "package_name" => "weird name"
        )

        expect(fake_client).to receive(:get)
          .with(a_string_including("package_name=weird+name").or(a_string_including("package_name=weird%20name")))
          .and_return(success: true, data: { "skills" => [] })

        result = config.fetch_free_skills!
        expect(result[:success]).to be true
      end
    end

    it "propagates API errors" do
      with_temp_brand_file do
        config = described_class.new(
          "product_name" => "JohnAI",
          "package_name" => "johnai"
        )

        allow(fake_client).to receive(:get).and_return(success: false, error: "HTTP 404")

        result = config.fetch_free_skills!
        expect(result[:success]).to be false
        expect(result[:error]).to eq("HTTP 404")
        expect(result[:skills]).to eq([])
      end
    end
  end

  describe "#sync_free_skills_async!" do
    it "skips when already activated" do
      with_temp_brand_file do
        config = described_class.new(
          "product_name" => "JohnAI",
          "package_name" => "johnai",
          "license_key"  => "AAAAAAAA-AAAAAAAA-AAAAAAAA-AAAAAAAA-AAAAAAAA"
        )
        expect(config.sync_free_skills_async!).to be_nil
      end
    end

    it "skips when not branded" do
      with_temp_brand_file do
        config = described_class.new({})
        expect(config.sync_free_skills_async!).to be_nil
      end
    end

    it "skips in CLACKY_TEST mode" do
      with_temp_brand_file do
        config = described_class.new(
          "product_name" => "JohnAI",
          "package_name" => "johnai"
        )
        # CLACKY_TEST is set by spec_helper, so this is the default path.
        expect(ENV["CLACKY_TEST"]).to eq("1")
        expect(config.sync_free_skills_async!).to be_nil
      end
    end
  end
end
