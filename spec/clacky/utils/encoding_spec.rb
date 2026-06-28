# frozen_string_literal: true

RSpec.describe Clacky::Utils::Encoding do
  describe ".cmd_to_utf8" do
    context "with nil or empty input" do
      it "returns empty string for nil" do
        expect(described_class.cmd_to_utf8(nil)).to eq("")
      end

      it "returns empty string for empty string" do
        expect(described_class.cmd_to_utf8("")).to eq("")
      end
    end

    context "with GBK-encoded input (simulating Chinese Windows powershell.exe output)" do
      # "桌面" in GBK: 0xD7 0xC0 0xC3 0xE6
      let(:gbk_desktop) do
        [0xD7, 0xC0, 0xC3, 0xE6].pack("C*").force_encoding("ASCII-8BIT")
      end

      # "C:\Users\张三\Desktop\r\n" — "张三" in GBK: 0xD5 0xC5 0xC8 0xFD
      let(:gbk_path) do
        [
          0x43, 0x3A, 0x5C,                         # C:\
          0x55, 0x73, 0x65, 0x72, 0x73, 0x5C,       # Users\
          0xD5, 0xC5, 0xC8, 0xFD,                   # 张三 (GBK)
          0x5C,                                      # \
          0x44, 0x65, 0x73, 0x6B, 0x74, 0x6F, 0x70, # Desktop
          0x0D, 0x0A                                 # \r\n
        ].pack("C*").force_encoding("ASCII-8BIT")
      end

      it "decodes GBK bytes to correct UTF-8 Chinese characters" do
        result = described_class.cmd_to_utf8(gbk_desktop)
        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result).to eq("桌面")
      end

      it "decodes a full Windows Desktop path containing Chinese username" do
        result = described_class.cmd_to_utf8(gbk_path)
        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result).to include("张三")
        expect(result).to include("C:\\Users\\")
      end

      it "always returns a valid UTF-8 string (no encoding errors on .strip.tr)" do
        result = described_class.cmd_to_utf8(gbk_path)
        expect { result.strip.tr("\r\n", "") }.not_to raise_error
      end
    end

    context "with ASCII-8BIT encoded UTF-8 input (simulating Unix command output)" do
      # wslpath / xdg-user-dir output arrives as ASCII-8BIT but contains valid UTF-8 bytes
      let(:utf8_path) { "/home/用户/Desktop".encode("UTF-8").b }

      it "correctly handles UTF-8 bytes when source_encoding is UTF-8" do
        result = described_class.cmd_to_utf8(utf8_path, source_encoding: "UTF-8")
        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result).to eq("/home/用户/Desktop")
      end
    end

    context "with plain ASCII input (e.g. `which node` output)" do
      let(:ascii_path) { "/usr/local/bin/node\n".b }

      it "passes through ASCII content unchanged" do
        result = described_class.cmd_to_utf8(ascii_path, source_encoding: "UTF-8")
        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result.strip).to eq("/usr/local/bin/node")
      end
    end

    context "return value encoding" do
      it "always returns UTF-8 encoded string" do
        raw = "hello".b
        expect(described_class.cmd_to_utf8(raw).encoding).to eq(Encoding::UTF_8)
      end
    end
  end

  describe ".pty_to_utf8" do
    context "with nil or empty input" do
      it "returns empty string for nil" do
        expect(described_class.pty_to_utf8(nil)).to eq("")
      end

      it "returns empty string for empty string" do
        expect(described_class.pty_to_utf8("")).to eq("")
      end
    end

    context "with UTF-8 bytes (Linux/macOS and modern programs)" do
      it "decodes UTF-8 Chinese unchanged" do
        result = described_class.pty_to_utf8("你好，世界".encode("UTF-8").b)
        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result).to eq("你好，世界")
      end

      it "passes ASCII through unchanged" do
        result = described_class.pty_to_utf8("Hello World\n".b)
        expect(result).to eq("Hello World\n")
      end

      it "preserves multibyte emoji" do
        expect(described_class.pty_to_utf8("OK 完成 ✓".encode("UTF-8").b)).to eq("OK 完成 ✓")
      end
    end

    context "with GBK bytes (Simplified Chinese Windows powershell.exe / cmd.exe)" do
      # Real bytes captured from `powershell.exe -Command "Write-Host '你好，世界'"`
      # on a CP936 host: c4e3 bac3 a3ac cac0 bde7
      let(:gbk_greeting) do
        [0xC4, 0xE3, 0xBA, 0xC3, 0xA3, 0xAC, 0xCA, 0xC0, 0xBD, 0xE7].pack("C*").b
      end

      it "falls back to GBK and decodes correctly" do
        result = described_class.pty_to_utf8(gbk_greeting)
        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result).to eq("你好，世界")
      end

      it "decodes a GBK line with trailing CRLF (cmd.exe form)" do
        bytes = gbk_greeting + [0x0D, 0x0A].pack("C*").b
        result = described_class.pty_to_utf8(bytes)
        expect(result).to eq("你好，世界\r\n")
      end
    end

    context "with genuinely invalid bytes" do
      it "scrubs unrepresentable sequences rather than raising" do
        raw = [0xFF, 0xFE, 0xFD].pack("C*").b
        expect { described_class.pty_to_utf8(raw) }.not_to raise_error
        expect(described_class.pty_to_utf8(raw).encoding).to eq(Encoding::UTF_8)
      end
    end

    context "line-based slicing never splits a multibyte char (PTY \\n boundary)" do
      it "decodes each GBK line correctly when split on \\n" do
        line = [0xC4, 0xE3, 0xBA, 0xC3].pack("C*").b   # 你好 in GBK
        stream = line + "\n".b + line + "\n".b
        decoded = stream.split("\n".b, -1).map { |seg| described_class.pty_to_utf8(seg) }
        expect(decoded[0]).to eq("你好")
        expect(decoded[1]).to eq("你好")
      end
    end
  end

  describe "code audit: all backtick command calls must be wrapped with cmd_to_utf8 or to_utf8" do
    # Core lib files only — exclude default_skills (deploy/channel scripts run in controlled envs)
    CORE_SOURCE_FILES = (
      Dir.glob(File.join(__dir__, "../../../lib/clacky/**/*.rb")) +
      Dir.glob(File.join(__dir__, "../../../lib/*.rb"))
    ).reject { |f| f.include?("/default_skills/") }.sort.freeze

    # Matches a line that contains a backtick shell command (not just inline code docs).
    # Heuristic: backtick pair where content looks like a shell command (contains space or slash or dot).
    BACKTICK_COMMAND_RE = /(?:=\s*`[^`]+`|`[^`]+`\s*\.\s*\w)/.freeze

    # A line (or its neighbours) is considered safe if it references an encoding helper.
    ENCODING_GUARD_RE = /cmd_to_utf8|to_utf8/.freeze

    it "all core source files have no unguarded backtick command calls" do
      expect(CORE_SOURCE_FILES).not_to be_empty

      all_violations = []

      CORE_SOURCE_FILES.each do |path|
        lines = File.readlines(path)
        rel_path = path.sub("#{Dir.pwd}/", "")

        lines.each_with_index do |line, idx|
          next unless line.match?(BACKTICK_COMMAND_RE)
          next if line.strip.start_with?("#")

          window = lines[[idx - 1, 0].max...[idx + 2, lines.size].min].join
          unless window.match?(ENCODING_GUARD_RE)
            all_violations << "  #{rel_path}:#{idx + 1}: #{line.rstrip}"
          end
        end
      end

      expect(all_violations).to be_empty,
        "Found backtick command(s) not wrapped with cmd_to_utf8/to_utf8:\n#{all_violations.join("\n")}"
    end
  end
end
