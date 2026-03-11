# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"

# Tests for the user-licensed features introduced in:
#   1. BrandConfig#license_user_id / #user_licensed?
#   2. BrandConfig#activate! saves user_id from API response
#   3. BrandConfig#save persists license_user_id to brand.yml
#   4. BrandConfig#to_h exposes user_licensed and license_user_id

RSpec.describe Clacky::BrandConfig, "user_licensed features" do
  # ── Helpers ────────────────────────────────────────────────────────────────

  def with_temp_brand_file(data = nil)
    tmp_dir    = Dir.mktmpdir("brand_user_spec_")
    brand_file = File.join(tmp_dir, "brand.yml")

    if data
      File.write(brand_file, YAML.dump(data))
    end

    stub_const("Clacky::BrandConfig::BRAND_FILE", brand_file)
    stub_const("Clacky::BrandConfig::CONFIG_DIR",  tmp_dir)

    yield brand_file
  ensure
    FileUtils.rm_rf(tmp_dir)
  end

  # Stub api_post on a config instance to return an activation response.
  def stub_activate_api(config, user_id: nil, brand_name: "TestBrand", status: "active")
    response_data = {
      "status"     => status,
      "brand_name" => brand_name,
      "expires_at" => (Time.now.utc + 365 * 86_400).iso8601
    }
    # Server returns "owner_user_id" (not "user_id") for system licenses
    response_data["owner_user_id"] = user_id if user_id

    allow(config).to receive(:api_post)
      .with("/api/v1/licenses/activate", anything)
      .and_return({ success: true, data: response_data })
  end

  # A valid test license key (segment 0 = 0x0000002A = 42)
  TEST_KEY = "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4"

  # ── #license_user_id ──────────────────────────────────────────────────────

  describe "#license_user_id" do
    it "is nil when not set in attributes" do
      config = described_class.new({})
      expect(config.license_user_id).to be_nil
    end

    it "loads from YAML attributes" do
      config = described_class.new("license_user_id" => "99")
      expect(config.license_user_id).to eq("99")
    end

    it "persists across .load round-trip" do
      with_temp_brand_file(
        "brand_name"       => "TestBrand",
        "license_key"      => TEST_KEY,
        "license_user_id"  => "42"
      ) do
        config = described_class.load
        expect(config.license_user_id).to eq("42")
      end
    end
  end

  # ── #user_licensed? ───────────────────────────────────────────────────────

  describe "#user_licensed?" do
    it "returns false when license is not activated (no license_key)" do
      config = described_class.new("license_user_id" => "42")
      expect(config.user_licensed?).to be false
    end

    it "returns false when activated but license_user_id is nil" do
      config = described_class.new(
        "brand_name"  => "X",
        "license_key" => TEST_KEY
      )
      expect(config.user_licensed?).to be false
    end

    it "returns false when activated but license_user_id is blank string" do
      config = described_class.new(
        "brand_name"      => "X",
        "license_key"     => TEST_KEY,
        "license_user_id" => "   "
      )
      expect(config.user_licensed?).to be false
    end

    it "returns true when activated and license_user_id is present" do
      config = described_class.new(
        "brand_name"      => "X",
        "license_key"     => TEST_KEY,
        "license_user_id" => "42"
      )
      expect(config.user_licensed?).to be true
    end

    it "returns true regardless of the numeric value of user_id" do
      ["1", "999999", "0"].each do |uid|
        config = described_class.new(
          "brand_name"      => "X",
          "license_key"     => TEST_KEY,
          "license_user_id" => uid
        )
        expect(config.user_licensed?).to be true
      end
    end
  end

  # ── #save persists license_user_id ────────────────────────────────────────

  describe "#save" do
    it "writes license_user_id to brand.yml when present" do
      with_temp_brand_file do |brand_file|
        config = described_class.new(
          "brand_name"      => "TestBrand",
          "license_key"     => TEST_KEY,
          "license_user_id" => "42"
        )
        config.save

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["license_user_id"]).to eq("42")
      end
    end

    it "omits license_user_id from brand.yml when nil" do
      with_temp_brand_file do |brand_file|
        config = described_class.new("brand_name" => "TestBrand")
        config.save

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved.key?("license_user_id")).to be false
      end
    end

    it "omits license_user_id from brand.yml when blank string" do
      with_temp_brand_file do |brand_file|
        config = described_class.new(
          "brand_name"      => "TestBrand",
          "license_user_id" => "  "
        )
        config.save

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved.key?("license_user_id")).to be false
      end
    end
  end

  # ── #to_h exposes user_licensed and license_user_id ──────────────────────

  describe "#to_h" do
    it "includes user_licensed: false when license_user_id is absent" do
      config = described_class.new(
        "brand_name"  => "X",
        "license_key" => TEST_KEY
      )
      h = config.to_h
      expect(h[:user_licensed]).to be false
      expect(h[:license_user_id]).to be_nil
    end

    it "includes user_licensed: true when activated with license_user_id" do
      config = described_class.new(
        "brand_name"      => "X",
        "license_key"     => TEST_KEY,
        "license_user_id" => "42"
      )
      h = config.to_h
      expect(h[:user_licensed]).to be true
      expect(h[:license_user_id]).to eq("42")
    end

    it "includes all expected keys in the hash" do
      config = described_class.new(
        "brand_name"      => "X",
        "license_key"     => TEST_KEY,
        "license_user_id" => "7"
      )
      h = config.to_h
      expect(h.keys).to include(:user_licensed, :license_user_id, :branded, :activated, :expired,
                                  :license_expires_at)
    end
  end

  # ── #activate! saves user_id from API response ────────────────────────────

  describe "#activate!" do
    it "saves license_user_id when API returns user_id" do
      with_temp_brand_file("brand_name" => "TestBrand") do
        config = described_class.new("brand_name" => "TestBrand")
        stub_activate_api(config, user_id: "42")

        result = config.activate!(TEST_KEY)

        expect(result[:success]).to be true
        expect(result[:user_id]).to eq("42")
        expect(config.license_user_id).to eq("42")
        expect(config.user_licensed?).to be true
      end
    end

    it "does not set license_user_id when API omits user_id" do
      with_temp_brand_file("brand_name" => "TestBrand") do
        config = described_class.new("brand_name" => "TestBrand")
        stub_activate_api(config)  # no user_id

        result = config.activate!(TEST_KEY)

        expect(result[:success]).to be true
        expect(result[:user_id]).to be_nil
        expect(config.license_user_id).to be_nil
        expect(config.user_licensed?).to be false
      end
    end

    it "does not set license_user_id when API returns empty string user_id" do
      with_temp_brand_file("brand_name" => "TestBrand") do
        config = described_class.new("brand_name" => "TestBrand")
        stub_activate_api(config, user_id: "")

        config.activate!(TEST_KEY)

        expect(config.license_user_id).to be_nil
        expect(config.user_licensed?).to be false
      end
    end

    it "persists license_user_id to brand.yml after successful activation" do
      with_temp_brand_file("brand_name" => "TestBrand") do |brand_file|
        config = described_class.new("brand_name" => "TestBrand")
        stub_activate_api(config, user_id: "99")

        config.activate!(TEST_KEY)

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["license_user_id"]).to eq("99")
        expect(saved["license_key"]).to eq(TEST_KEY)
      end
    end

    it "does not persist license_user_id when API returns failure" do
      with_temp_brand_file("brand_name" => "TestBrand") do |brand_file|
        config = described_class.new("brand_name" => "TestBrand")
        allow(config).to receive(:api_post)
          .with("/api/v1/licenses/activate", anything)
          .and_return({ success: false, error: "invalid_proof", data: { "code" => "invalid_proof" } })

        result = config.activate!(TEST_KEY)

        expect(result[:success]).to be false
        expect(config.license_user_id).to be_nil

        # brand.yml not updated on failure (no save called)
        saved = YAML.safe_load(File.read(brand_file)) || {}
        expect(saved.key?("license_user_id")).to be false
      end
    end

    it "result hash includes user_id key pointing to the saved value" do
      with_temp_brand_file("brand_name" => "TestBrand") do
        config = described_class.new("brand_name" => "TestBrand")
        stub_activate_api(config, user_id: "77")

        result = config.activate!(TEST_KEY)

        expect(result).to include(success: true, user_id: "77")
      end
    end
  end

  # ── .load / save round-trip ───────────────────────────────────────────────

  describe ".load round-trip" do
    it "restores user_licensed? state correctly after save and reload" do
      with_temp_brand_file do
        original = described_class.new(
          "brand_name"      => "RoundTrip",
          "license_key"     => TEST_KEY,
          "license_user_id" => "55"
        )
        original.save

        reloaded = described_class.load
        expect(reloaded.license_user_id).to eq("55")
        expect(reloaded.user_licensed?).to be true
      end
    end

    it "correctly restores non-user-licensed state after save and reload" do
      with_temp_brand_file do
        original = described_class.new(
          "brand_name"  => "NoUserLicense",
          "license_key" => TEST_KEY
        )
        original.save

        reloaded = described_class.load
        expect(reloaded.license_user_id).to be_nil
        expect(reloaded.user_licensed?).to be false
      end
    end
  end

  # ── .version_older? ───────────────────────────────────────────────────────

  describe ".version_older?" do
    subject { described_class }

    it "returns true when installed is older than latest" do
      expect(subject.version_older?("1.0.0", "1.0.4")).to be true
      expect(subject.version_older?("1.0.3", "1.1.0")).to be true
      expect(subject.version_older?("0.9.9", "1.0.0")).to be true
    end

    it "returns false when installed equals latest (already up to date)" do
      expect(subject.version_older?("1.0.4", "1.0.4")).to be false
    end

    it "returns false when installed is NEWER than latest (local dev build)" do
      # This was the bug: v1.0.4 installed, server reports v1.0.0 → must NOT show Update
      expect(subject.version_older?("1.0.4", "1.0.0")).to be false
      expect(subject.version_older?("2.0.0", "1.9.9")).to be false
    end

    it "returns false when installed version is nil or blank" do
      expect(subject.version_older?(nil,  "1.0.0")).to be false
      expect(subject.version_older?("",   "1.0.0")).to be false
      expect(subject.version_older?("  ", "1.0.0")).to be false
    end

    it "returns false when latest version is nil or blank" do
      expect(subject.version_older?("1.0.0", nil )).to be false
      expect(subject.version_older?("1.0.0", ""  )).to be false
    end

    it "returns false for unparseable version strings without raising" do
      expect { subject.version_older?("not-a-version", "1.0.0") }.not_to raise_error
      expect(subject.version_older?("not-a-version", "1.0.0")).to be false
    end
  end
end
