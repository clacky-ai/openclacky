# frozen_string_literal: true

require "spec_helper"
require "cgi"
require "clacky/utils/environment_detector"

RSpec.describe Clacky::Utils::EnvironmentDetector do
  described = Clacky::Utils::EnvironmentDetector

  describe ".win_to_linux_path" do
    context "on WSL" do
      before { allow(described).to receive(:os_type).and_return(:wsl) }

      it "converts a plain drive-letter path to /mnt" do
        expect(described.win_to_linux_path("C:/Users/foo/a.png"))
          .to eq("/mnt/c/Users/foo/a.png")
      end

      it "converts the leading-slash drive-letter form (file:// three-slash stripped)" do
        expect(described.win_to_linux_path("/C:/Users/foo/a.png"))
          .to eq("/mnt/c/Users/foo/a.png")
      end

      it "converts backslash-separated Windows paths" do
        expect(described.win_to_linux_path("D:\\a\\b.png"))
          .to eq("/mnt/d/a/b.png")
      end

      it "lower-cases the drive letter" do
        expect(described.win_to_linux_path("E:/x")).to eq("/mnt/e/x")
      end

      it "leaves a real Linux path unchanged" do
        expect(described.win_to_linux_path("/mnt/c/x.png")).to eq("/mnt/c/x.png")
        expect(described.win_to_linux_path("/home/u/x.png")).to eq("/home/u/x.png")
      end
    end

    %i[macos linux unknown].each do |os|
      context "on #{os} (non-WSL must be a pure no-op)" do
        before { allow(described).to receive(:os_type).and_return(os) }

        it "returns drive-letter paths unchanged" do
          expect(described.win_to_linux_path("C:/Users/x.png")).to eq("C:/Users/x.png")
          expect(described.win_to_linux_path("/C:/Users/x.png")).to eq("/C:/Users/x.png")
        end

        it "returns Linux/macOS paths unchanged" do
          expect(described.win_to_linux_path("/Users/jiujiu/a.png")).to eq("/Users/jiujiu/a.png")
        end
      end
    end
  end

  describe ".resolve_local_path" do
    context "on WSL" do
      before { allow(described).to receive(:os_type).and_return(:wsl) }

      it "resolves a file:// three-slash drive-letter URL to /mnt" do
        expect(described.resolve_local_path("file:///C:/Users/foo/a.png"))
          .to eq("/mnt/c/Users/foo/a.png")
      end

      it "resolves a bare drive-letter path to /mnt" do
        expect(described.resolve_local_path("C:/Users/foo/a.png"))
          .to eq("/mnt/c/Users/foo/a.png")
      end

      it "percent-decodes before normalizing" do
        expect(described.resolve_local_path("file:///C:/Users/%E4%B8%AD%E6%96%87.png"))
          .to eq("/mnt/c/Users/中文.png")
      end

      it "passes through an existing /mnt path" do
        expect(described.resolve_local_path("file:///mnt/c/x.png")).to eq("/mnt/c/x.png")
      end
    end

    context "on macOS (non-WSL: strip + unescape + expand only)" do
      before { allow(described).to receive(:os_type).and_return(:macos) }

      it "strips file:// and expands an absolute path" do
        expect(described.resolve_local_path("file:///Users/jiujiu/a.png"))
          .to eq("/Users/jiujiu/a.png")
      end

      it "percent-decodes spaces and non-ASCII" do
        expect(described.resolve_local_path("file:///Users/jiujiu/b%20c.png"))
          .to eq("/Users/jiujiu/b c.png")
        expect(described.resolve_local_path("/Users/jiujiu/%E4%B8%AD.png"))
          .to eq("/Users/jiujiu/中.png")
      end

      it "does NOT convert Windows drive letters (no /mnt on macOS)" do
        expect(described.resolve_local_path("file:///C:/Users/x.png"))
          .to eq("/C:/Users/x.png")
      end

      it "expands ~ to the home directory" do
        expect(described.resolve_local_path("file://~/a.png"))
          .to eq(File.expand_path("~/a.png"))
      end
    end
  end
end
