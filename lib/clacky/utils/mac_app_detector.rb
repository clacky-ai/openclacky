# frozen_string_literal: true

require "open3"
require "digest"
require_relative "environment_detector"

module Clacky
  module Utils
    # Detects installed macOS applications able to open a given file type.
    #
    # Builds an extension → apps index by scanning application bundles and
    # parsing their Info.plist document declarations (CFBundleDocumentTypes),
    # then applies a static supplement for well-known apps whose cross-format
    # abilities are not declared in the plist — e.g. Keynote opens ppt/pptx
    # without listing them. Non-macOS hosts always answer with an empty list.
    module MacAppDetector
      SEARCH_DIRS = [
        "/Applications",
        "/System/Applications",
        File.expand_path("~/Applications")
      ].freeze

      # bundle name (without .app) => extensions it handles but does not
      # declare in CFBundleDocumentTypes.
      EXTRA_ABILITIES = {
        "Keynote"              => %w[key kth ppt pptx pot pps ppsx],
        "Pages"                => %w[pages doc docx dot rtf],
        "Numbers"              => %w[numbers xls xlsx csv],
        "Preview"              => %w[pdf png jpg jpeg gif tiff tif heic webp svg bmp],
        "Microsoft PowerPoint" => %w[ppt pptx pot pps ppsx],
        "Microsoft Word"       => %w[doc docx dot rtf],
        "Microsoft Excel"      => %w[xls xlsx csv],
      }.freeze

      # @param ext [String] file extension, with or without leading dot
      # @return [Array<Hash>] [{ "name" => ..., "path" => bundle path }]
      def self.apps_for_ext(ext)
        return [] unless Utils::EnvironmentDetector.os_type == :macos

        ext = ext.to_s.downcase.sub(/\A\./, "")
        return [] if ext.empty?

        index[ext].sort_by { |a| a["name"] }
      end

      # Resolve an app name or bundle path to a scanned bundle path.
      # @return [String, nil]
      def self.app_path(name_or_path)
        return nil unless Utils::EnvironmentDetector.os_type == :macos

        all_apps[name_or_path.to_s] || all_apps.key(name_or_path.to_s)
      end

      # Return the application macOS would use to open `path` (the handler the
      # plain `open` command would pick). Cached per file extension.
      # @param path [String] absolute file path
      # @return [Hash, nil] { "name" => ..., "path" => bundle path }
      def self.default_app_for(path)
        return nil unless Utils::EnvironmentDetector.os_type == :macos

        ext = File.extname(path).downcase.sub(/\A\./, "")
        return nil if ext.empty?

        @default_app_cache ||= {}
        return @default_app_cache[ext] if @default_app_cache.key?(ext)

        bundle = default_app_bundle(path)
        @default_app_cache[ext] =
          if bundle && File.directory?(bundle)
            { "name" => File.basename(bundle, ".app"), "path" => bundle }
          end
      end

      # Query LaunchServices for the default handler of `path` via NSWorkspace.
      # @return [String, nil] bundle path (…/*.app)
      def self.default_app_bundle(path)
        script = <<~JXA
          (function() {
            ObjC.import("AppKit");
            var url = $.NSURL.fileURLWithPath(#{path.to_json});
            var app = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(url);
            return app ? app.path.js : "";
          })()
        JXA
        out, _err, _status = Open3.capture3("osascript", "-l", "JavaScript", "-e", script)
        result = out.strip
        result.empty? ? nil : result
      rescue StandardError
        nil
      end

      # Convert an application bundle icon (.icns) to a cached 64px PNG via the
      # system `sips` tool. Used by the Web UI "open with" dropdown.
      # @param bundle_path [String] application bundle path (…/*.app)
      # @return [String, nil] path to the cached PNG file
      def self.icon_png(bundle_path)
        return nil unless Utils::EnvironmentDetector.os_type == :macos

        bundle = bundle_path.to_s
        return nil unless bundle.end_with?(".app") && File.directory?(bundle)

        cache_dir = File.join(Dir.home, "Library", "Caches", "openclacky", "app-icons")
        cache = File.join(cache_dir, Digest::MD5.hexdigest(bundle) + ".png")
        return cache if File.exist?(cache)

        info = read_plist(File.join(bundle, "Contents", "Info.plist"))
        return nil unless info

        icon = info["CFBundleIconFile"].to_s
        return nil if icon.empty?
        icon += ".icns" unless icon =~ /\.icns\z/i
        icns = File.join(bundle, "Contents", "Resources", icon)
        return nil unless File.exist?(icns)

        require "fileutils"
        FileUtils.mkdir_p(cache_dir)
        ok = system("sips", "-s", "format", "png", "--resampleWidth", "64",
                    icns, "--out", cache, out: File::NULL, err: File::NULL)
        return nil unless ok && File.exist?(cache)
        cache
      end

      # Open a file with a specific installed application (macOS only).
      # @param path [String] absolute file path
      # @param app [String] app name or bundle path, must be a scanned app
      # @return [Boolean, nil] system() result, nil when the app is unknown
      def self.open_with(path, app)
        bundle = app_path(app.to_s)
        return nil unless bundle
        system("open", "-a", bundle, path)
      end

      def self.all_apps
        return @all_apps if defined?(@all_apps)

        @all_apps = {}
        SEARCH_DIRS.each do |dir|
          next unless File.directory?(dir)
          Dir.glob(File.join(dir, "*.app")).each do |bundle|
            @all_apps[File.basename(bundle, ".app")] = bundle
          end
        end
        @all_apps
      end

      def self.index
        return @index if defined?(@index)

        @index = Hash.new { |h, k| h[k] = [] }

        all_apps.each do |name, bundle|
          info = read_plist(File.join(bundle, "Contents", "Info.plist"))
          next unless info
          (info["CFBundleDocumentTypes"] || []).each do |dt|
            (dt["CFBundleTypeExtensions"] || []).each do |e|
              add(@index, e.to_s.downcase, name, bundle)
            end
          end
        end

        EXTRA_ABILITIES.each do |name, exts|
          bundle = all_apps[name]
          next unless bundle
          exts.each { |e| add(@index, e, name, bundle) }
        end

        @index
      end

      def self.add(index, ext, name, bundle)
        return if ext.empty?
        list = index[ext]
        list << { "name" => name, "path" => bundle } unless list.any? { |a| a["path"] == bundle }
      end

      def self.read_plist(path)
        out, _err, _status = Open3.capture3("plutil", "-convert", "json", "-o", "-", path)
        return nil if out.nil? || out.empty?
        require "json"
        JSON.parse(out)
      rescue StandardError
        nil
      end
    end
  end
end
