# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::I18n do
  around do |example|
    original_thread = Thread.current[:lang]
    original_env = ENV.to_h.slice("LC_ALL", "LC_MESSAGES", "LANG")
    Thread.current[:lang] = nil
    # Environment variables must be cleared too: an exported LC_ALL overrides
    # LANG, which is exactly the precedence the implementation follows.
    %w[LC_ALL LC_MESSAGES LANG].each { |key| ENV.delete(key) }
    example.run
  ensure
    Thread.current[:lang] = original_thread
    %w[LC_ALL LC_MESSAGES LANG].each do |key|
      ENV.delete(key)
      ENV[key] = original_env[key] if original_env.key?(key)
    end
  end

  describe ".tool_progress" do
    it "uses the Chinese phrase under the zh locale" do
      Thread.current[:lang] = "zh"

      expect(described_class.tool_progress("terminal")).to eq("正在执行命令...")
    end

    it "uses the English phrase under the en locale" do
      Thread.current[:lang] = "en"

      expect(described_class.tool_progress("terminal")).to eq("Running command...")
    end

    it "matches tool names case-insensitively" do
      Thread.current[:lang] = "zh"

      expect(described_class.tool_progress("Web_Search")).to eq("正在联网搜索...")
    end

    it "falls back to a generic phrase naming the tool" do
      Thread.current[:lang] = "zh"

      expect(described_class.tool_progress("some_new_tool")).to eq("正在执行 some_new_tool...")
    end

    it "has a translated phrase for every tool in PROGRESS_TOOLS" do
      described_class::PROGRESS_TOOLS.each do |tool|
        key = "progress.tool.#{tool}"

        expect(Clacky::Locales::EN).to have_key(key), "missing #{key} in EN table"
        expect(Clacky::Locales::ZH).to have_key(key), "missing #{key} in ZH table"
      end
    end

    it "translates into every locale at once for IM cards" do
      expect(described_class.tool_progress_translations("terminal")).to eq(
        "en" => "Running command...",
        "zh" => "正在执行命令..."
      )
    end
  end

  describe ".locale" do
    it "prefers the thread locale over the environment" do
      Thread.current[:lang] = "zh"
      ENV["LANG"] = "en_US.UTF-8"

      expect(described_class.locale).to eq("zh")
    end

    it "detects Chinese from the environment" do
      ENV["LANG"] = "zh_CN.UTF-8"

      expect(described_class.locale).to eq("zh")
    end

    it "ignores an empty LC_ALL instead of masking LANG" do
      ENV["LC_ALL"] = ""
      ENV["LANG"] = "zh_CN.UTF-8"

      expect(described_class.locale).to eq("zh")
    end

    it "accepts a regional variant from the client even when the host is English" do
      Thread.current[:lang] = "zh-CN"
      ENV["LANG"] = "C"

      expect(described_class.locale).to eq("zh")
    end

    it "ignores an unsupported thread locale" do
      Thread.current[:lang] = "fr"
      ENV["LANG"] = "zh_CN.UTF-8"

      expect(described_class.locale).to eq("zh")
    end

    it "defaults to English when the environment is not Chinese" do
      ENV["LANG"] = "C"

      expect(described_class.locale).to eq("en")
    end
  end

  describe ".supported?" do
    it "accepts every locale with a translation table" do
      expect(described_class.supported?("en")).to be(true)
      expect(described_class.supported?("zh")).to be(true)
    end

    it "rejects unknown locales" do
      expect(described_class.supported?("fr")).to be(false)
      expect(described_class.supported?("")).to be(false)
      expect(described_class.supported?(nil)).to be(false)
    end
  end

  describe ".normalize" do
    it "returns a supported code unchanged" do
      expect(described_class.normalize("zh")).to eq("zh")
      expect(described_class.normalize("en")).to eq("en")
    end

    it "strips surrounding whitespace" do
      expect(described_class.normalize("  zh ")).to eq("zh")
    end

    it "collapses regional variants onto their base locale" do
      expect(described_class.normalize("zh-CN")).to eq("zh")
      expect(described_class.normalize("zh_TW")).to eq("zh")
      expect(described_class.normalize("ZH")).to eq("zh")
      expect(described_class.normalize("zh_CN.UTF-8")).to eq("zh")
      expect(described_class.normalize("en-US")).to eq("en")
    end

    it "returns nil for blank, unsupported or missing values" do
      expect(described_class.normalize("")).to be_nil
      expect(described_class.normalize("   ")).to be_nil
      expect(described_class.normalize("fr")).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end
  end
end
