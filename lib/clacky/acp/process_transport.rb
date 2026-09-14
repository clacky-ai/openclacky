# frozen_string_literal: true

require "json"
require "open3"
require_relative "../thread_registry"

module Clacky
  module Acp
    # Owns one newline-delimited JSON subprocess and its complete process tree.
    class ProcessTransport
      class Error < StandardError; end

      STDIN_CLOSE_GRACE = 2.25
      TERM_GRACE = 0.5
      KILL_GRACE = 0.5
      THREAD_JOIN_GRACE = 0.5
      STDERR_REDACTION_CONTEXT_BYTES = 4096

      def initialize(name:, argv:, env: {}, cwd: nil, max_message_bytes:, stderr_bytes:)
        unless argv.is_a?(Array) && !argv.empty? && !argv.first.to_s.empty?
          raise ArgumentError, "argv must contain an executable"
        end
        raise ArgumentError, "max_message_bytes must be positive" unless max_message_bytes.to_i > 0
        raise ArgumentError, "stderr_bytes must be positive" unless stderr_bytes.to_i > 0

        @name = name.to_s
        @argv = argv.map(&:to_s)
        @env = normalize_environment(env || {})
        @cwd = cwd && cwd.to_s
        @max_message_bytes = max_message_bytes.to_i
        @stderr_bytes = stderr_bytes.to_i

        @state_mutex = Mutex.new
        @write_mutex = Mutex.new
        @stderr_mutex = Mutex.new
        @callback_mutex = Mutex.new
        @stop_mutex = Mutex.new
        @stderr_buffer = String.new.b
        @on_message = nil
        @stdin = @stdout = @stderr = @wait_thread = nil
        @reader_thread = @stderr_thread = nil
        @pgid = nil
        @generation = 0
        @closed_generation = nil
      end

      def on_message(&block)
        raise ArgumentError, "on_message block is required" unless block

        @callback_mutex.synchronize { @on_message = block }
        self
      end

      def start
        @stop_mutex.synchronize do
          @state_mutex.synchronize do
            raise Error, "ACP process '#{@name}' is already running" if process_alive_unlocked?

            environment = @env.dup
            options = { pgroup: true, close_others: true, unsetenv_others: true }
            options[:chdir] = @cwd if @cwd

            # The [path, argv0] form forces direct execution even when argv text
            # contains shell metacharacters.
            executable = [@argv.first, @argv.first]
            @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
              environment,
              executable,
              *@argv.drop(1),
              options
            )
            @pgid = @wait_thread.pid
            @generation += 1
            generation = @generation
            @stderr_mutex.synchronize { @stderr_buffer.clear }
            @stdin.sync = true
            @stdout.binmode
            @stderr.binmode
            stdout = @stdout
            stderr = @stderr
            wait_thread = @wait_thread
            @reader_thread = spawn_thread("acp-reader:#{@name}") do
              read_stdout(stdout, wait_thread, generation)
            end
            @stderr_thread = spawn_thread("acp-stderr:#{@name}") do
              read_stderr(stderr, generation)
            end
          end
        end
        self
      rescue Error
        raise
      rescue StandardError => e
        close_streams
        raise Error, "failed to start ACP process '#{@name}': #{e.class}: #{e.message}"
      end

      def send_message(payload)
        line = JSON.generate(payload) + "\n"
        if line.bytesize - 1 > @max_message_bytes
          raise Error,
                "ACP message for '#{@name}' exceeds #{@max_message_bytes} bytes"
        end

        stream = @state_mutex.synchronize do
          unless process_alive_unlocked? && @stdin && !@stdin.closed?
            raise Error, "ACP process '#{@name}' stdin is closed"
          end
          @stdin
        end

        @write_mutex.synchronize { stream.write(line) }
        nil
      rescue JSON::GeneratorError => e
        raise Error, "failed to encode ACP message for '#{@name}': #{e.message}"
      rescue Errno::EPIPE, IOError => e
        raise Error, "failed to write ACP message for '#{@name}': #{e.message}"
      end

      def alive?
        @state_mutex.synchronize { process_alive_unlocked? }
      end

      def stderr_tail(bytes: nil)
        requested = bytes.nil? ? @stderr_bytes : bytes.to_i
        return "" if requested <= 0

        limit = [requested, @stderr_bytes].min
        raw = @stderr_mutex.synchronize { @stderr_buffer.dup }
        redacted = redact_stderr(raw)
        tail = redacted.byteslice(-limit, limit) || redacted
        tail.force_encoding(Encoding::UTF_8).scrub
      end

      def stop
        @stop_mutex.synchronize do
          stdin, stdout, stderr, wait_thread, reader_thread, stderr_thread, pgid,
            generation =
            @state_mutex.synchronize do
              snapshot = [@stdin, @stdout, @stderr, @wait_thread,
                          @reader_thread, @stderr_thread, @pgid, @generation]
              @stdin = @stdout = @stderr = @wait_thread = nil
              @reader_thread = @stderr_thread = nil
              @pgid = nil
              snapshot
            end

          return self unless wait_thread || stdin || stdout || stderr

          safe_close(stdin)
          wait_thread&.join(STDIN_CLOSE_GRACE)

          if owned_process_tree_alive?(pgid, wait_thread)
            signal_owned_process_tree("TERM", pgid, wait_thread)
            wait_for_process_tree(pgid, wait_thread, TERM_GRACE)
          end

          if owned_process_tree_alive?(pgid, wait_thread)
            signal_owned_process_tree("KILL", pgid, wait_thread)
            wait_for_process_tree(pgid, wait_thread, KILL_GRACE)
          end

          wait_thread&.join(KILL_GRACE)
          reader_thread&.join(THREAD_JOIN_GRACE)
          stderr_thread&.join(THREAD_JOIN_GRACE)
          safe_close(stdout)
          safe_close(stderr)
          reader_thread&.join(THREAD_JOIN_GRACE)
          stderr_thread&.join(THREAD_JOIN_GRACE)
          reader_thread&.kill if reader_thread&.alive?
          stderr_thread&.kill if stderr_thread&.alive?
          emit_closed(wait_thread, generation)
        end
        self
      end

      private def normalize_environment(environment)
        environment.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_s] = value.nil? ? nil : value.to_s
        end
      end

      private def process_alive_unlocked?
        !!(@wait_thread && @wait_thread.alive?)
      end

      private def spawn_thread(name, &block)
        Clacky::ThreadRegistry.spawn(name: name, daemon: true, &block)
      end

      private def read_stdout(stream, wait_thread, generation)
        loop do
          line = stream.gets(@max_message_bytes + 2)
          break unless line

          if line.end_with?("\n")
            payload = line.byteslice(0, line.bytesize - 1)
            payload = payload.byteslice(0, payload.bytesize - 1) if payload.end_with?("\r")
            if payload.bytesize > @max_message_bytes
              emit_message_too_large(generation)
            else
              parse_line(payload, generation)
            end
          elsif line.bytesize > @max_message_bytes
            emit_message_too_large(generation)
            discard_until_newline(stream)
          else
            parse_line(line, generation)
          end
        end
      rescue IOError, Errno::EBADF
        nil
      ensure
        emit_closed(wait_thread, generation)
      end

      private def discard_until_newline(stream)
        loop do
          fragment = stream.gets(@max_message_bytes + 2)
          break unless fragment
          break if fragment.end_with?("\n")
        end
      end

      private def parse_line(line, generation)
        message = JSON.parse(line.force_encoding(Encoding::UTF_8))
        emit(message, generation: generation)
      rescue JSON::ParserError, EncodingError
        emit_transport_error(
          "malformed_json",
          "invalid JSON received from ACP process '#{@name}'",
          {},
          generation
        )
      end

      private def emit_message_too_large(generation)
        emit_transport_error(
          "message_too_large",
          "ACP process '#{@name}' emitted a message larger than #{@max_message_bytes} bytes",
          { "max_bytes" => @max_message_bytes },
          generation
        )
      end

      private def emit_transport_error(code, message, details = {}, generation = nil)
        error = { "code" => code, "message" => message }.merge(details)
        emit(
          { "__transport_error__" => error, "error" => message },
          generation: generation
        )
      end

      private def emit(message, generation: nil)
        if generation
          current = @state_mutex.synchronize { @generation == generation }
          return unless current
        end

        callback = @callback_mutex.synchronize { @on_message }
        callback&.call(message)
      rescue StandardError
        nil
      end

      private def read_stderr(stream, generation)
        loop do
          chunk = stream.readpartial(4096)
          @state_mutex.synchronize do
            break unless @generation == generation

            @stderr_mutex.synchronize do
              @stderr_buffer << chunk
              raw_limit = @stderr_bytes + STDERR_REDACTION_CONTEXT_BYTES
              if @stderr_buffer.bytesize > raw_limit
                @stderr_buffer.replace(
                  @stderr_buffer.byteslice(-raw_limit, raw_limit) || @stderr_buffer
                )
              end
            end
          end
        end
      rescue EOFError, IOError, Errno::EBADF
        nil
      end

      private def redact_stderr(raw)
        text = raw.dup.force_encoding(Encoding::UTF_8).scrub
        text.gsub!(
          /(authorization\s*:\s*bearer\s+)[^\s,"']+/i,
          '\\1[REDACTED]'
        )
        text.gsub!(
          /((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret)["']?\s*[:=]\s*["']?)[^\s,"';]+/i,
          '\\1[REDACTED]'
        )
        text.gsub!(/\b(?:sk|sess)-[A-Za-z0-9._-]+/i, "[REDACTED]")
        text
      end

      private def emit_closed(wait_thread = nil, generation = nil)
        should_emit = @state_mutex.synchronize do
          generation ||= @generation
          next false unless generation == @generation
          next false if @closed_generation == generation

          @closed_generation = generation
          wait_thread ||= @wait_thread
          true
        end
        return unless should_emit

        wait_thread&.join(0.2)
        status = wait_thread.value unless wait_thread&.alive?
        exit_status = status && status.exitstatus
        term_signal = status && status.termsig
        error = if exit_status
                  "ACP process '#{@name}' exited with status #{exit_status}"
                elsif term_signal
                  "ACP process '#{@name}' exited from signal #{term_signal}"
                else
                  "ACP process '#{@name}' closed"
                end
        emit(
          {
            "__transport_closed__" => true,
            "error" => error,
            "exit_status" => exit_status,
            "term_signal" => term_signal
          },
          generation: generation
        )
      end

      private def owned_process_tree_alive?(pgid, wait_thread)
        if valid_owned_pgid?(pgid)
          Process.kill(0, -pgid)
          true
        else
          !!(wait_thread && wait_thread.alive?)
        end
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      private def signal_owned_process_tree(signal, pgid, wait_thread)
        if valid_owned_pgid?(pgid)
          Process.kill(signal, -pgid)
        elsif wait_thread
          Process.kill(signal, wait_thread.pid)
        end
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      private def wait_for_process_tree(pgid, wait_thread, timeout)
        deadline = monotonic_now + timeout
        while owned_process_tree_alive?(pgid, wait_thread) && monotonic_now < deadline
          sleep(0.01)
        end
      end

      private def valid_owned_pgid?(pgid)
        pgid && pgid > 1 && pgid != Process.getpgrp
      end

      private def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      private def close_streams
        streams = @state_mutex.synchronize { [@stdin, @stdout, @stderr] }
        streams.each { |stream| safe_close(stream) }
      end

      private def safe_close(stream)
        stream&.close unless stream&.closed?
      rescue IOError
        nil
      end
    end
  end
end
