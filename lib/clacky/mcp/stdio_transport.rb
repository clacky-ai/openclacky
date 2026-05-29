# frozen_string_literal: true

require "json"
require "open3"
require "monitor"
require "shellwords"

require_relative "transport"
require_relative "../utils/login_shell"

module Clacky
  module Mcp
    class StdioTransport < Transport
      def initialize(name:, command:, args: [], env: {}, cwd: nil)
        @name    = name
        @command = command
        @args    = Array(args)
        @env     = env || {}
        @cwd     = cwd

        @stdin = @stdout = @stderr = nil
        @wait_thr = nil
        @reader_thr = nil
        @on_message = nil
        @lock = Monitor.new
        @stderr_buf = String.new
      end

      def start
        full_env = ENV.to_h.merge(@env.transform_keys(&:to_s).transform_values(&:to_s))
        opts = { unsetenv_others: false }
        opts[:chdir] = @cwd if @cwd && File.directory?(@cwd)

        inner = ([@command] + @args).map { |a| Shellwords.shellescape(a) }.join(" ")
        wrapped = Clacky::Utils::LoginShell.login_shell_command(inner)

        @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(full_env, *wrapped, opts)
        @stdin.sync = true

        Thread.new do
          @stderr.each_line do |line|
            @lock.synchronize do
              @stderr_buf << line
              @stderr_buf.replace(@stderr_buf[-32_768, 32_768] || @stderr_buf) if @stderr_buf.bytesize > 65_536
            end
          end
        rescue IOError
        end

        start_reader
        self
      rescue Errno::ENOENT => e
        raise TransportError, "MCP server '#{@name}' command not found: #{@command} (#{e.message})"
      end

      def stop
        @lock.synchronize do
          return unless @wait_thr&.alive?
          begin
            Process.kill("TERM", @wait_thr.pid)
          rescue Errno::ESRCH, Errno::EPERM
          end
          deadline = Time.now + 2
          sleep 0.05 while @wait_thr.alive? && Time.now < deadline
          if @wait_thr.alive?
            begin
              Process.kill("KILL", @wait_thr.pid)
            rescue Errno::ESRCH, Errno::EPERM
            end
          end
        ensure
          [@stdin, @stdout, @stderr].each { |io| io&.close rescue nil }
          @reader_thr&.kill rescue nil
        end
      end

      def alive?
        !!(@wait_thr && @wait_thr.alive?)
      end

      def send_message(payload)
        line = JSON.generate(payload) + "\n"
        @lock.synchronize do
          raise TransportError, "MCP server '#{@name}' stdin closed" if @stdin.nil? || @stdin.closed?
          @stdin.write(line)
        end
      rescue Errno::EPIPE => e
        raise TransportError, "MCP server '#{@name}' stdin pipe broken: #{e.message}"
      end

      def on_message(&blk)
        @on_message = blk
      end

      def stderr_tail(bytes: 4096)
        @lock.synchronize { @stderr_buf[-bytes, bytes] || @stderr_buf.dup }
      end

      private def start_reader
        @reader_thr = Thread.new do
          @stdout.each_line do |line|
            line = line.strip
            next if line.empty?
            begin
              msg = JSON.parse(line)
            rescue JSON::ParserError
              next
            end
            @on_message&.call(msg)
          end
        rescue IOError
          @on_message&.call({ "__transport_closed__" => true })
        end
      end
    end
  end
end
