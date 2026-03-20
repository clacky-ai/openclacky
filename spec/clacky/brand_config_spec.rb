# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe Clacky::BrandConfig do
  # ── Helpers ────────────────────────────────────────────────────────────────

  # Run block with a temporary brand.yml path injected via stub.
  def with_temp_brand_file(data = nil)
    tmp_dir   = Dir.mktmpdir
    brand_file = File.join(tmp_dir, "brand.yml")

    if data
      File.write(brand_file, YAML.dump(data))
    end

    allow(described_class).to receive(:const_get).and_call_original
    stub_const("Clacky::BrandConfig::BRAND_FILE", brand_file)
    stub_const("Clacky::BrandConfig::CONFIG_DIR",  tmp_dir)

    yield brand_file
  ensure
    FileUtils.rm_rf(tmp_dir)
  end

  # ── .load ──────────────────────────────────────────────────────────────────

  describe ".load" do
    context "when brand.yml does not exist" do
      it "returns an unbranded BrandConfig" do
        with_temp_brand_file do
          config = described_class.load
          expect(config.branded?).to be false
          expect(config.product_name).to be_nil
        end
      end
    end

    context "when brand.yml exists with a product_name" do
      it "loads product_name" do
        with_temp_brand_file("product_name" => "JohnAI") do
          config = described_class.load
          expect(config.branded?).to be true
          expect(config.product_name).to eq("JohnAI")
        end
      end

      it "loads package_name" do
        with_temp_brand_file("product_name" => "JohnAI", "package_name" => "johncli") do
          config = described_class.load
          expect(config.package_name).to eq("johncli")
        end
      end

      it "loads license fields" do
        data = {
          "product_name"          => "JohnAI",
          "license_key"           => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
          "license_activated_at"  => "2025-03-01T00:00:00Z",
          "license_expires_at"    => "2099-03-01T00:00:00Z",
          "license_last_heartbeat"=> "2025-03-05T00:00:00Z",
          "device_id"             => "abc123"
        }
        with_temp_brand_file(data) do
          config = described_class.load
          expect(config.license_key).to eq("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
          expect(config.device_id).to eq("abc123")
          expect(config.license_expires_at).to be_a(Time)
        end
      end

      it "returns unbranded config on malformed YAML" do
        with_temp_brand_file do |brand_file|
          File.write(brand_file, "--- :\n bad: [yaml")
          config = described_class.load
          expect(config.branded?).to be false
        end
      end
    end
  end

  # ── #branded? ─────────────────────────────────────────────────────────────

  describe "#branded?" do
    it "returns false when product_name is nil" do
      config = described_class.new({})
      expect(config.branded?).to be false
    end

    it "returns false when product_name is blank" do
      config = described_class.new("product_name" => "  ")
      expect(config.branded?).to be false
    end

    it "returns true when product_name is present" do
      config = described_class.new("product_name" => "AcmeCLI")
      expect(config.branded?).to be true
    end
  end

  # ── #activated? ───────────────────────────────────────────────────────────

  describe "#activated?" do
    it "returns false when license_key is absent" do
      config = described_class.new("product_name" => "X")
      expect(config.activated?).to be false
    end

    it "returns true when license_key is present" do
      config = described_class.new(
        "brand_name"  => "X",
        "license_key" => "AAAABBBB-CCCCDDDD-EEEEFFFF-00001111-22223333"
      )
      expect(config.activated?).to be true
    end
  end

  # ── #expired? ─────────────────────────────────────────────────────────────

  describe "#expired?" do
    it "returns false when expires_at is nil" do
      config = described_class.new({})
      expect(config.expired?).to be false
    end

    it "returns false when expiry is in the future" do
      config = described_class.new("license_expires_at" => (Time.now + 3600).utc.iso8601)
      expect(config.expired?).to be false
    end

    it "returns true when expiry is in the past" do
      config = described_class.new("license_expires_at" => "2000-01-01T00:00:00Z")
      expect(config.expired?).to be true
    end
  end

  # ── #heartbeat_due? ───────────────────────────────────────────────────────

  describe "#heartbeat_due?" do
    it "returns true when last_heartbeat is nil" do
      config = described_class.new({})
      expect(config.heartbeat_due?).to be true
    end

    it "returns true when heartbeat interval has elapsed" do
      old_ts = (Time.now.utc - Clacky::BrandConfig::HEARTBEAT_INTERVAL - 1).iso8601
      config = described_class.new("license_last_heartbeat" => old_ts)
      expect(config.heartbeat_due?).to be true
    end

    it "returns false when heartbeat was recent" do
      recent_ts = (Time.now.utc - 60).iso8601
      config = described_class.new("license_last_heartbeat" => recent_ts)
      expect(config.heartbeat_due?).to be false
    end
  end

  # ── #grace_period_exceeded? ───────────────────────────────────────────────

  describe "#grace_period_exceeded?" do
    it "returns false when last_heartbeat is nil" do
      config = described_class.new({})
      expect(config.grace_period_exceeded?).to be false
    end

    it "returns true when grace period has elapsed" do
      old_ts = (Time.now.utc - Clacky::BrandConfig::HEARTBEAT_GRACE_PERIOD - 1).iso8601
      config = described_class.new("license_last_heartbeat" => old_ts)
      expect(config.grace_period_exceeded?).to be true
    end

    it "returns false within grace period" do
      recent_ts = (Time.now.utc - Clacky::BrandConfig::HEARTBEAT_INTERVAL - 60).iso8601
      config = described_class.new("license_last_heartbeat" => recent_ts)
      expect(config.grace_period_exceeded?).to be false
    end
  end

  # ── #save ─────────────────────────────────────────────────────────────────

  describe "#save" do
    it "writes product_name and package_name to brand.yml" do
      with_temp_brand_file do |brand_file|
        config = described_class.new("product_name" => "JohnAI", "package_name" => "johncli")
        config.save
        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["product_name"]).to eq("JohnAI")
        expect(saved["package_name"]).to eq("johncli")
      end
    end

    it "sets file permissions to 0600" do
      with_temp_brand_file do |brand_file|
        described_class.new("product_name" => "Test").save
        mode = File.stat(brand_file).mode & 0o777
        expect(mode).to eq(0o600)
      end
    end

    it "omits nil fields from the saved YAML" do
      with_temp_brand_file do |brand_file|
        described_class.new("product_name" => "Test").save
        saved = YAML.safe_load(File.read(brand_file))
        expect(saved.key?("license_key")).to be false
        expect(saved.key?("device_id")).to be false
      end
    end
  end

  # ── #activate_mock! ───────────────────────────────────────────────────────

  describe "#activate_mock!" do
    it "stores the license key and sets timestamps without hitting the API" do
      with_temp_brand_file do
        config = described_class.new("product_name" => "JohnAI")
        result = config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        expect(result[:success]).to be true
        # product_name is always derived fresh from the key (user_id 0x2A = 42 → Brand42)
        expect(result[:product_name]).to eq("Brand42")
        expect(config.activated?).to be true
        expect(config.expired?).to be false
        expect(config.license_expires_at).to be > Time.now
      end
    end

    it "derives product_name from the key's first segment regardless of existing product_name" do
      with_temp_brand_file do
        # 0x00000001 = 1 → Brand1
        config = described_class.new("product_name" => "OldBrand")
        result = config.activate_mock!("00000001-FFFFFFFF-DEADBEEF-CAFEBABE-00000001")

        expect(result[:product_name]).to eq("Brand1")
        expect(config.product_name).to eq("Brand1")

        # 0x0000002A = 42 → Brand42
        result2 = config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        expect(result2[:product_name]).to eq("Brand42")
        expect(config.product_name).to eq("Brand42")
      end
    end

    it "persists product_name derived from key to brand.yml" do
      with_temp_brand_file do |brand_file|
        config = described_class.new("product_name" => "TestBrand")
        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["license_key"]).to eq("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        expect(saved["product_name"]).to eq("Brand42")
      end
    end
  end

  # ── #to_h ─────────────────────────────────────────────────────────────────

  describe "#to_h" do
    it "returns correct keys" do
      config = described_class.new("product_name" => "AcmeCLI")
      h = config.to_h
      expect(h).to include(
        product_name: "AcmeCLI",
        branded:      true,
        activated:    false,
        expired:      false
      )
    end
  end
end
