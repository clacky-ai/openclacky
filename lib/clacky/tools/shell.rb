# frozen_string_literal: true

require_relative "base"

module Clacky
  module Tools
    class Shell < Base
      self.tool_name = "shell"
      self.tool_description = "Execute shell commands in the terminal"
      self.tool_category = "system"
      self.tool_parameters = {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "Shell command to execute"
          },
          soft_timeout: {
            type: "integer",
            description: "Soft timeout in seconds (for interaction detection)"
          },
          hard_timeout: {
            type: "integer",
            description: "Hard timeout in seconds (force kill)"
          },
          max_output_lines: {
            type: "integer",
            description: "Maximum number of output lines to return (default: 1000)",
            default: 1000
          }
        },
        required: ["command"]
      }

      INTERACTION_PATTERNS = [
        [/\[Y\/n\]|\[y\/N\]|\(yes\/no\)|\(Y\/n\)|\(y\/N\)/i, 'confirmation'],
        [/[Pp]assword\s*:\s*$|Enter password|enter password/, 'password'],
        [/^\s*>>>\s*$|^\s*>>?\s*$|^irb\(.*\):\d+:\d+[>*]\s*$|^>\s*$/, 'repl'],
        [/^\s*:\s*$|\(END\)|--More--|Press .* to continue|lines \d+-\d+/, 'pager'],
        [/Are you sure|Continue\?|Proceed\?|Confirm|Overwrite/i, 'question'],
        [/Enter\s+\w+:|Input\s+\w+:|Please enter|please provide/i, 'input'],
        [/Select an option|Choose|Which one|select one/i, 'selection']
      ].freeze

      SLOW_COMMANDS = [
        'bundle install',
        'npm install',
        'yarn install',
        'pnpm install',
        'rspec',
        'rake test',
        'npm run build',
        'npm run test',
        'yarn build',
        'cargo build',
        'go build'
      ].freeze

      def execute(command:, soft_timeout: nil, hard_timeout: nil, max_output_lines: 1000)
        require "open3"
        require "stringio"

        soft_timeout, hard_timeout = determine_timeouts(command, soft_timeout, hard_timeout)

        stdout_buffer = StringIO.new
        stderr_buffer = StringIO.new
        soft_timeout_triggered = false
        check_time = nil
        last_size = nil

        begin
          Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
            start_time = Time.now

            stdout.sync = true
            stderr.sync = true

            loop do
              elapsed = Time.now - start_time

              if elapsed > hard_timeout
                Process.kill('TERM', wait_thr.pid) rescue nil
                sleep 0.5
                Process.kill('KILL', wait_thr.pid) if wait_thr.alive? rescue nil

                return format_timeout_result(
                  command,
                  stdout_buffer.string,
                  stderr_buffer.string,
                  elapsed,
                  :hard_timeout,
                  hard_timeout,
                  max_output_lines
                )
              end

              if elapsed > soft_timeout && !soft_timeout_triggered
                soft_timeout_triggered = true

                # L1: Check for interaction patterns first
                interaction = detect_interaction(stdout_buffer.string)
                if interaction
                  Process.kill('TERM', wait_thr.pid) rescue nil
                  return format_waiting_input_result(
                    command,
                    stdout_buffer.string,
                    stderr_buffer.string,
                    interaction,
                    max_output_lines
                  )
                end

                # L2: Send newline and schedule check for 2 seconds later
                last_size = stdout_buffer.size
                stdin.puts("\n") rescue nil
                check_time = Time.now + 2  # Check after 2 seconds
              end

              # If soft timeout was triggered, check if it's time to verify output
              if soft_timeout_triggered && check_time && Time.now >= check_time
                current_size = stdout_buffer.size
                if current_size > last_size
                  # Output increased, program is responding - stop checking, let it continue
                  check_time = nil
                  last_size = nil
                else
                  # No new output, program is stuck
                  Process.kill('TERM', wait_thr.pid) rescue nil
                  return format_stuck_result(
                    command,
                    stdout_buffer.string,
                    stderr_buffer.string,
                    elapsed,
                    max_output_lines
                  )
                end
              end

              break unless wait_thr.alive?

              begin
                ready = IO.select([stdout, stderr], nil, nil, 0.1)
                if ready
                  ready[0].each do |io|
                    begin
                      data = io.read_nonblock(4096)
                      if io == stdout
                        stdout_buffer.write(data)
                      else
                        stderr_buffer.write(data)
                      end
                    rescue IO::WaitReadable, EOFError
                    end
                  end
                end
              rescue StandardError => e
              end

              sleep 0.1
            end

            begin
              stdout_buffer.write(stdout.read)
            rescue StandardError
            end
            begin
              stderr_buffer.write(stderr.read)
            rescue StandardError
            end

            stdout_output = stdout_buffer.string
            stderr_output = stderr_buffer.string
            
            {
              command: command,
              stdout: truncate_output(stdout_output, max_output_lines),
              stderr: truncate_output(stderr_output, max_output_lines),
              exit_code: wait_thr.value.exitstatus,
              success: wait_thr.value.success?,
              elapsed: Time.now - start_time,
              output_truncated: output_truncated?(stdout_output, stderr_output, max_output_lines)
            }
          end
        rescue StandardError => e
          stdout_output = stdout_buffer.string
          stderr_output = "Error executing command: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
          
          {
            command: command,
            stdout: truncate_output(stdout_output, max_output_lines),
            stderr: truncate_output(stderr_output, max_output_lines),
            exit_code: -1,
            success: false,
            output_truncated: output_truncated?(stdout_output, stderr_output, max_output_lines)
          }
        end
      end

      def determine_timeouts(command, soft_timeout, hard_timeout)
        # 检查是否是慢命令
        is_slow = SLOW_COMMANDS.any? { |slow_cmd| command.include?(slow_cmd) }

        if is_slow
          soft_timeout ||= 30
          hard_timeout ||= 180 # 3分钟
        else
          soft_timeout ||= 7
          hard_timeout ||= 60
        end

        [soft_timeout, hard_timeout]
      end

      # L1: 规则检测
      def detect_interaction(output)
        return nil if output.empty?

        lines = output.split("\n").last(10)

        lines.reverse.each do |line|
          line_stripped = line.strip
          next if line_stripped.empty?

          INTERACTION_PATTERNS.each do |pattern, type|
            if line.match?(pattern)
              return { type: type, line: line_stripped }
            end
          end
        end

        nil
      end

      def format_waiting_input_result(command, stdout, stderr, interaction, max_output_lines)
        {
          command: command,
          stdout: truncate_output(stdout, max_output_lines),
          stderr: truncate_output(stderr, max_output_lines),
          exit_code: -2,
          success: false,
          state: 'WAITING_INPUT',
          interaction_type: interaction[:type],
          message: format_waiting_message(truncate_output(stdout, max_output_lines), interaction),
          output_truncated: output_truncated?(stdout, stderr, max_output_lines)
        }
      end

      def format_waiting_message(output, interaction)
        <<~MSG
          #{output}

          #{'=' * 60}
          [Terminal State: WAITING_INPUT]
          #{'=' * 60}

          The terminal is waiting for your input.

          Detected pattern: #{interaction[:type]}
          Last line: #{interaction[:line]}

          Suggested actions:
          • Provide answer: run shell with your response
          • Cancel: send Ctrl+C (\\x03)
        MSG
      end

      def format_stuck_result(command, stdout, stderr, elapsed, max_output_lines)
        {
          command: command,
          stdout: truncate_output(stdout, max_output_lines),
          stderr: truncate_output(stderr, max_output_lines),
          exit_code: -3,
          success: false,
          state: 'STUCK',
          elapsed: elapsed,
          message: format_stuck_message(truncate_output(stdout, max_output_lines), elapsed),
          output_truncated: output_truncated?(stdout, stderr, max_output_lines)
        }
      end

      def format_stuck_message(output, elapsed)
        <<~MSG
          #{output}

          #{'=' * 60}
          [Terminal State: STUCK]
          #{'=' * 60}

          The terminal is not responding after #{elapsed.round(1)}s.

          Suggested actions:
          • Try interrupting with Ctrl+C
          • Check if command is frozen
        MSG
      end

      def format_timeout_result(command, stdout, stderr, elapsed, type, timeout, max_output_lines)
        {
          command: command,
          stdout: truncate_output(stdout, max_output_lines),
          stderr: truncate_output(stderr.empty? ? "Command timed out after #{elapsed.round(1)} seconds (#{type}=#{timeout}s)" : stderr, max_output_lines),
          exit_code: -1,
          success: false,
          state: 'TIMEOUT',
          timeout_type: type,
          output_truncated: output_truncated?(stdout, stderr, max_output_lines)
        }
      end

      # Truncate output to max_lines, adding a truncation notice if needed
      def truncate_output(output, max_lines)
        return output if output.nil? || output.empty?
        
        lines = output.lines
        return output if lines.length <= max_lines
        
        truncated_lines = lines.first(max_lines)
        truncation_notice = "\n\n... [Output truncated: showing #{max_lines} of #{lines.length} lines] ...\n"
        truncated_lines.join + truncation_notice
      end

      # Check if output was truncated
      def output_truncated?(stdout, stderr, max_lines)
        stdout_lines = stdout&.lines&.length || 0
        stderr_lines = stderr&.lines&.length || 0
        stdout_lines > max_lines || stderr_lines > max_lines
      end

      def format_call(args)
        cmd = args[:command] || args['command'] || ''
        cmd_parts = cmd.split
        cmd_short = cmd_parts.first(3).join(' ')
        cmd_short += '...' if cmd_parts.size > 3
        "Shell(#{cmd_short})"
      end

      def format_result(result)
        exit_code = result[:exit_code] || result['exit_code'] || 0
        stdout = result[:stdout] || result['stdout'] || ""
        stderr = result[:stderr] || result['stderr'] || ""

        if exit_code == 0
          lines = stdout.lines.size
          "✓ Completed#{lines > 0 ? " (#{lines} lines)" : ''}"
        else
          error_msg = stderr.lines.first&.strip || "Failed"
          "✗ Exit #{exit_code}: #{error_msg[0..50]}"
        end
      end
    end
  end
end
