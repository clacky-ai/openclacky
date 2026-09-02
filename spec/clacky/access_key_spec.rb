# frozen_string_literal: true

require "spec_helper"
require "clacky/access_key"

RSpec.describe Clacky::AccessKey do
  let(:home) { Dir.mktmpdir }

  before do
    allow(Dir).to receive(:home).and_return(home)
    FileUtils.mkdir_p(File.join(home, ".clacky"))
  end

  after { FileUtils.remove_entry(home) if Dir.exist?(home) }

  describe ".from_file" do
    it "returns nil when the file does not exist" do
      expect(described_class.from_file).to be_nil
    end

    it "reads and strips the key" do
      File.write(described_class.key_file, "  file-secret\n")
      expect(described_class.from_file).to eq("file-secret")
    end

    it "returns nil for a blank file" do
      File.write(described_class.key_file, "   \n")
      expect(described_class.from_file).to be_nil
    end
  end

  describe ".resolve" do
    it "prefers the file over the env var" do
      File.write(described_class.key_file, "file-secret\n")
      with_env("CLACKY_ACCESS_KEY" => "env-secret") do
        expect(described_class.resolve).to eq("file-secret")
      end
    end

    it "falls back to the env var when no file exists" do
      with_env("CLACKY_ACCESS_KEY" => "env-secret") do
        expect(described_class.resolve).to eq("env-secret")
      end
    end

    it "returns nil when neither source is set" do
      with_env("CLACKY_ACCESS_KEY" => "") do
        expect(described_class.resolve).to be_nil
      end
    end
  end

  describe ".write" do
    it "persists the key with owner-only permissions" do
      described_class.write("new-secret")

      expect(File.read(described_class.key_file).strip).to eq("new-secret")
      expect(File.stat(described_class.key_file).mode & 0o777).to eq(0o600)
    end

    it "round-trips through resolve" do
      described_class.write("rotated")
      expect(described_class.resolve).to eq("rotated")
    end

    it "rejects a blank key" do
      expect { described_class.write("  ") }.to raise_error(ArgumentError)
    end
  end

  describe ".generate" do
    it "returns a 64-char hex string" do
      expect(described_class.generate).to match(/\A[0-9a-f]{64}\z/)
    end

    it "returns a different value each call" do
      expect(described_class.generate).not_to eq(described_class.generate)
    end
  end
end
