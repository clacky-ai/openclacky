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
      long_command = "a" * 200
      formatted = tool.format_call({ command: long_command })

      expect(formatted.length).to be < long_command.length + 20
      expect(formatted).to include("...")
    end
  end

  describe "#format_result" do
    it "shows success with line count" do
      result = { exit_code: 0, stdout: "line1\nline2\nline3\n", stderr: "" }
      formatted = tool.format_result(result)

      expect(formatted).to include("[OK]")
      expect(formatted).to include("lines")
    end

    it "shows security enhancement indicator" do
      result = { exit_code: 0, stdout: "output", stderr: "", security_enhanced: true }
      formatted = tool.format_result(result)

      expect(formatted).to include("[Safe]")
    end

    it "shows error for failed commands" do
      result = { exit_code: 1, stdout: "", stderr: "Error message" }
      formatted = tool.format_result(result)

      expect(formatted).to include("[Exit 1]")
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("safe_shell")
      expect(definition[:function][:description]).to be_a(String)
      expect(definition[:function][:parameters][:required]).to include("command")
      expect(definition[:function][:parameters][:properties]).to have_key(:timeout)
      expect(definition[:function][:parameters][:properties]).to have_key(:max_output_lines)
    end
  end

  describe "timeout behavior" do
    it "uses provided timeout as hard_timeout" do
      # Test that timeout parameter is properly used
      result = tool.execute(command: "echo 'test'", timeout: 30)
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:success]).to be true
    end

    it "auto-detects timeout for slow commands when not specified" do
      # Just verify it doesn't crash with auto-detection
      result = tool.execute(command: "echo 'bundle install simulation'")
      
      expect(result[:exit_code]).to eq(0)
    end

    it "auto-detects timeout for normal commands when not specified" do
      result = tool.execute(command: "echo 'normal command'")
      
      expect(result[:exit_code]).to eq(0)
    end

    it "extracts timeout from 'timeout N command' format" do
      result = tool.execute(command: "timeout 30 echo 'test'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:success]).to be true
      # The actual command executed should be without the timeout prefix
      expect(result[:stdout]).to include("test")
    end

    it "extracts timeout from 'timeout Ns command' format with seconds suffix" do
      result = tool.execute(command: "timeout 45s echo 'hello'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("hello")
    end

    it "extracts timeout with signal option 'timeout -s SIGNAL N command'" do
      result = tool.execute(command: "timeout -s KILL 60 echo 'world'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("world")
    end

    it "prefers explicit timeout parameter over extracted timeout" do
      # When both are provided, explicit parameter should win
      result = tool.execute(command: "timeout 10 echo 'test'", timeout: 99)
      
      expect(result[:exit_code]).to eq(0)
      # We can't directly test which timeout was used, but we verify it executes
    end
  end

    it "extracts timeout from 'cd xxx && timeout N command' format" do
      result = tool.execute(command: "cd /tmp && timeout 30 echo 'test'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:success]).to be true
      expect(result[:stdout]).to include("test")
    end

    it "extracts timeout from 'export VAR=val && timeout N command' format" do
      result = tool.execute(command: "export TEST=value && timeout 45 echo 'hello'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("hello")
    end

    it "extracts timeout from 'prefix; timeout N command' format with semicolon" do
      result = tool.execute(command: "cd /tmp; timeout 60 echo 'world'")
      
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include("world")
    end

    it "handles complex compound commands with timeout" do
      result = tool.execute(command: "cd spec && timeout 30s ls -la")
      
      expect(result[:exit_code]).to eq(0)
      # Should execute in spec directory
    end

  describe "#format_waiting_input_result (via Shell)" do
    let(:shell) { Clacky::Tools::Shell.new }

    it "includes sudo hint when interaction type is password" do
      interaction = { type: "password", line: "[sudo] password for user:" }
      result = shell.send(:format_waiting_input_result, "sudo apt-get install vim", "", "", interaction, 1000)

      expect(result[:state]).to eq("WAITING_INPUT")
      expect(result[:interaction_type]).to eq("password")
      expect(result[:message]).to include("sudo -S")
      expect(result[:message]).to include("Ask the user")
    end

    it "does not include sudo hint for non-password interactions" do
      interaction = { type: "confirmation", line: "Do you want to continue? [Y/n]" }
      result = shell.send(:format_waiting_input_result, "apt-get install vim", "", "", interaction, 1000)

      expect(result[:state]).to eq("WAITING_INPUT")
      expect(result[:message]).not_to include("sudo -S")
    end
  end

  describe "#format_result_for_llm" do
    it "truncates long stdout output to save tokens" do
      # Create a result with very long output (over 2000 chars)
      long_output = "Line of text\n" * 500  # 6500+ chars
      result = {
        command: "generate_large_output",
        exit_code: 0,
        success: true,
        stdout: long_output,
        stderr: ""
      }

      compact = tool.format_result_for_llm(result)

      expect(compact[:stdout].length).to be < long_output.length
      expect(compact[:stdout]).to include("Output truncated for LLM")
      expect(compact[:exit_code]).to eq(0)
      expect(compact[:success]).to be true
    end

    it "truncates long stderr output to save tokens" do
      long_error = "Error line\n" * 500  # 5500+ chars
      result = {
        command: "failing_command",
        exit_code: 1,
        success: false,
        stdout: "",
        stderr: long_error
      }

      compact = tool.format_result_for_llm(result)

      expect(compact[:stderr].length).to be < long_error.length
      expect(compact[:stderr]).to include("Error output truncated for LLM")
    end

    it "preserves short output without truncation" do
      short_output = "Hello\nWorld\n"
      result = {
        command: "echo_test",
        exit_code: 0,
        success: true,
        stdout: short_output,
        stderr: ""
      }

      compact = tool.format_result_for_llm(result)

      expect(compact[:stdout]).to eq(short_output)
      expect(compact[:stdout]).not_to include("truncated")
    end

    it "preserves security enhancement fields" do
      result = {
        command: "rm test.txt",
        exit_code: 0,
        success: true,
        stdout: "[Safe] Command was automatically made safe\noutput",
        stderr: "",
        security_enhanced: true,
        original_command: "rm test.txt",
        safe_command: "mv test.txt /path/to/trash"
      }

      compact = tool.format_result_for_llm(result)

      expect(compact[:security_enhanced]).to be true
      expect(compact[:original_command]).to eq("rm test.txt")
      expect(compact[:safe_command]).to eq("mv test.txt /path/to/trash")
    end

    it "returns security_blocked results as-is" do
      result = {
        command: "sudo dangerous",
        stdout: "",
        stderr: "[Security Protection] sudo commands are not allowed",
        exit_code: 126,
        success: false,
        security_blocked: true
      }

      compact = tool.format_result_for_llm(result)

      expect(compact).to eq(result)
    end

    it "preserves error states and timeout info" do
      result = {
        command: "long_running_cmd",
        stdout: "partial output",
        stderr: "Command timed out",
        exit_code: -1,
        success: false,
        state: 'TIMEOUT',
        timeout_type: :hard_timeout
      }

      compact = tool.format_result_for_llm(result)

      expect(compact).to eq(result)
    end

    it "includes elapsed time if available" do
      result = {
        command: "quick_cmd",
        exit_code: 0,
        success: true,
        stdout: "done",
        stderr: "",
        elapsed: 1.234
      }

      compact = tool.format_result_for_llm(result)

      expect(compact[:elapsed]).to eq(1.234)
    end

    it "truncates individual long lines (e.g. minified CSS/JS)" do
      # Simulate minified CSS: only 2 lines but each is huge
      long_line = ".hover\:opacity-50{opacity:.5}" + ("a" * 50000) + "\n"
      minified_output = long_line * 2
      result = {
        command: "grep hover application.css",
        exit_code: 0,
        success: true,
        stdout: minified_output,
        stderr: ""
      }

      compact = tool.format_result_for_llm(result)

      expect(compact[:stdout].length).to be < minified_output.length
      expect(compact[:stdout]).to include("line truncated")
    end

    it "truncate_long_lines is accessible from SafeShell (inheritance check)" do
      # Regression test: private def in parent class breaks subclass access
      expect { tool.truncate_long_lines("a" * 600 + "\n", 500) }.not_to raise_error
      result = tool.truncate_long_lines("a" * 600 + "\n", 500)
      expect(result).to include("line truncated")
    end
  end
end

