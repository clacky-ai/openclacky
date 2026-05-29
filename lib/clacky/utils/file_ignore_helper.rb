# frozen_string_literal: true

module Clacky
  module Utils
    # Helper module for file ignoring functionality shared between tools
    module FileIgnoreHelper
      # Default patterns to ignore when .gitignore is not available
      DEFAULT_IGNORED_PATTERNS = [
        'node_modules',
        'vendor/bundle',
        '.git',
        '.svn',
        'tmp',
        'log',
        'coverage',
        'dist',
        'build',
        '.bundle',
        '.sass-cache',
        '.DS_Store',
        '*.log'
      ].freeze

      # Config file patterns that should always be searchable/visible
      CONFIG_FILE_PATTERNS = [
        /\.env/,
        /\.ya?ml$/,
        /\.json$/,
        /\.toml$/,
        /\.ini$/,
        /\.conf$/,
        /\.config$/,
      ].freeze

      # Find .gitignore file in the search path or parent directories
      # Only searches within the search path and up to the current working directory
      def self.find_gitignore(path)
        search_path = File.directory?(path) ? path : File.dirname(path)

        # Look for .gitignore in current and parent directories
        current = File.expand_path(search_path)
        cwd = File.expand_path(Dir.pwd) # intentional: gitignore boundary uses process cwd as fallback
        root = File.expand_path('/')

        # Limit search: only go up to current working directory
        # This prevents finding .gitignore files from unrelated parent directories
        # when searching in temporary directories (like /tmp in tests)
        search_limit = if current.start_with?(cwd)
                        cwd
                      else
                        current
                      end

        loop do
          gitignore = File.join(current, '.gitignore')
          return gitignore if File.exist?(gitignore)

          # Stop if we've reached the search limit or root
          break if current == search_limit || current == root
          current = File.dirname(current)
        end

        nil
      end

      # Directories that are always ignored regardless of .gitignore rules
      ALWAYS_IGNORED_DIRS = ['.git', '.svn', '.hg'].freeze

      # Check if file should be ignored based on .gitignore or default patterns
      def self.should_ignore_file?(file, base_path, gitignore)
        # Always calculate path relative to base_path for consistency
        # Expand both paths to handle symlinks and relative paths correctly
        expanded_file = File.expand_path(file)
        expanded_base = File.expand_path(base_path)

        # For files, use the directory as base
        expanded_base = File.dirname(expanded_base) if File.file?(expanded_base)

        # Calculate relative path
        if expanded_file.start_with?(expanded_base)
          relative_path = expanded_file[(expanded_base.length + 1)..-1] || File.basename(expanded_file)
        else
          # File is outside base path - use just the filename
          relative_path = File.basename(expanded_file)
        end

        # Clean up relative path
        relative_path = relative_path.sub(/^\.\//, '') if relative_path

        # Always ignore version control directories regardless of .gitignore rules
        return true if ALWAYS_IGNORED_DIRS.any? do |dir|
          relative_path.start_with?("#{dir}/") || relative_path == dir
        end

        if gitignore
          # Use .gitignore rules
          gitignore.ignored?(relative_path)
        else
          # Use default ignore patterns - only match against relative path components
          DEFAULT_IGNORED_PATTERNS.any? do |pattern|
            if pattern.include?('*')
              File.fnmatch(pattern, relative_path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
            else
              # Match pattern as a path component (not substring of absolute path)
              relative_path.start_with?("#{pattern}/") ||
              relative_path.include?("/#{pattern}/") ||
              relative_path == pattern ||
              File.basename(relative_path) == pattern
            end
          end
        end
      end

      # Check if file is a config file (should not be ignored even if in .gitignore)
      def self.is_config_file?(file)
        CONFIG_FILE_PATTERNS.any? { |pattern| file.match?(pattern) }
      end

      # Paths considered too broad to recursively walk by default. Searching from
      # these would commonly traverse millions of files (system roots, $HOME with
      # many workspaces, WSL Windows mounts). Tools should refuse such requests
      # and ask for a narrower base_path.
      def self.dangerous_root?(path)
        return false if path.nil? || path.empty?

        expanded = File.expand_path(path)
        return true if expanded == "/"

        system_roots = ["/root", "/home", "/Users", "/mnt", "/media", "/var", "/etc", "/usr", "/opt"]
        return true if system_roots.include?(expanded)

        ["/Users/", "/home/"].each do |prefix|
          next unless expanded.start_with?(prefix)
          tail = expanded[prefix.length..]
          return true if tail && !tail.empty? && !tail.include?("/")
        end

        return true if expanded =~ %r{\A/mnt/[a-zA-Z]\z}

        home = ENV["HOME"]
        return true if home && !home.empty? && expanded == File.expand_path(home)

        false
      end

      # Hard ceiling on directories visited in a single walk. Prevents indefinite
      # traversal across huge trees (e.g. /root, $HOME, /mnt/c on WSL).
      MAX_DIRS_VISITED = 20_000

      # Wall-clock budget for a single walk, in seconds.
      WALK_TIMEOUT_SECONDS = 15

      # Raised internally to abort a walk when a budget is exhausted.
      class WalkBudgetExceeded < StandardError
        attr_reader :reason
        def initialize(reason)
          @reason = reason
          super(reason.to_s)
        end
      end

      # Walk a directory tree, pruning ignored directories early.
      # Yields each non-ignored file path. Supports nested .gitignore files.
      # @param skipped [Hash, nil] If provided, increments :ignored for each gitignore-skipped entry.
      # @param status [Hash, nil] If provided, populated with :truncated and :truncation_reason
      #   when the walk is aborted due to dir-count or wall-clock budget.
      def self.walk_files(base_path, gitignore: nil, skipped: nil, status: nil,
                          max_dirs_visited: MAX_DIRS_VISITED,
                          timeout_seconds: WALK_TIMEOUT_SECONDS,
                          &block)
        unless block_given?
          return enum_for(:walk_files, base_path,
                          gitignore: gitignore, skipped: skipped, status: status,
                          max_dirs_visited: max_dirs_visited, timeout_seconds: timeout_seconds)
        end

        root_gitignore = gitignore || begin
          gi_path = find_gitignore(base_path)
          gi_path ? Clacky::GitignoreParser.new(gi_path) : nil
        end

        budget = {
          dirs_visited: 0,
          max_dirs: max_dirs_visited,
          deadline: timeout_seconds ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds) : nil
        }

        begin
          _walk_recursive(base_path, base_path, root_gitignore, skipped, budget, &block)
        rescue WalkBudgetExceeded => e
          if status
            status[:truncated] = true
            status[:truncation_reason] = e.reason.to_s
          end
        end
      end

      def self._walk_recursive(dir, base_path, gitignore, skipped, budget, &block)
        budget[:dirs_visited] += 1
        if budget[:dirs_visited] > budget[:max_dirs]
          raise WalkBudgetExceeded.new(:max_dirs_visited)
        end
        if budget[:deadline] && Process.clock_gettime(Process::CLOCK_MONOTONIC) > budget[:deadline]
          raise WalkBudgetExceeded.new(:timeout)
        end

        child_gitignore_path = File.join(dir, ".gitignore")
        if dir != base_path && File.exist?(child_gitignore_path)
          gitignore ||= Clacky::GitignoreParser.new(nil)
          relative_dir = dir[(base_path.length + 1)..]
          gitignore.merge!(child_gitignore_path, prefix: relative_dir)
        end

        begin
          entries = Dir.children(dir)
        rescue Errno::EACCES, Errno::ENOENT
          return
        end

        entries.sort.each do |name|
          full = File.join(dir, name)
          relative = full[(base_path.length + 1)..]

          if File.directory?(full)
            next if ALWAYS_IGNORED_DIRS.include?(name)
            if gitignore&.ignored?("#{relative}/") || should_ignore_file?(full, base_path, gitignore)
              next
            end
            _walk_recursive(full, base_path, gitignore, skipped, budget, &block)
          else
            if !is_config_file?(full) && should_ignore_file?(full, base_path, gitignore)
              skipped[:ignored] += 1 if skipped
              next
            end
            yield full
          end
        end
      end
      private_class_method :_walk_recursive

    end
  end
end
