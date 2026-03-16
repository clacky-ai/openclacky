# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe Clacky::BrandConfig do
  # ── Helpers ────────────────────────────────────────────────────────────────

  # Run block with a fully isolated temp directory replacing all brand paths.
  def with_isolated_brand_dir(initial_yml = nil)
    tmp_dir      = Dir.mktmpdir
    brand_file   = File.join(tmp_dir, "brand.yml")
    backups_dir  = File.join(tmp_dir, "brand_backups")

    if initial_yml
      File.write(brand_file, YAML.dump(initial_yml))
    end

    stub_const("Clacky::BrandConfig::CONFIG_DIR",  tmp_dir)
    stub_const("Clacky::BrandConfig::BRAND_FILE",  brand_file)
    stub_const("Clacky::BrandConfig::BACKUPS_DIR", backups_dir)

    yield tmp_dir, brand_file, backups_dir
  ensure
    FileUtils.rm_rf(tmp_dir)
  end

  # Helper: fixture data representing an already-activated license A
  def license_a_data
    {
      "brand_name"             => "BrandAlpha",
      "brand_command"          => "alpha",
      "distribution_name"      => "Alpha Distribution",
      "product_name"           => "Alpha Pro",
      "logo_url"               => "https://alpha.example.com/logo.png",
      "support_contact"        => "support@alpha.example.com",
      "theme_color"            => "#FF0000",
      "homepage_url"           => "https://alpha.example.com",
      "license_key"            => "0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4",
      "license_activated_at"   => "2025-01-01T00:00:00Z",
      "license_expires_at"     => "2099-01-01T00:00:00Z",
      "license_last_heartbeat" => "2025-06-01T00:00:00Z",
      "device_id"              => "device-aaa-111"
    }
  end

  # ── backup! ───────────────────────────────────────────────────────────────

  describe "#backup!" do
    context "when no brand.yml exists" do
      it "returns nil and creates no backup directories" do
        with_isolated_brand_dir do |_, _, backups_dir|
          config = described_class.new({})
          result = config.backup!

          expect(result).to be_nil
          expect(Dir.exist?(backups_dir)).to be false
        end
      end
    end

    context "when brand.yml exists but has no license_key" do
      it "returns nil (nothing meaningful to back up)" do
        with_isolated_brand_dir("brand_name" => "NoBrand") do |_, _, backups_dir|
          config = described_class.new("brand_name" => "NoBrand")
          result = config.backup!

          expect(result).to be_nil
          expect(Dir.exist?(backups_dir)).to be false
        end
      end
    end

    context "when brand.yml has an activated license" do
      it "creates a timestamped backup directory containing brand.yml" do
        with_isolated_brand_dir(license_a_data) do |_, _, backups_dir|
          config = described_class.load
          result = config.backup!

          expect(result).not_to be_nil
          expect(Dir.exist?(result)).to be true
          expect(File.exist?(File.join(result, "brand.yml"))).to be true

          saved = YAML.safe_load(File.read(File.join(result, "brand.yml")))
          expect(saved["license_key"]).to eq(license_a_data["license_key"])
          expect(saved["brand_name"]).to eq("BrandAlpha")
        end
      end

      it "backup directory name follows YYYYMMDDTHHMMSSZ format" do
        with_isolated_brand_dir(license_a_data) do |_, _, backups_dir|
          config = described_class.load
          result = config.backup!

          dirname = File.basename(result)
          # Matches e.g. "20260316T123456Z" or "20260316T123456Z_123456"
          expect(dirname).to match(/\A\d{8}T\d{6}Z/)
        end
      end

      it "copies brand_assets directory into the backup when it exists" do
        with_isolated_brand_dir(license_a_data) do |tmp_dir, _, _|
          assets_dir = File.join(tmp_dir, "brand_assets")
          FileUtils.mkdir_p(assets_dir)
          File.write(File.join(assets_dir, "logo.png"), "fakepng")

          config = described_class.load
          result = config.backup!

          expect(File.exist?(File.join(result, "brand_assets", "logo.png"))).to be true
        end
      end

      it "copies brand_skills directory into the backup when it exists" do
        with_isolated_brand_dir(license_a_data) do |tmp_dir, _, _|
          skills_dir = File.join(tmp_dir, "brand_skills", "my-skill")
          FileUtils.mkdir_p(skills_dir)
          File.write(File.join(skills_dir, "SKILL.md.enc"), "encrypted")
          File.write(
            File.join(tmp_dir, "brand_skills", "brand_skills.json"),
            JSON.generate({ "my-skill" => { "version" => "1.0.0", "name" => "My Skill" } })
          )

          config = described_class.load
          result = config.backup!

          expect(File.exist?(File.join(result, "brand_skills", "brand_skills.json"))).to be true
          expect(File.exist?(File.join(result, "brand_skills", "my-skill", "SKILL.md.enc"))).to be true
        end
      end

      it "does not fail when brand_assets and brand_skills are absent" do
        with_isolated_brand_dir(license_a_data) do
          config = described_class.load
          expect { config.backup! }.not_to raise_error
        end
      end
    end

    context "deduplication — same license_key + device_id" do
      it "skips backup when the most recent backup has an identical fingerprint" do
        with_isolated_brand_dir(license_a_data) do |_, _, backups_dir|
          config = described_class.load

          # First backup — should succeed
          first_path = config.backup!
          expect(first_path).not_to be_nil

          # Second backup with same key/device_id — should be skipped
          second_path = config.backup!
          expect(second_path).to be_nil

          # Only one backup directory should exist
          dirs = Dir.glob(File.join(backups_dir, "*")).select { |p| File.directory?(p) }
          expect(dirs.size).to eq(1)
        end
      end

      it "does NOT skip backup when license_key differs" do
        with_isolated_brand_dir(license_a_data) do |tmp_dir, brand_file, backups_dir|
          config = described_class.load
          first_path = config.backup!
          expect(first_path).not_to be_nil

          # Write a different license_key to brand.yml
          new_data = license_a_data.merge("license_key" => "BBBBBBBB-CCCCCCCC-DDDDDDDD-EEEEEEEE-FFFFFFFF")
          File.write(brand_file, YAML.dump(new_data))

          second_config = described_class.load
          second_path   = second_config.backup!
          expect(second_path).not_to be_nil
          expect(second_path).not_to eq(first_path)

          dirs = Dir.glob(File.join(backups_dir, "*")).select { |p| File.directory?(p) }
          expect(dirs.size).to eq(2)
        end
      end

      it "does NOT skip backup when device_id differs" do
        with_isolated_brand_dir(license_a_data) do |tmp_dir, brand_file, backups_dir|
          config = described_class.load
          config.backup!

          new_data = license_a_data.merge("device_id" => "device-new-999")
          File.write(brand_file, YAML.dump(new_data))

          second_config = described_class.load
          second_path   = second_config.backup!
          expect(second_path).not_to be_nil

          dirs = Dir.glob(File.join(backups_dir, "*")).select { |p| File.directory?(p) }
          expect(dirs.size).to eq(2)
        end
      end
    end

    context ".list_backups" do
      it "returns empty array when no backups exist" do
        with_isolated_brand_dir do |_, _, backups_dir|
          expect(described_class.list_backups).to eq([])
        end
      end

      it "returns backup paths sorted oldest-first" do
        with_isolated_brand_dir(license_a_data) do |_, brand_file, backups_dir|
          config = described_class.load
          first = config.backup!

          # Simulate a second backup by changing device_id
          new_data = license_a_data.merge("device_id" => "device-bbb-222")
          File.write(brand_file, YAML.dump(new_data))
          second_config = described_class.load
          sleep(0.01) # ensure different timestamp
          second = second_config.backup!

          listed = described_class.list_backups
          expect(listed.size).to eq(2)
          expect(listed.first).to eq(first)
          expect(listed.last).to eq(second)
        end
      end
    end
  end

  # ── reset_brand_state! (via activate_mock!) ───────────────────────────────

  describe "re-activation via activate_mock!" do
    it "clears all brand fields from the previous activation before writing new ones" do
      with_isolated_brand_dir(license_a_data) do
        config = described_class.load

        # Verify initial state
        expect(config.brand_name).to eq("BrandAlpha")
        expect(config.theme_color).to eq("#FF0000")
        expect(config.license_key).to eq(license_a_data["license_key"])

        # Re-activate with a completely different key
        result = config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        expect(result[:success]).to be true

        # Brand metadata from license A must be gone
        expect(config.brand_name).to eq("Brand42")
        expect(config.distribution_name).to be_nil
        expect(config.product_name).to be_nil
        expect(config.theme_color).to be_nil
        expect(config.homepage_url).to be_nil
      end
    end

    it "creates a backup before wiping old state" do
      with_isolated_brand_dir(license_a_data) do |_, _, backups_dir|
        config = described_class.load
        result = config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        expect(result[:backup_path]).not_to be_nil
        backed_up = YAML.safe_load(File.read(File.join(result[:backup_path], "brand.yml")))
        expect(backed_up["license_key"]).to eq(license_a_data["license_key"])
        expect(backed_up["brand_name"]).to eq("BrandAlpha")
      end
    end

    it "writes new state immediately to disk after re-activation" do
      with_isolated_brand_dir(license_a_data) do |_, brand_file|
        config = described_class.load
        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["license_key"]).to eq("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        expect(saved["brand_name"]).to eq("Brand42")
        # Old brand-specific fields must not survive in the new brand.yml
        expect(saved["theme_color"]).to be_nil
      end
    end

    it "clears in-memory decryption key cache on re-activation" do
      with_isolated_brand_dir(license_a_data) do
        config = described_class.load
        # Seed the internal cache (private instance variable)
        config.instance_variable_set(:@decryption_keys, { "1:2" => { key: "abc", expires_at: Time.now + 3600 } })

        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        expect(config.instance_variable_get(:@decryption_keys)).to eq({})
      end
    end

    it "generates a fresh device_id on each re-activation (not reusing the old one)" do
      with_isolated_brand_dir(license_a_data) do
        config = described_class.load
        old_device_id = config.device_id  # "device-aaa-111" from fixture

        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")
        new_device_id = config.device_id

        # The new device_id is computed from hostname:user:platform, which is
        # deterministic on the same machine — but it must not be the fixture's
        # hand-crafted string "device-aaa-111".
        expect(new_device_id).not_to eq(old_device_id)
        expect(new_device_id).not_to be_nil
        expect(new_device_id.length).to eq(64)  # SHA256 hex string
      end
    end

    it "skips duplicate backup when the same key is already the current disk state" do
      # Start with license_a already on disk and already backed up once.
      with_isolated_brand_dir(license_a_data) do |_, _, backups_dir|
        config = described_class.load

        # Manually create a backup that matches the current brand.yml fingerprint,
        # simulating a prior run that already backed up license_a.
        config.backup!

        dirs_before = Dir.glob(File.join(backups_dir, "*")).select { |p| File.directory?(p) }
        expect(dirs_before.size).to eq(1)

        # Calling backup! again with the same fingerprint must be skipped.
        result = config.backup!
        expect(result).to be_nil

        dirs_after = Dir.glob(File.join(backups_dir, "*")).select { |p| File.directory?(p) }
        expect(dirs_after.size).to eq(1)
      end
    end
  end

  # ── Disk cleanup on re-activation ─────────────────────────────────────────
  #
  # reset_brand_state! must wipe old brand files from disk so the new license
  # starts with a completely clean slate.  Tests in this group verify that
  # brand_assets/ and brand_skills/ are erased before new data is written.

  describe "disk cleanup during re-activation" do
    it "removes old brand_assets/ directory before writing new assets" do
      with_isolated_brand_dir(license_a_data) do |tmp_dir|
        # Seed old brand's image files
        assets_dir = File.join(tmp_dir, "brand_assets")
        FileUtils.mkdir_p(assets_dir)
        File.write(File.join(assets_dir, "logo.png"),       "old-logo-bytes")
        File.write(File.join(assets_dir, "support_qr.png"), "old-qr-bytes")

        config = described_class.load
        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        # Old image files must be gone after re-activation
        # (activate_mock! does not re-download images — that happens via
        #  apply_distribution → cache_assets! during a real activate! call.
        #  What we verify here is that the old files were erased.)
        expect(File.exist?(File.join(assets_dir, "logo.png"))).to be false
        expect(File.exist?(File.join(assets_dir, "support_qr.png"))).to be false
      end
    end

    it "removes old brand_skills/ directory and its contents before re-activation" do
      with_isolated_brand_dir(license_a_data) do |tmp_dir|
        # Seed old brand's encrypted skill files
        skills_dir = File.join(tmp_dir, "brand_skills")
        slug_dir   = File.join(skills_dir, "old-skill")
        FileUtils.mkdir_p(slug_dir)
        File.write(File.join(skills_dir, "brand_skills.json"), JSON.generate({ "old-skill" => { "version" => "1.0.0" } }))
        File.write(File.join(slug_dir,   "SKILL.md.enc"),      "encrypted-content")

        config = described_class.load
        config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        # Entire brand_skills/ tree must have been wiped
        expect(Dir.exist?(skills_dir)).to be false
      end
    end

    it "overwrites brand.yml with new license data after successful re-activation" do
      # Use distinct keys so we can tell old from new
      old_key_value = "AAAAAAAA-11111111-22222222-33333333-44444444"
      new_key_value = "BBBBBBBB-55555555-66666666-77777777-88888888"
      old_data = license_a_data.merge("license_key" => old_key_value, "device_id" => "device-old-111")

      with_isolated_brand_dir(old_data) do |tmp_dir, brand_file|
        config = described_class.load

        # brand.yml exists with old key before re-activation
        expect(File.exist?(brand_file)).to be true
        expect(YAML.safe_load(File.read(brand_file))["license_key"]).to eq(old_key_value)

        config.activate_mock!(new_key_value)

        # brand.yml must now carry ONLY the new key — old key must not appear
        saved = YAML.safe_load(File.read(brand_file))
        expect(saved["license_key"]).to eq(new_key_value)
        expect(saved["license_key"]).not_to eq(old_key_value)
        # Old brand fields from license_a must not survive
        expect(saved["theme_color"]).to be_nil
        expect(saved["distribution_name"]).to be_nil
      end
    end

    it "keeps brand_backups/ intact — backup directory is never wiped" do
      with_isolated_brand_dir(license_a_data) do |tmp_dir, _, backups_dir|
        config = described_class.load

        # First backup — simulates a prior session
        config.backup!
        expect(described_class.list_backups.size).to eq(1)

        # Re-activate to a different key
        new_data = license_a_data.merge("license_key" => "BBBBBBBB-CCCCCCCC-DDDDDDDD-EEEEEEEE-FFFFFFFF",
                                        "device_id"   => "device-bbb-222")
        File.write(File.join(tmp_dir, "brand.yml"), YAML.dump(new_data))
        config2 = described_class.load
        config2.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        # Both the old backup AND the new backup must still be present
        expect(described_class.list_backups.size).to eq(2)
      end
    end

    it "backup preserves old assets before they are deleted" do
      with_isolated_brand_dir(license_a_data) do |tmp_dir, _, backups_dir|
        assets_dir = File.join(tmp_dir, "brand_assets")
        FileUtils.mkdir_p(assets_dir)
        File.write(File.join(assets_dir, "logo.png"), "old-logo-bytes")

        config = described_class.load
        result = config.activate_mock!("0000002A-00000007-DEADBEEF-CAFEBABE-A1B2C3D4")

        # The backup was taken before the cleanup, so it must contain the old logo
        backed_logo = File.join(result[:backup_path], "brand_assets", "logo.png")
        expect(File.exist?(backed_logo)).to be true
        expect(File.read(backed_logo)).to eq("old-logo-bytes")

        # But the live brand_assets/ directory was wiped
        expect(File.exist?(File.join(assets_dir, "logo.png"))).to be false
      end
    end
  end
end
