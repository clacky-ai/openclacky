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
          expect(config.brand_name).to be_nil
        end
      end
    end

    context "when brand.yml exists with a brand_name" do
      it "loads brand_name" do
        with_temp_brand_file("brand_name" => "JohnAI") do
          config = described_class.load
          expect(config.branded?).to be true
          expect(config.brand_name).to eq("JohnAI")
        end
      end

      it "loads brand_command" do
        with_temp_brand_file("brand_name" => "JohnAI", "brand_command" => "johncli") do
          config = described_class.load
          expect(config.brand_command).to eq("johncli")
        end
      end

      it "loads license fields" do
        data = {
          "brand_name"            => "JohnAI",
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
    it "returns false when brand_name is nil" do
      config = described_class.new({})
      expect(config.branded?).to be false
    end

    it "returns false when brand_name is blank" do
      config = described_class.new("brand_name" => "  ")
      expect(config.branded?).to be false
    end

    it "returns true when brand_name is present" do
      config = described_class.new("brand_name" => "AcmeCLI")
      expect(config.branded?).to be true
    end
  end

  # ── #activated? ───────────────────────────────────────────────────────────

  describe "#activated?" do
    it "returns false when license_key is absent" do
      config = described_class.new("brand_name" => "X")
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
    it "writes brand_name and brand_command to brand.yml" do
      with_temp_brand_file do |brand_file|
        config = described_class.new("brand_name" => "JohnAI", "brand_command" => "johncli")
        config.save
        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["brand_name"]).to eq("JohnAI")
        expect(saved["brand_command"]).to eq("johncli")
      end
    end

    it "sets file permissions to 0600" do
      with_temp_brand_file do |brand_file|
        described_class.new("brand_name" => "Test").save
        mode = File.stat(brand_file).mode & 0o777
        expect(mode).to eq(0o600)
      end
    end

    it "omits nil fields from the saved YAML" do
      with_temp_brand_file do |brand_file|
        described_class.new("brand_name" => "Test").save
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
        config = described_class.new("brand_name" => "JohnAI")
        result = config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        expect(result[:success]).to be true
        # brand_name is always derived fresh from the key (user_id 0x2A = 42 → Brand42)
        expect(result[:brand_name]).to eq("Brand42")
        expect(config.activated?).to be true
        expect(config.expired?).to be false
        expect(config.license_expires_at).to be > Time.now
      end
    end

    it "derives brand_name from the key's first segment regardless of existing brand_name" do
      with_temp_brand_file do
        # 0x00000001 = 1 → Brand1
        config = described_class.new("brand_name" => "OldBrand")
        result = config.activate_mock!("00000001-FFFFFFFF-DEADBEEF-CAFEBABE-00000001")

        expect(result[:brand_name]).to eq("Brand1")
        expect(config.brand_name).to eq("Brand1")

        # 0x0000002A = 42 → Brand42
        result2 = config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        expect(result2[:brand_name]).to eq("Brand42")
        expect(config.brand_name).to eq("Brand42")
      end
    end

    it "persists brand_name derived from key to brand.yml" do
      with_temp_brand_file do |brand_file|
        config = described_class.new("brand_name" => "TestBrand")
        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["license_key"]).to eq("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        expect(saved["brand_name"]).to eq("Brand42")
      end
    end
  end

  # ── #to_h ─────────────────────────────────────────────────────────────────

  describe "#to_h" do
    it "returns correct keys" do
      config = described_class.new("brand_name" => "AcmeCLI")
      h = config.to_h
      expect(h).to include(
        brand_name: "AcmeCLI",
        branded:    true,
        activated:  false,
        expired:    false
      )
    end

    context "when local cached assets exist" do
      it "returns local route for logo_url when logo_local file is present" do
        with_temp_brand_file do
          assets_dir = File.join(Clacky::BrandConfig::CONFIG_DIR, "brand_assets")
          FileUtils.mkdir_p(assets_dir)
          File.write(File.join(assets_dir, "logo.png"), "fakepng")

          config = described_class.new(
            "brand_name"  => "AcmeCLI",
            "logo_url"    => "https://example.com/logo.png",
            "logo_local"  => "logo.png"
          )
          h = config.to_h
          expect(h[:logo_url]).to eq("/api/brand/assets/logo.png")
        end
      end

      it "falls back to remote logo_url when local file is missing" do
        with_temp_brand_file do
          config = described_class.new(
            "brand_name" => "AcmeCLI",
            "logo_url"   => "https://example.com/logo.png",
            "logo_local" => "logo.png"  # filename set but file not on disk
          )
          h = config.to_h
          expect(h[:logo_url]).to eq("https://example.com/logo.png")
        end
      end

      it "returns local route for support_qr_url when support_qr_local file is present" do
        with_temp_brand_file do
          assets_dir = File.join(Clacky::BrandConfig::CONFIG_DIR, "brand_assets")
          FileUtils.mkdir_p(assets_dir)
          File.write(File.join(assets_dir, "support_qr.png"), "fakepng")

          config = described_class.new(
            "brand_name"       => "AcmeCLI",
            "support_qr_url"   => "https://example.com/qr.png",
            "support_qr_local" => "support_qr.png"
          )
          h = config.to_h
          expect(h[:support_qr_url]).to eq("/api/brand/assets/support_qr.png")
        end
      end

      it "falls back to remote support_qr_url when local file is missing" do
        with_temp_brand_file do
          config = described_class.new(
            "brand_name"       => "AcmeCLI",
            "support_qr_url"   => "https://example.com/qr.png",
            "support_qr_local" => "support_qr.png"
          )
          h = config.to_h
          expect(h[:support_qr_url]).to eq("https://example.com/qr.png")
        end
      end
    end

    context "when no local cached assets exist" do
      it "returns remote logo_url directly" do
        config = described_class.new(
          "brand_name" => "AcmeCLI",
          "logo_url"   => "https://example.com/logo.png"
        )
        expect(config.to_h[:logo_url]).to eq("https://example.com/logo.png")
      end

      it "returns remote support_qr_url directly" do
        config = described_class.new(
          "brand_name"     => "AcmeCLI",
          "support_qr_url" => "https://example.com/qr.png"
        )
        expect(config.to_h[:support_qr_url]).to eq("https://example.com/qr.png")
      end
    end
  end

  # ── #startup_sync_async! ──────────────────────────────────────────────────

  describe "#startup_sync_async!" do
    def activated_brand(tmp_dir)
      described_class.new(
        "brand_name"           => "AcmeCLI",
        "license_key"          => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
        "license_expires_at"   => "2099-01-01T00:00:00Z",
        "license_activated_at" => "2025-01-01T00:00:00Z",
        "device_id"            => "dev-abc"
      )
    end

    context "when license is not activated" do
      it "returns nil without spawning a thread" do
        config = described_class.new("brand_name" => "AcmeCLI")
        result = config.startup_sync_async!
        expect(result).to be_nil
      end
    end

    context "when CLACKY_TEST=1" do
      around { |ex| ClimateControl.modify(CLACKY_TEST: "1") { ex.run } rescue ex.run }

      it "returns nil without spawning a thread" do
        # set env directly since ClimateControl may not be available
        orig = ENV["CLACKY_TEST"]
        ENV["CLACKY_TEST"] = "1"
        config = activated_brand(nil)
        result = config.startup_sync_async!
        expect(result).to be_nil
      ensure
        ENV["CLACKY_TEST"] = orig
      end
    end

    context "when activated and CLACKY_TEST unset" do
      around do |ex|
        orig = ENV["CLACKY_TEST"]
        ENV.delete("CLACKY_TEST")
        ex.run
      ensure
        ENV["CLACKY_TEST"] = orig
      end

      it "calls heartbeat! then fetch_brand_skills! in the background thread" do
        with_temp_brand_file do |brand_file|
          config = activated_brand(nil)
          heartbeat_called    = false
          fetch_skills_called = false

          allow(config).to receive(:heartbeat!) do
            heartbeat_called = true
            { success: true }
          end
          allow(config).to receive(:fetch_brand_skills!) do
            fetch_skills_called = true
            { success: false, skills: [] }   # no skills to install
          end

          thread = config.startup_sync_async!
          expect(thread).to be_a(Thread)
          thread.join(5)   # wait up to 5s for background work to complete

          expect(heartbeat_called).to be true
          expect(fetch_skills_called).to be true
        end
      end

      it "proceeds to fetch_brand_skills! even when heartbeat! raises" do
        with_temp_brand_file do
          config = activated_brand(nil)
          fetch_skills_called = false

          allow(config).to receive(:heartbeat!).and_raise(StandardError, "network down")
          allow(config).to receive(:fetch_brand_skills!) do
            fetch_skills_called = true
            { success: false, skills: [] }
          end

          thread = config.startup_sync_async!
          thread.join(5)

          expect(fetch_skills_called).to be true
        end
      end

      it "heartbeat! is called unconditionally (no heartbeat_due? gate)" do
        with_temp_brand_file do
          config = activated_brand(nil)
          # Simulate a very recent heartbeat — heartbeat_due? would return false
          config.instance_variable_set(:@license_last_heartbeat, Time.now.utc)

          heartbeat_called = false
          allow(config).to receive(:heartbeat!) { heartbeat_called = true; { success: true } }
          allow(config).to receive(:fetch_brand_skills!).and_return({ success: false, skills: [] })

          thread = config.startup_sync_async!
          thread.join(5)

          expect(heartbeat_called).to be true
        end
      end
    end
  end

  # ── #save — local asset fields ─────────────────────────────────────────────

  describe "#save (local asset fields)" do
    it "persists logo_local and support_qr_local to brand.yml" do
      with_temp_brand_file do |brand_file|
        config = described_class.new(
          "brand_name"       => "AcmeCLI",
          "logo_local"       => "logo.png",
          "support_qr_local" => "support_qr.png"
        )
        config.save

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["logo_local"]).to eq("logo.png")
        expect(saved["support_qr_local"]).to eq("support_qr.png")
      end
    end

    it "omits logo_local and support_qr_local when nil" do
      with_temp_brand_file do |brand_file|
        config = described_class.new("brand_name" => "AcmeCLI")
        config.save

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved).not_to have_key("logo_local")
        expect(saved).not_to have_key("support_qr_local")
      end
    end
  end
end
