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

      it "does NOT overwrite brand.yml when the file is corrupt" do
        with_temp_brand_file do |brand_file|
          corrupt = "--- :\n bad: [yaml"
          File.write(brand_file, corrupt)
          described_class.load
          expect(File.read(brand_file)).to eq(corrupt)
        end
      end

      it "does not write to disk from the rescue fallback (no overwrite loop)" do
        with_temp_brand_file do |brand_file|
          File.write(brand_file, "--- :\n bad: [yaml")
          expect_any_instance_of(described_class).not_to receive(:save)
          config = described_class.load
          expect(config.device_id).not_to be_nil
        end
      end
    end
  end

  # ── #save ─────────────────────────────────────────────────────────────────

  describe "#save" do
    it "writes atomically without leaving temp files behind" do
      with_temp_brand_file do |brand_file|
        config = described_class.new("product_name" => "JohnAI", "license_key" => "KEY")
        config.save
        dir = File.dirname(brand_file)
        expect(File.exist?(brand_file)).to be true
        expect(Dir.glob(File.join(dir, "*.tmp"))).to be_empty
      end
    end

    it "persists the config so it round-trips through load" do
      with_temp_brand_file do
        described_class.new("product_name" => "JohnAI", "license_key" => "KEY").save
        reloaded = described_class.load
        expect(reloaded.product_name).to eq("JohnAI")
        expect(reloaded.license_key).to eq("KEY")
      end
    end

    it "writes the file with 0600 permissions" do
      with_temp_brand_file do |brand_file|
        described_class.new("product_name" => "JohnAI").save
        expect(File.stat(brand_file).mode & 0o777).to eq(0o600)
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
    it "returns false when there is no recorded heartbeat failure" do
      config = described_class.new({})
      expect(config.grace_period_exceeded?).to be false
    end

    it "returns false when heartbeat last_heartbeat is old but no failure has been recorded" do
      ancient_ts = (Time.now.utc - (10 * 86_400)).iso8601
      config = described_class.new("license_last_heartbeat" => ancient_ts)
      expect(config.grace_period_exceeded?).to be false
    end

    it "returns true when heartbeats have been failing continuously past the grace period" do
      old_failure = (Time.now.utc - Clacky::BrandConfig::HEARTBEAT_GRACE_PERIOD - 1).iso8601
      config = described_class.new("license_last_heartbeat_failure" => old_failure)
      expect(config.grace_period_exceeded?).to be true
    end

    it "returns false when the failure streak is still within the grace period" do
      recent_failure = (Time.now.utc - 60).iso8601
      config = described_class.new("license_last_heartbeat_failure" => recent_failure)
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

  describe "#deactivate!" do
    it "removes brand.yml and every installed brand Skill" do
      with_temp_brand_file do |brand_file|
        config = described_class.new(
          "product_name" => "Enterprise",
          "license_key" => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4"
        )
        config.save
        skill_dir = File.join(config.brand_skills_dir, "private-skill")
        FileUtils.mkdir_p(skill_dir)
        File.write(File.join(skill_dir, "SKILL.md.enc"), "encrypted")

        result = config.deactivate!

        expect(result).to eq(success: true)
        expect(File).not_to exist(brand_file)
        expect(Dir).not_to exist(config.brand_skills_dir)
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

    it "preserves installed brand skills when re-activating with the same brand identity" do
      with_temp_brand_file do
        config = described_class.new
        # Initial activation — same key derives product_name "Brand42" both times.
        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        expect(config).not_to receive(:clear_brand_skills!)
        config.activate_mock!("0000002A-99999999-DEADBEEF-CAFEBABE-FFFFFFFF")
      end
    end

    it "wipes installed brand skills when switching to a different brand" do
      with_temp_brand_file do
        config = described_class.new
        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")  # Brand42
        expect(config).to receive(:clear_brand_skills!).and_call_original
        config.activate_mock!("00000001-FFFFFFFF-DEADBEEF-CAFEBABE-00000001")  # Brand1
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

  describe "#search_extensions!" do
    let(:config) { described_class.new({}) }
    let(:fake_client) { double("PlatformHttpClient") }

    before { allow(config).to receive(:platform_client).and_return(fake_client) }

    it "returns extensions on success" do
      allow(fake_client).to receive(:get)
        .with("/api/v1/extensions?q=weather&sort=newest")
        .and_return(success: true, data: { "extensions" => [{ "name" => "weather" }] })

      result = config.search_extensions!(query: "weather", sort: "newest")
      expect(result[:success]).to be true
      expect(result[:extensions]).to eq([{ "name" => "weather" }])
    end

    it "omits blank query and sort params" do
      allow(fake_client).to receive(:get)
        .with("/api/v1/extensions")
        .and_return(success: true, data: { "extensions" => [] })

      result = config.search_extensions!(query: "  ", sort: nil)
      expect(result[:success]).to be true
      expect(result[:extensions]).to eq([])
    end

    it "returns error on failure" do
      allow(fake_client).to receive(:get).and_return(success: false, error: "boom")

      result = config.search_extensions!
      expect(result[:success]).to be false
      expect(result[:error]).to eq("boom")
      expect(result[:extensions]).to eq([])
    end

    it "handles network exceptions" do
      allow(fake_client).to receive(:get).and_raise(StandardError.new("timeout"))

      result = config.search_extensions!(query: "x")
      expect(result[:success]).to be false
      expect(result[:error]).to include("Network error")
    end
  end
end
