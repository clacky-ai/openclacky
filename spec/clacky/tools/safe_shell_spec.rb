# frozen_string_literal: true

RSpec.describe Clacky::Tools::SafeShell do
  let(:tool) { described_class.new }

  describe "#execute" do
    context "output truncation" do
      it "does not truncate short output" do
        result = tool.execute(command: "echo 'Line 1\nLine 2\nLine 3'", max_output_lines: 10)

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be false
        expect(result[:stdout].lines.count).to be <= 10
      end

      it "truncates long output when exceeding max_output_lines" do
        # Generate command that outputs many lines
        result = tool.execute(command: "seq 1 500", max_output_lines: 100)

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be true
        # Should be truncated to ~100 lines plus truncation notice
        expect(result[:stdout].lines.count).to be <= 105
        expect(result[:stdout]).to include("Output truncated")
      end

      it "uses default max_output_lines of 1000 when not specified" do
        # Generate more than 1000 lines
        result = tool.execute(command: "seq 1 2000")

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be true
        # Should be truncated to ~1000 lines plus truncation notice
        expect(result[:stdout].lines.count).to be <= 1005
      end

      it "handles empty output" do
        result = tool.execute(command: "echo -n ''", max_output_lines: 10)

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:output_truncated]).to be false
      end
    end

    context "security features" do
      it "makes dangerous rm command safe" do
        result = tool.execute(command: "rm nonexistent_file.txt")

        # Should replace rm with mv to trash
        expect(result[:security_enhanced]).to be true
        expect(result[:safe_command]).to include("mv")
      end

      it "allows safe read-only commands without modification" do
        result = tool.execute(command: "ls -la")

        expect(result[:exit_code]).to eq(0)
        expect(result[:success]).to be true
        expect(result[:security_enhanced]).to be_falsy
      end
    end
  end

  describe ".command_safe_for_auto_execution?" do
    it "returns true for safe read-only commands" do
      expect(described_class.command_safe_for_auto_execution?("ls -la")).to be true
      expect(described_class.command_safe_for_auto_execution?("pwd")).to be true
      expect(described_class.command_safe_for_auto_execution?("echo hello")).to be true
    end

    it "returns false for dangerous commands" do
      expect(described_class.command_safe_for_auto_execution?("sudo apt-get install")).to be false
    end
  end

  describe "#format_call" do
    it "formats command for display" do
      formatted = tool.format_call({ command: "ls -la" })

      expect(formatted).to include("safe_shell")
      expect(formatted).to include("ls -la")
    end

    it "truncates long commands" do
      long_command = "a" * 100
      formatted = tool.format_call({ command: long_command })

      expect(formatted.length).to be < long_command.length + 20
      expect(formatted).to include("...")
    end
  end

  describe "#format_result" do
    it "shows success with line count" do
      result = { exit_code: 0, stdout: "line1\nline2\nline3\n", stderr: "" }
      formatted = tool.format_result(result)

      expect(formatted).to include("✓")
      expect(formatted).to include("lines")
    end

    it "shows security enhancement indicator" do
      result = { exit_code: 0, stdout: "output", stderr: "", security_enhanced: true }
      formatted = tool.format_result(result)

      expect(formatted).to include("🔒")
    end

    it "shows error for failed commands" do
      result = { exit_code: 1, stdout: "", stderr: "Error message" }
      formatted = tool.format_result(result)

      expect(formatted).to include("✗")
      expect(formatted).to include("Exit 1")
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("safe_shell")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("command")
      expect(definition[:function][:parameters][:properties]).to have_key(:max_output_lines)
    end
  end
end
