# frozen_string_literal: true

require "fileutils"
require_relative "parser_manager"

module Clacky
  module Utils
    # Manages user-space search providers in ~/.clacky/searchers/.
    #
    # Mirrors ParserManager: bundled searchers are copied out of the gem on
    # first use, and from then on the user-space copy wins, so a user can edit
    # a searcher (or add their own) without touching the gem and without
    # losing the change on `gem update`.
    #
    # CLI interface contract (all searchers must follow):
    #   <interpreter> <searcher> "<query>" <max_results>
    #   stdout → JSON array of {"title","url","snippet"} objects
    #   stderr → error messages
    #   exit 0 → success
    #   exit 1 → failure
    #
    # The credential from search.yml arrives as ENV["CLACKY_SEARCH_KEY"] rather
    # than an argv entry, which would otherwise be world-readable via `ps`.
    module SearcherManager
      SEARCHERS_DIR         = File.expand_path("~/.clacky/searchers").freeze
      DEFAULT_SEARCHERS_DIR = File.expand_path("../default_searchers", __dir__).freeze

      INTERPRETER_FOR = { ".rb" => RbConfig.ruby, ".py" => "python3" }.freeze

      # Called at Agent startup (idempotent — safe to run every time).
      # Upgrade policy matches ParserManager: a bundled searcher only replaces
      # an installed one when its `# VERSION:` marker is higher, and the old
      # copy is backed up so a user can recover their edits.
      def self.setup!
        FileUtils.mkdir_p(SEARCHERS_DIR)

        Dir.glob(File.join(DEFAULT_SEARCHERS_DIR, "*")).each do |src|
          next unless File.file?(src)
          basename = File.basename(src)
          next if basename.start_with?(".") || basename.end_with?(".bak")

          dest = File.join(SEARCHERS_DIR, basename)

          unless File.exist?(dest)
            FileUtils.cp(src, dest)
            FileUtils.chmod(File.stat(src).mode, dest)
            next
          end

          bundled_version = ParserManager.extract_version(src)
          next unless bundled_version

          installed_version = ParserManager.extract_version(dest) || 0
          next unless bundled_version > installed_version

          backup = "#{dest}.v#{installed_version}.bak"
          FileUtils.cp(dest, backup) unless File.exist?(backup)
          FileUtils.cp(src, dest)
          FileUtils.chmod(File.stat(src).mode, dest)
        end
      end

      # Resolve a provider name from search.yml to an installed script path.
      # @param name [String] e.g. "tavily"
      # @return [String, nil] absolute path, or nil when not installed
      def self.path_for(name)
        base = File.basename(name.to_s.strip)
        return nil if base.empty?

        Dir.glob(File.join(SEARCHERS_DIR, "#{base}.*")).find { |p| INTERPRETER_FOR.key?(File.extname(p)) }
      end

      # Names of every installed searcher, for the settings UI to offer.
      # @return [Array<String>]
      def self.available
        Dir.glob(File.join(SEARCHERS_DIR, "*"))
           .select { |p| File.file?(p) && INTERPRETER_FOR.key?(File.extname(p)) }
           .map { |p| File.basename(p, File.extname(p)) }
           .sort
      end

      def self.interpreter_for(path)
        INTERPRETER_FOR[File.extname(path)] || RbConfig.ruby
      end
    end
  end
end
