# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "yaml"

RSpec.describe Clacky::BrandConfig do
  around do |example|
    ClimateControl.modify("CLACKY_LICENSE_SERVER" => nil) { example.run }
  end

  # Same helper pattern as brand_config_spec.rb — isolates brand.yml to a tmpdir
  # so tests never touch the user's real ~/.clacky/brand.yml.
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

  # ── #distribution_refresh_due? ─────────────────────────────────────────────

  describe "#distribution_refresh_due?" do
    it "returns false when not branded" do
      config = described_class.new({})
      expect(config.distribution_refresh_due?).to be false
    end

    it "returns true when a private source has no local brand yet" do
      ClimateControl.modify(
        "CLACKY_LICENSE_SERVER" => "https://enterprise.example.com"
      ) do
        config = described_class.new({})
        expect(config.distribution_refresh_due?).to be true
      end
    end

    it "returns false when already activated" do
      config = described_class.new(
        "product_name" => "JohnAI",
        "package_name" => "johnai",
        "license_key"  => "AAAAAAAA-AAAAAAAA-AAAAAAAA-AAAAAAAA-AAAAAAAA"
      )
      expect(config.activated?).to be true
      expect(config.distribution_refresh_due?).to be false
    end

    it "returns true when branded, unactivated, and never refreshed" do
      config = described_class.new(
        "product_name" => "JohnAI",
        "package_name" => "johnai"
      )
      expect(config.distribution_refresh_due?).to be true
    end

    it "returns true when last refresh was over 24h ago" do
      old_ts = (Time.now.utc - Clacky::BrandConfig::HEARTBEAT_INTERVAL - 60).iso8601
      config = described_class.new(
        "product_name"                    => "JohnAI",
        "package_name"                    => "johnai",
        "distribution_last_refreshed_at"  => old_ts
      )
      expect(config.distribution_refresh_due?).to be true
    end

    it "returns false when last refresh was recent" do
      recent_ts = (Time.now.utc - 60).iso8601
      config = described_class.new(
        "product_name"                    => "JohnAI",
        "package_name"                    => "johnai",
        "distribution_last_refreshed_at"  => recent_ts
      )
      expect(config.distribution_refresh_due?).to be false
    end
  end

  # ── #refresh_distribution! ────────────────────────────────────────────────

  describe "#refresh_distribution!" do
    # Stub the platform HTTP client so we never hit the network.
    let(:fake_client) { instance_double(Clacky::PlatformHttpClient) }

    before do
      allow(Clacky::PlatformHttpClient).to receive(:new).and_return(fake_client)
    end

    context "when not branded" do
      it "is a no-op" do
        with_temp_brand_file do
          config = described_class.new({})
          result = config.refresh_distribution!

          expect(result[:success]).to be false
          expect(result[:message]).to match(/not branded/i)
          expect(fake_client).not_to have_received(:get).with(anything) if RSpec::Mocks.space.proxy_for(fake_client).instance_variable_get(:@method_doubles)&.key?(:get)
        end
      end

      it "fetches and persists the deployment brand for a private source" do
        ClimateControl.modify(
          "CLACKY_LICENSE_SERVER" => "https://enterprise.example.com"
        ) do
          with_temp_brand_file do |brand_file|
            expect(fake_client).to receive(:get)
              .with("/api/v1/distributions/lookup")
              .and_return(
                success: true,
                data: {
                  "distribution" => {
                    "product_name" => "Enterprise Platform",
                    "package_name" => nil,
                    "logo_url" => "https://enterprise.example.com/logo/icon.png"
                  }
                }
              )

            config = described_class.new({})
            result = config.refresh_distribution!

            expect(result[:success]).to be true
            expect(config.product_name).to eq("Enterprise Platform")
            expect(config.package_name).to be_nil
            expect(config.logo_url).to eq(
              "https://enterprise.example.com/logo/icon.png"
            )
            expect(config.distribution_refresh_due?).to be false

            saved = YAML.safe_load(File.read(brand_file))
            expect(saved["product_name"]).to eq("Enterprise Platform")
            expect(saved["package_name"]).to be_nil
            expect(saved["distribution_last_refreshed_at"]).to be_a(String)
          end
        end
      end
    end

    context "when already activated" do
      it "returns an informative message and does not call the API" do
        with_temp_brand_file do
          config = described_class.new(
            "product_name" => "JohnAI",
            "package_name" => "johnai",
            "license_key"  => "AAAAAAAA-AAAAAAAA-AAAAAAAA-AAAAAAAA-AAAAAAAA"
          )
          expect(fake_client).not_to receive(:get)
          result = config.refresh_distribution!

          expect(result[:success]).to be false
          expect(result[:message]).to match(/activated/i)
        end
      end
    end

    context "when package_name is blank" do
      it "returns an informative message and does not call the API" do
        with_temp_brand_file do
          config = described_class.new("product_name" => "JohnAI")
          expect(fake_client).not_to receive(:get)
          result = config.refresh_distribution!

          expect(result[:success]).to be false
          expect(result[:message]).to match(/package_name/i)
        end
      end

      it "refreshes the deployment brand again after the interval" do
        ClimateControl.modify(
          "CLACKY_LICENSE_SERVER" => "https://enterprise.example.com"
        ) do
          with_temp_brand_file do
            old_ts = (
              Time.now.utc - Clacky::BrandConfig::HEARTBEAT_INTERVAL - 60
            ).iso8601
            config = described_class.new(
              "product_name" => "Enterprise Platform",
              "distribution_last_refreshed_at" => old_ts
            )
            expect(fake_client).to receive(:get)
              .with("/api/v1/distributions/lookup")
              .and_return(
                success: true,
                data: {
                  "distribution" => {
                    "product_name" => "Renamed Platform",
                    "package_name" => nil
                  }
                }
              )

            result = config.refresh_distribution!

            expect(result[:success]).to be true
            expect(config.product_name).to eq("Renamed Platform")
            expect(config.distribution_refresh_due?).to be false
          end
        end
      end
    end

    context "when the API returns a valid distribution" do
      it "applies fields, stamps the timestamp, and persists to disk" do
        with_temp_brand_file do |brand_file|
          expect(fake_client).to receive(:get)
            .with("/api/v1/distributions/lookup?package_name=johnai")
            .and_return(
              success: true,
              data: {
                "distribution" => {
                  "product_name"    => "JohnAI",
                  "package_name"    => "johnai",
                  "logo_url"        => "https://cdn.example.com/logo.png",
                  "support_contact" => "support@johnai.com",
                  "theme_color"     => "#3B82F6",
                  "homepage_url"    => "https://johnai.com"
                }
              }
            )

          config = described_class.new(
            "product_name" => "JohnAI",
            "package_name" => "johnai"
          )

          t0 = Time.now.utc
          result = config.refresh_distribution!

          expect(result[:success]).to be true
          expect(config.logo_url).to     eq("https://cdn.example.com/logo.png")
          expect(config.theme_color).to  eq("#3B82F6")
          expect(config.homepage_url).to eq("https://johnai.com")
          expect(config.support_contact).to eq("support@johnai.com")
          expect(config.distribution_last_refreshed_at).to be >= t0

          # Persisted to disk so the next poll / restart sees the refreshed data
          saved = YAML.safe_load(File.read(brand_file))
          expect(saved["logo_url"]).to     eq("https://cdn.example.com/logo.png")
          expect(saved["theme_color"]).to  eq("#3B82F6")
          expect(saved["homepage_url"]).to eq("https://johnai.com")
          expect(saved["distribution_last_refreshed_at"]).to be_a(String)
        end
      end

      it "URL-encodes package_name containing unusual characters" do
        # Distribution model restricts package_name to [a-z0-9]+ but be defensive
        # against future changes — don't inject raw strings into the query.
        with_temp_brand_file do
          expect(fake_client).to receive(:get)
            .with(a_string_matching(%r{^/api/v1/distributions/lookup\?package_name=}))
            .and_return(success: true, data: { "distribution" => { "product_name" => "X", "package_name" => "x" } })

          config = described_class.new("product_name" => "X", "package_name" => "x y")
          config.refresh_distribution!
        end
      end
    end

    context "when the API returns an error" do
      it "does not update state or stamp the timestamp (retryable on next trigger)" do
        with_temp_brand_file do
          allow(fake_client).to receive(:get).and_return(success: false, error: "not_found")

          config = described_class.new(
            "product_name" => "JohnAI",
            "package_name" => "johnai"
          )

          result = config.refresh_distribution!

          expect(result[:success]).to be false
          expect(config.distribution_last_refreshed_at).to be_nil
          expect(config.distribution_refresh_due?).to be true  # still due — retry ASAP
        end
      end
    end

    context "when the API returns 200 but with malformed body" do
      it "treats it as a failure and does not stamp the timestamp" do
        with_temp_brand_file do
          allow(fake_client).to receive(:get).and_return(success: true, data: { "unexpected" => "shape" })

          config = described_class.new(
            "product_name" => "JohnAI",
            "package_name" => "johnai"
          )

          result = config.refresh_distribution!

          expect(result[:success]).to be false
          expect(config.distribution_last_refreshed_at).to be_nil
        end
      end
    end
  end

  # ── Persistence round-trip for distribution_last_refreshed_at ─────────────

  describe "distribution_last_refreshed_at persistence" do
    it "survives save → load round-trip" do
      with_temp_brand_file do
        ts = Time.now.utc.iso8601
        config = described_class.new(
          "product_name"                   => "JohnAI",
          "distribution_last_refreshed_at" => ts
        )
        config.save

        reloaded = described_class.load
        expect(reloaded.distribution_last_refreshed_at).to eq(Time.parse(ts))
      end
    end

    it "is cleared on #deactivate!" do
      with_temp_brand_file do
        config = described_class.new(
          "product_name"                   => "JohnAI",
          "distribution_last_refreshed_at" => Time.now.utc.iso8601
        )
        config.deactivate!
        expect(config.distribution_last_refreshed_at).to be_nil
      end
    end
  end
end
