# frozen_string_literal: true

require "thor"
require "tmpdir"

module Clacky
  # `clacky ext <subcommand>` — manage extension containers (ext.yml).
  #
  # Containers contribute panels (WebUI) and api (HTTP backends). This command
  # group scaffolds, verifies, lists and hot-reloads them.
  class CliExtensionCommands < Thor
    def self.exit_on_failure?
      true
    end

    desc "new ID", "Scaffold a runnable hello-panel container at ~/.clacky/ext/local/ID/"
    method_option :full, type: :boolean, default: false,
                  desc: "Generate a kitchen-sink container exercising all 8 contributes types"
    def new(id)
      path = Clacky::ExtensionScaffold.new_container(id, full: options[:full])
      puts "Created extension container: #{path}"
      if options[:full]
        puts "It contributes panels/api/skills/agents/channels/patches/hooks. Read its README.md, run `clacky ext verify`, then reload the WebUI."
      else
        puts "Reload the WebUI page to see the panel. Edits to view.js and handler.rb take effect on the next request — no restart needed."
      end
    rescue ArgumentError => e
      warn "Error: #{e.message}"
      exit 1
    end

    desc "verify", "Resolve all containers across layers and report units + structured issues"
    def verify
      result = Clacky::ExtensionLoader.load_all

      if result.units.empty? && result.errors.empty?
        puts "No extension containers found."
        return
      end

      result.units.each do |u|
        case u.kind
        when :panel
          attach = Array(u.spec["attach"])
          suffix = attach.empty? ? "" : ", attach=#{attach.inspect}"
          puts "[OK]   #{u.ext_id}/#{u.id} (panel#{suffix}, #{u.layer})"
        when :api
          puts "[OK]   #{u.ext_id} (api → /api/ext/#{u.ext_id}/, #{u.layer})"
        else
          puts "[OK]   #{u.ext_id}/#{u.id} (#{u.kind}, #{u.layer})"
        end
      end

      issues = Clacky::ExtensionVerifier.verify(result)
      issues.each do |issue|
        tag = issue.level == :error ? "[ERR]" : "[WARN]"
        unit = issue.unit ? " #{issue.unit}" : ""
        loc  = issue.file ? " [#{issue.file}]" : ""
        hint = issue.hint ? "\n         hint: #{issue.hint}" : ""
        puts "#{tag} #{issue.ext}#{unit} (#{issue.code}) — #{issue.message}#{loc}#{hint}"
      end

      exit 1 if issues.any? { |i| i.level == :error }
    end

    desc "list", "List resolved containers and their contributed units"
    def list
      result = Clacky::ExtensionLoader.load_all

      if result.units.empty?
        puts "No extension units resolved."
        return
      end

      grouped = result.units.group_by(&:ext_id)
      grouped.each do |ext_id, units|
        layer = units.first.layer
        origin = units.first.origin
        puts "#{ext_id} (#{layer}, origin=#{origin})"
        units.each do |u|
          case u.kind
          when :panel
            attach = Array(u.spec["attach"])
            suffix = attach.empty? ? "" : "  attach=#{attach.inspect}"
            puts "  panel  #{u.id}#{suffix}"
          when :api
            puts "  api    → /api/ext/#{ext_id}/"
          else
            puts "  #{u.kind.to_s.ljust(6)} #{u.id}"
          end
        end
      end

      result.errors.each do |e|
        puts "[ERR] #{e.ext_id} #{e.unit} — #{e.message}"
      end
    end

    desc "pack ID", "Package a local container into a distributable zip"
    method_option :out, type: :string, desc: "Output directory for the zip (default: current dir)"
    def pack(id)
      out = options[:out] || Dir.pwd
      res = Clacky::ExtensionPackager.pack(id, out_dir: out)
      puts "Packed #{res.ext_id} → #{res.path}"
    rescue Clacky::ExtensionPackager::Error => e
      warn "Error: #{e.message}"
      exit 1
    end

    desc "install SOURCE", "Install a packed container (local zip path or http(s) URL) into the installed layer"
    method_option :force, type: :boolean, default: false, desc: "Overwrite an already-installed extension of the same id"
    def install(source)
      res = Clacky::ExtensionPackager.install(source, force: options[:force])
      puts "Installed #{res.ext_id} → #{res.path}"
      puts "Reload the WebUI page to see any panels. No restart needed."
    rescue Clacky::ExtensionPackager::Error => e
      warn "Error: #{e.message}"
      exit 1
    end

    desc "publish ID", "Pack a local container and publish it to the OpenClacky marketplace"
    method_option :force, type: :boolean, default: false, desc: "Publish a new version of an already-published extension"
    method_option :status, type: :string, desc: "Publish status: draft or published"
    method_option :changelog, type: :string, desc: "Release notes for this version"
    def publish(id)
      unless Clacky::Identity.load.bound?
        warn "Error: this device is not bound to a platform account. Authorize it first to publish."
        exit 1
      end

      brand = Clacky::BrandConfig.load
      Dir.mktmpdir("clacky-ext-publish") do |tmp|
        res      = Clacky::ExtensionPackager.pack(id, out_dir: tmp)
        zip_data = File.binread(res.path)

        result = brand.upload_extension!(
          res.ext_id, zip_data,
          force:     options[:force],
          status:    options[:status],
          changelog: options[:changelog]
        )

        if result[:success]
          ext = result[:extension] || {}
          ver = (ext["latest_version"] || {})["version"]
          puts "Published #{res.ext_id}#{ver ? " v#{ver}" : ""} → status=#{ext["status"]}"
        elsif result[:already_exists]
          warn "Error: #{res.ext_id} already published. Re-run with --force to publish a new version."
          exit 1
        else
          warn "Error: #{result[:error]}"
          exit 1
        end
      end
    rescue Clacky::ExtensionPackager::Error => e
      warn "Error: #{e.message}"
      exit 1
    end

    desc "published", "List extensions you have published to the marketplace"
    def published
      brand  = Clacky::BrandConfig.load
      result = brand.fetch_my_extensions!

      unless result[:success]
        warn "Error: #{result[:error]}"
        exit 1
      end

      extensions = result[:extensions]
      if extensions.empty?
        puts "You have not published any extensions yet."
        return
      end

      extensions.each do |ext|
        ver   = (ext["latest_version"] || {})["version"] || ext["version"]
        units = (ext["units"] || {}).map { |k, v| "#{v} #{k}" }.join(", ")
        puts "#{ext["name"]}  v#{ver}  [#{ext["status"]}]#{units.empty? ? "" : "  (#{units})"}"
      end
    end

    desc "unpublish ID", "Remove one of your published extensions from the marketplace"
    def unpublish(id)
      brand  = Clacky::BrandConfig.load
      result = brand.delete_extension!(id)

      if result[:success]
        puts "Unpublished #{id}."
      else
        warn "Error: #{result[:error]}"
        exit 1
      end
    end

    desc "search [QUERY]", "Search the public extension marketplace"
    method_option :sort, type: :string, default: "newest",
                         desc: "Sort order: newest, updated, downloads"
    def search(query = nil)
      brand  = Clacky::BrandConfig.load
      result = brand.search_extensions!(query: query, sort: options[:sort])

      unless result[:success]
        warn "Error: #{result[:error]}"
        exit 1
      end

      extensions = result[:extensions]
      if extensions.empty?
        puts query ? "No extensions found for #{query.inspect}." : "No extensions available yet."
        return
      end

      extensions.each do |ext|
        emoji = ext["emoji"] || "🧩"
        ver   = ext["version"]
        units = (ext["units"] || {}).map { |k, v| "#{v} #{k}" }.join(", ")
        name  = ext["name_zh"] || ext["name"]
        puts "#{emoji}  #{name}#{ver ? "  v#{ver}" : ""}#{units.empty? ? "" : "  (#{units})"}"
        desc = ext["description_zh"] || ext["description"]
        puts "    #{desc}" if desc && !desc.to_s.strip.empty?
      end
    end

  end
end
