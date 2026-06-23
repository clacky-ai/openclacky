# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/browser_detector"

# Focused on the default-browser identity detection (.default_browser) used by
# the browser-setup skill to see through Chromium-shell browsers (e.g. 360),
# which spoof their UA but cannot fake the OS-registered default-browser id.
RSpec.describe Clacky::Utils::BrowserDetector do
  describe ".classify_default_browser (whitelist matching)" do
    let(:mac_rules) { described_class::DEFAULT_BROWSER_WHITELIST[:macos] }
    let(:win_rules) { described_class::DEFAULT_BROWSER_WHITELIST[:win] }
    let(:linux_rules) { described_class::DEFAULT_BROWSER_WHITELIST[:linux] }

    def classify(id, rules)
      described_class.send(:classify_default_browser, id, rules)
    end

    context "macOS bundle ids (case-insensitive)" do
      it "labels Chrome" do
        expect(classify("com.google.chrome", mac_rules)).to eq("chrome")
        expect(classify("COM.GOOGLE.CHROME", mac_rules)).to eq("chrome")
      end

      it "labels Edge" do
        expect(classify("com.microsoft.edgemac", mac_rules)).to eq("edge")
      end

      it "labels Safari as other" do
        expect(classify("com.apple.safari", mac_rules)).to eq("other")
      end
    end

    context "Windows ProgIDs (case-insensitive)" do
      it "labels Chrome and Edge" do
        expect(classify("ChromeHTML", win_rules)).to eq("chrome")
        expect(classify("MSEdgeHTM", win_rules)).to eq("edge")
      end

      it "labels 360 as other (its real ProgID is exposed, not spoofed)" do
        expect(classify("360seURL", win_rules)).to eq("other")
      end
    end

    context "Linux .desktop names (prefix match)" do
      it "labels Chrome and Edge variants" do
        expect(classify("google-chrome.desktop", linux_rules)).to eq("chrome")
        expect(classify("microsoft-edge-beta.desktop", linux_rules)).to eq("edge")
      end

      it "labels Firefox as other" do
        expect(classify("firefox.desktop", linux_rules)).to eq("other")
      end
    end

    context "missing / blank identity" do
      it "returns unknown for nil or empty" do
        expect(classify(nil, mac_rules)).to eq("unknown")
        expect(classify("", mac_rules)).to eq("unknown")
      end

      it "returns unknown when rules are nil (unsupported OS)" do
        expect(classify("com.google.chrome", nil)).to eq("unknown")
      end
    end
  end

  describe ".default_browser" do
    it "classifies a macOS Chrome default" do
      allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:macos)
      allow(described_class).to receive(:macos_default_browser_id).and_return("com.google.chrome")

      expect(described_class.default_browser).to eq(id: "com.google.chrome", browser: "chrome")
    end

    it "classifies a WSL 360 default as other" do
      allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:wsl)
      allow(described_class).to receive(:win_default_browser_progid).and_return("360seURL")

      expect(described_class.default_browser).to eq(id: "360seURL", browser: "other")
    end

    it "classifies a Linux Edge default" do
      allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:linux)
      allow(described_class).to receive(:linux_default_browser_desktop).and_return("microsoft-edge.desktop")

      expect(described_class.default_browser).to eq(id: "microsoft-edge.desktop", browser: "edge")
    end

    it "returns unknown when identity cannot be read" do
      allow(Clacky::Utils::EnvironmentDetector).to receive(:os_type).and_return(:macos)
      allow(described_class).to receive(:macos_default_browser_id).and_return(nil)

      expect(described_class.default_browser).to eq(id: nil, browser: "unknown")
    end
  end
end
