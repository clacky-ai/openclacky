# frozen_string_literal: true

require "fileutils"
require "open3"

module Clacky
  module Utils
    # Manages user-space parsers in ~/.clacky/parsers/.
    #
    # On first use, default parser scripts are copied from the gem's
    # default_parsers/ directory into ~/.clacky/parsers/. After that,
    # the user-space version is always used — allowing the LLM to modify
    # or extend parsers without touching the gem itself.
    #
    # CLI interface contract (all parsers must follow):
    #   ruby <parser>.rb <file_path>
    #   stdout → extracted text (UTF-8)
    #   stderr → error messages
    #   exit 0 → success
    #   exit 1 → failure
    module ParserManager
      PARSERS_DIR         = File.expand_path("~/.clacky/parsers").freeze
      DEFAULT_PARSERS_DIR = File.expand_path("../default_parsers", __dir__).freeze

      PARSER_FOR = {
        ".pdf"  => "pdf_parser.rb",
        ".doc"  => "doc_parser.rb",
        ".docx" => "docx_parser.rb",
        ".xlsx" => "xlsx_parser.py",
        ".xls"  => "xlsx_parser.py",
        ".pptx" => "pptx_parser.rb",
        ".ppt"  => "pptx_parser.rb",
        ".wps"  => "wps_parser.rb",
        ".et"   => "wps_parser.rb",
        ".dps"  => "wps_parser.rb",
      }.freeze

      # Map a parser script's extension to the interpreter that runs it.
      # Lets PARSER_FOR point at scripts in any language (see extract_version).
      INTERPRETER_FOR = { ".rb" => RbConfig.ruby, ".py" => "python3" }.freeze

      # Third-party libraries a given Python parser needs at runtime.
      PYTHON_PARSER_LIBS = { "xlsx_parser.py" => "openpyxl" }.freeze

      # Hard ceiling on how long a single parser subprocess may run. A runaway
      # parser (huge/malformed file) is killed rather than hanging the caller
      # forever and starving the machine.
      PARSE_TIMEOUT = 60
      # Called at Agent startup (idempotent — safe to run every time).
      #
      # Copies every file from default_parsers/ (not just the entry-point .rb
      # scripts listed in PARSER_FOR). A parser may ship companion helper
      # scripts — e.g. pdf_parser_ocr.py sits next to pdf_parser.rb and is
      # invoked by relative path — so those helpers must be distributed too.
      #
      # Version upgrade policy:
      #   Each bundled parser declares `VERSION: <n>` in a header comment
      #   (works for Ruby `# VERSION: 2` and Python `# VERSION: 2` alike,
      #   scanned in the first 40 lines of the file).
      #
      #   On startup, per-file:
      #     - If the file does NOT exist in ~/.clacky/parsers/ → copy it.
      #     - If it exists:
      #         * bundled has no VERSION → never touch (bundled file
      #           is opting out of managed upgrades).
      #         * installed has no VERSION → treat it as legacy v0 and
      #           upgrade (lenient mode — covers users who installed before
      #           the VERSION scheme existed). The old file is backed up.
      #         * both have VERSION, bundled > installed → upgrade, backing
      #           up the old copy as `<script>.v<old>.bak`.
      #         * bundled ≤ installed → leave the user's copy alone
      #           (preserves LLM/user modifications).
      #
      #   Backups live alongside the parser so the user can inspect
      #   their own edits after an upgrade. They are never removed
      #   automatically.
      def self.setup!
        FileUtils.mkdir_p(PARSERS_DIR)

        Dir.glob(File.join(DEFAULT_PARSERS_DIR, "**", "*")).each do |src|
          next unless File.file?(src)
          basename = File.basename(src)
          next if basename.start_with?(".") || basename.end_with?(".bak")

          rel  = src.sub(/^#{Regexp.escape(DEFAULT_PARSERS_DIR)}\/?/, "")
          dest = File.join(PARSERS_DIR, rel)

          if !File.exist?(dest)
            FileUtils.mkdir_p(File.dirname(dest))
            FileUtils.cp(src, dest)
            # Preserve executable bit so sibling scripts can be run directly.
            FileUtils.chmod(File.stat(src).mode, dest)
            next
          end

          bundled_version = extract_version(src)
          # Bundled file opts out of managed upgrades — never touch user copy.
          next unless bundled_version

          installed_version = extract_version(dest) || 0

          if bundled_version > installed_version
            backup = "#{dest}.v#{installed_version}.bak"
            FileUtils.cp(dest, backup) unless File.exist?(backup)
            FileUtils.cp(src, dest)
            FileUtils.chmod(File.stat(src).mode, dest)
          end
        end
      end

      # Read the VERSION marker from a parser script (e.g. "# VERSION: 2").
      # Works for any script language that uses `#` for comments
      # (Ruby, Python, shell). Returns Integer or nil.
      def self.extract_version(path)
        return nil unless File.exist?(path)
        # Only scan the first 40 lines — the marker lives in the header.
        File.foreach(path).with_index do |line, i|
          break if i >= 40
          if (m = line.match(/^\s*#\s*VERSION:\s*(\d+)/i))
            return m[1].to_i
          end
        end
        nil
      rescue StandardError
        nil
      end

      # Run the appropriate parser for the given file path.
      #
      # @param file_path [String] path to the file to parse
      # @return [Hash] { success: bool, text: String, error: String, parser_path: String }
      def self.parse(file_path)
        ext = File.extname(file_path.to_s).downcase
        script = PARSER_FOR[ext]

        unless script
          return { success: false, text: nil,
                   error: "No parser available for #{ext} files",
                   parser_path: nil }
        end

        parser_path = File.join(PARSERS_DIR, script)

        unless File.exist?(parser_path)
          return { success: false, text: nil,
                   error: "Parser not found: #{parser_path}",
                   parser_path: parser_path }
        end

        interpreter = interpreter_for(script)

        # Python parsers need Python + their libs present before parsing.
        # ensure_python_deps returns an error string if python3 is missing or
        # a lib can't be installed — the caller surfaces it as parse_error.
        if interpreter == "python3"
          dep_error = ensure_python_deps(script)
          return { success: false, text: nil, error: dep_error, parser_path: parser_path } if dep_error
        end

        raw_stdout, raw_stderr, status =
          capture3_with_timeout(interpreter, parser_path, file_path, timeout: PARSE_TIMEOUT)

        # capture3 returns ASCII-8BIT across the subprocess boundary on Ruby 2.6+.
        # Normalise both streams to UTF-8 immediately so all downstream code is clean.
        stdout = Clacky::Utils::Encoding.to_utf8(raw_stdout.to_s)
        stderr = Clacky::Utils::Encoding.to_utf8(raw_stderr.to_s)

        # Filter out Ruby/Bundler version warnings that pollute stderr
        clean_stderr = stderr.lines.reject { |l| l.match?(/warning:|already initialized constant/) }.join.strip

        if status == :timeout
          { success: false, text: nil,
            error: "Parser timed out after #{PARSE_TIMEOUT}s (file too large or malformed)",
            parser_path: parser_path }
        elsif status.success? && stdout.strip.length > 0
          { success: true, text: stdout.strip, error: nil, parser_path: parser_path }
        else
          { success: false, text: nil,
            error: clean_stderr.empty? ? "Parser exited with code #{status.exitstatus}" : clean_stderr,
            parser_path: parser_path }
        end
      end

      # Map a parser script to its interpreter (Ruby, Python, ...).
      def self.interpreter_for(script)
        INTERPRETER_FOR[File.extname(script)] || RbConfig.ruby
      end

      # Run a subprocess with a hard timeout. On timeout the whole process
      # GROUP is killed (TERM, 2s grace, then KILL) so grandchildren spawned
      # by the parser die too. Mirrors mcp/stdio_transport.rb's kill sequence.
      #
      # Returns [stdout, stderr, status] — status is a Process::Status on
      # normal exit, or the symbol :timeout when the subprocess was killed.
      def self.capture3_with_timeout(*cmd, timeout:)
        stdin, stdout, stderr, wait_thr = Open3.popen3(*cmd, pgroup: true)
        stdin.close
        pgid = Process.getpgid(wait_thr.pid)

        out_thr = Thread.new { stdout.read }
        err_thr = Thread.new { stderr.read }

        if wait_thr.join(timeout)
          [out_thr.value, err_thr.value, wait_thr.value]
        else
          kill_process_group(pgid)
          out_thr.kill
          err_thr.kill
          [nil, "timed out", :timeout]
        end
      ensure
        [stdout, stderr].each { |io| io&.close rescue nil }
      end

      # Terminate a process group: TERM, wait up to 2s, then KILL.
      def self.kill_process_group(pgid)
        Process.kill("TERM", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
      else
        deadline = Time.now + 2
        sleep 0.05 while process_group_alive?(pgid) && Time.now < deadline
        begin
          Process.kill("KILL", -pgid) if process_group_alive?(pgid)
        rescue Errno::ESRCH, Errno::EPERM
        end
      end

      def self.process_group_alive?(pgid)
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      # Ensure Python 3 and the libs a Python parser needs are present,
      # installing on demand. Returns nil on success, or an error string.
      #
      # If python3 is missing, returns an error instructing the caller (the
      # LLM via terminal tool) to run install_system_deps.sh --clt-only — we
      # do NOT run it here because it blocks for 100+ seconds (CLT download).
      # If python3 exists, probe + install the missing lib via pip --user.
      def self.ensure_python_deps(script)
        lib = PYTHON_PARSER_LIBS[script]

        unless python3_available?
          return "Python 3 is required to parse this file. " \
                 "Run: bash ~/.clacky/scripts/install_system_deps.sh --clt-only\n" \
                 "Then retry."
        end

        return nil if lib.nil? || python_lib_present?(lib)
        pip_install(lib) ? nil : "Failed to install #{lib} (required to parse this file)."
      end

      def self.python3_available?
        system("python3", "--version", out: File::NULL, err: File::NULL)
      end

      def self.python_lib_present?(lib)
        system("python3", "-c", "import #{lib}", out: File::NULL, err: File::NULL)
      end

      def self.pip_install(lib)
        system("python3", "-m", "pip", "install", "--user", lib, out: File::NULL, err: File::NULL)
      end

      # Returns the path to a parser script for a given extension.
      # Used by agent to tell LLM where to find/modify the parser.
      def self.parser_path_for(ext)
        script = PARSER_FOR[ext.downcase]
        return nil unless script
        File.join(PARSERS_DIR, script)
      end
    end
  end
end
