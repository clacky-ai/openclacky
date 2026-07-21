# frozen_string_literal: true

require "fileutils"
require "json"

module Clacky
  # Discovers extension containers across three source layers and resolves them
  # into a flat list of capability units (panels, api, skills, agents) for the
  # rest of the system to mount.
  #
  # A container is a directory holding an `ext.yml` manifest:
  #
  #   id: canvas-suite
  #   name: Canvas Suite
  #   version: "1.0.0"
  #   author: Jane Doe                # display credit (optional)
  #   homepage: https://example.com   # optional
  #   license: MIT                    # optional, SPDX identifier
  #   origin: self                 # self | marketplace | enterprise
  #   contributes:
  #     panels:
  #       - id: canvas
  #         view: panels/canvas/view.js
  #         attach: [designer]               # optional: panel author's default
  #                                          # ("*" = all agents; omit = hidden
  #                                          # unless an agent references it)
  #     api: api/handler.rb                  # single backend for the whole ext
  #
  # Source layers (ascending priority — same id, higher layer wins):
  #   builtin    gem default_extensions/<id>/
  #   installed  ~/.clacky/ext/installed/<id>/
  #   local      ~/.clacky/ext/local/<id>/
  #
  # This class only *discovers and resolves*; actual mounting is done by the
  # existing call sites:
  #   - api unit      → ApiExtensionLoader.load_one(...)  (server boot / reload)
  #   - panel units   → http_server ext_script_block(...) (rendered per request)
  #   - skill units   → SkillLoader#load_extension_skills (reads last_result on load_all)
  #   - agent units   → AgentProfile + http_server agent_profile_data (lookup by id)
  #   - channel units → channel.rb extension_adapter_loader (require + register at boot)
  #   - patch units   → PatchLoader.load_extension_patches (require at boot)
  #   - hook units    → ShellHookLoader.load_extension_hooks (register at boot)
  module ExtensionLoader
    BUILTIN_DIR   = File.expand_path("../default_extensions", __dir__)
    INSTALLED_DIR = File.expand_path("~/.clacky/ext/installed")
    LOCAL_DIR     = File.expand_path("~/.clacky/ext/local")
    DISABLED_FILE = File.expand_path("~/.clacky/ext/disabled.json")
    MANIFEST      = "ext.yml"

    # User data lives OUTSIDE the package tree so uninstalling (which deletes
    # the package dir) never takes the data with it, and reinstalling the same
    # extension transparently reconnects to it.
    DATA_DIR      = File.expand_path("~/.clacky/ext-data")

    # Layers in ascending priority; later entries override earlier ones by id.
    LAYERS = %i[builtin installed local].freeze
    ORIGINS = %w[self marketplace enterprise].freeze

    # One resolved capability unit. `kind` is :panel or :api.
    Unit = Struct.new(
      :kind, :id, :ext_id, :layer, :origin, :dir, :spec,
      keyword_init: true
    )

    # One resolution error, structured so an AI author can locate and fix it.
    Error = Struct.new(:ext_id, :layer, :unit, :message, :file, keyword_init: true)

    Result = Struct.new(:panels, :api, :skills, :agents, :channels, :patches, :hooks, :errors, :overridden, :containers, keyword_init: true) do
      def units
        panels + api + skills + agents + channels + patches + hooks
      end
    end

    class << self
      def dir_for(layer)
        case layer
        when :builtin   then BUILTIN_DIR
        when :installed then INSTALLED_DIR
        when :local     then LOCAL_DIR
        end
      end

      # Package-external directory holding an extension's persisted user data.
      def data_dir_for(id)
        File.join(DATA_DIR, id.to_s)
      end

      # Scan all layers, resolve overrides, return a structured Result.
      # `layers` maps layer name => root dir; defaults to the real three-layer
      # dirs. Tests inject temp dirs through it.
      #
      # Cached by a fingerprint of every container's `ext.yml` mtime — a hot
      # path (per web request, per API call) hits the cache; the moment any
      # manifest changes, we invalidate and rescan. Pass `force: true` to
      # bypass the cache (used by CLI / tests).
      def load_all(layers: default_layers, force: false)
        fingerprint = [fingerprint_layers(layers), disabled_fingerprint]
        if !force && @last_result && @last_fingerprint == fingerprint
          return @last_result
        end

        by_id = {}          # ext_id => resolved container (winning layer)
        overridden = []     # [ext_id, losing_layer, winning_layer]
        errors = []

        layers.each do |layer, root|
          next unless root && Dir.exist?(root)

          Dir.children(root).sort.each do |ext_id|
            next if ext_id.start_with?("_", ".")
            dir = File.join(root, ext_id)
            next unless File.directory?(dir)

            manifest = File.join(dir, MANIFEST)
            next unless File.file?(manifest)

            container = read_container(ext_id, layer, dir, manifest, errors)
            next unless container

            if (prev = by_id[ext_id])
              overridden << [ext_id, prev[:layer], layer]
            end
            by_id[ext_id] = container
          end
        end

        result = Result.new(panels: [], api: [], skills: [], agents: [], channels: [], patches: [], hooks: [], errors: errors, overridden: overridden, containers: by_id)
        disabled = disabled_ids
        by_id.each_value do |container|
          container[:disabled] = disabled.include?(container[:ext_id])
          resolve_units(container, result) unless container[:disabled]
        end

        @last_result = result
        @last_fingerprint = fingerprint
        result
      end

      def default_layers
        LAYERS.each_with_object({}) { |layer, h| h[layer] = dir_for(layer) }
      end

      def last_result
        @last_result || load_all
      end

      # Discard the mtime cache so the next `load_all` rescans from disk.
      # Used by CLI commands that mutate the ext tree (new / pack).
      def invalidate_cache!
        @last_fingerprint = nil
      end

      # ── Disabled state ────────────────────────────────────────────────
      # A disabled extension stays discoverable (still listed as installed)
      # but contributes no units until re-enabled. Persisted as a JSON array
      # of ext ids at ~/.clacky/ext/disabled.json.

      def disabled_ids
        return Set.new unless File.file?(DISABLED_FILE)

        data = JSON.parse(File.read(DISABLED_FILE))
        data.is_a?(Array) ? data.map(&:to_s).to_set : Set.new
      rescue StandardError
        Set.new
      end

      def disabled?(id)
        disabled_ids.include?(id.to_s)
      end

      def disable!(id)
        ids = disabled_ids
        ids << id.to_s
        write_disabled(ids)
      end

      def enable!(id)
        ids = disabled_ids
        ids.delete(id.to_s)
        write_disabled(ids)
      end

      # Remove an installed extension by deleting its installed-layer dir.
      # Only the installed layer is removable (builtin ships with the gem;
      # local is the author's own working copy). Package-external user data is
      # preserved by default so a reinstall reconnects to it; pass
      # `purge_data: true` to also delete ~/.clacky/ext-data/<id>. Returns true
      # on removal.
      def uninstall!(id, purge_data: false)
        dir = File.join(INSTALLED_DIR, id.to_s)
        return false unless File.directory?(dir)

        FileUtils.rm_rf(dir)
        FileUtils.rm_rf(data_dir_for(id)) if purge_data
        enable!(id) # clear any stale disabled flag
        invalidate_cache!
        true
      end

      private def write_disabled(ids)
        FileUtils.mkdir_p(File.dirname(DISABLED_FILE))
        File.write(DISABLED_FILE, JSON.generate(ids.to_a.sort))
        invalidate_cache!
      end

      private def disabled_fingerprint
        File.file?(DISABLED_FILE) ? File.mtime(DISABLED_FILE).to_f : 0.0
      rescue StandardError
        Object.new
      end


      # A layer's fingerprint is the sorted list of "<ext_id>|<mtime>" for
      # every container manifest present. Cheap to compute (one stat per
      # manifest); the whole map compared as a Hash so a container appearing
      # or disappearing also invalidates.
      private def fingerprint_layers(layers)
        layers.each_with_object({}) do |(layer, root), acc|
          next unless root && Dir.exist?(root)

          entries = []
          Dir.children(root).sort.each do |ext_id|
            next if ext_id.start_with?("_", ".")
            manifest = File.join(root, ext_id, MANIFEST)
            next unless File.file?(manifest)

            entries << [ext_id, File.mtime(manifest).to_f]
          end
          acc[layer] = entries
        end
      rescue StandardError
        # On any stat error just return a unique object so we always rescan.
        Object.new
      end

      private def read_container(ext_id, layer, dir, manifest, errors)
        data = YAMLCompat.load_file(manifest) || {}
        unless data.is_a?(Hash)
          errors << Error.new(ext_id: ext_id, layer: layer.to_s,
                              message: "ext.yml must be a mapping", file: manifest)
          return nil
        end

        origin = (data["origin"] || "self").to_s
        unless ORIGINS.include?(origin)
          errors << Error.new(ext_id: ext_id, layer: layer.to_s,
                              message: "invalid origin #{origin.inspect} (expected one of #{ORIGINS.join('/')})",
                              file: manifest)
          return nil
        end

        { ext_id: ext_id, layer: layer, dir: dir, origin: origin,
          public: data["public"] == true,
          name: (data["name"] || ext_id).to_s,
          version: data["version"].to_s,
          author: data["author"].to_s,
          homepage: data["homepage"].to_s,
          license: data["license"].to_s,
          contributes: data["contributes"] || {},
          raw: data }
      rescue StandardError => e
        errors << Error.new(ext_id: ext_id, layer: layer.to_s,
                            message: "failed to parse ext.yml: #{e.message}", file: manifest)
        nil
      end

      private def resolve_units(container, result)
        contributes = container[:contributes]
        return unless contributes.is_a?(Hash)

        Array(contributes["panels"]).each do |spec|
          unit = build_panel_unit(container, spec, result.errors)
          result.panels << unit if unit
        end

        if (api_spec = contributes["api"])
          unit = build_api_unit(container, api_spec, result.errors)
          result.api << unit if unit
        end

        Array(contributes["skills"]).each do |spec|
          unit = build_skill_unit(container, spec, result.errors)
          result.skills << unit if unit
        end

        Array(contributes["agents"]).each do |spec|
          unit = build_agent_unit(container, spec, result.errors)
          result.agents << unit if unit
        end

        Array(contributes["channels"]).each do |spec|
          unit = build_channel_unit(container, spec, result.errors)
          result.channels << unit if unit
        end

        Array(contributes["patches"]).each do |spec|
          unit = build_patch_unit(container, spec, result.errors)
          result.patches << unit if unit
        end

        Array(contributes["hooks"]).each do |spec|
          unit = build_hook_unit(container, spec, result.errors)
          result.hooks << unit if unit
        end
      end

      private def build_panel_unit(container, spec, errors)
        ext_id = container[:ext_id]
        unless spec.is_a?(Hash) && spec["id"] && spec["view"]
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "panel",
                              message: "panel needs both `id` and `view`")
          return nil
        end

        view_abs = File.join(container[:dir], spec["view"])
        unless File.file?(view_abs)
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "panel/#{spec['id']}",
                              message: "view file not found: #{spec['view']}", file: view_abs)
          return nil
        end

        Unit.new(kind: :panel, id: spec["id"].to_s, ext_id: ext_id,
                 layer: container[:layer], origin: container[:origin],
                 dir: container[:dir],
                 spec: {
                   "view"           => spec["view"],
                   "title"          => spec["title"],
                   "title_zh"       => spec["title_zh"],
                   "description"    => spec["description"],
                   "description_zh" => spec["description_zh"],
                   "order"          => spec["order"],
                   "attach"         => Array(spec["attach"]).map(&:to_s),
                 })
      end

      private def build_api_unit(container, spec, errors)
        ext_id = container[:ext_id]
        handler_rel = spec.is_a?(String) ? spec : nil
        unless handler_rel && !handler_rel.empty?
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "api",
                              message: "api must be a string path to the handler file (e.g. `api: api/handler.rb`)",
                              file: File.join(container[:dir], "ext.yml"))
          return nil
        end

        handler_abs = File.join(container[:dir], handler_rel)
        unless File.file?(handler_abs)
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "api",
                              message: "handler file not found: #{handler_rel}", file: handler_abs)
          return nil
        end

        Unit.new(kind: :api, id: ext_id, ext_id: ext_id,
                 layer: container[:layer], origin: container[:origin],
                 dir: container[:dir],
                 spec: { "handler" => handler_rel, "handler_abs" => handler_abs })
      end

      private def build_skill_unit(container, spec, errors)
        ext_id = container[:ext_id]
        unless spec.is_a?(Hash) && spec["id"]
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "skill",
                              message: "skill needs `id`")
          return nil
        end

        rel_dir = spec["dir"] || "skills/#{spec['id']}"
        skill_dir = File.join(container[:dir], rel_dir)
        unless File.directory?(skill_dir)
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "skill/#{spec['id']}",
                              message: "skill dir not found: #{rel_dir}", file: skill_dir)
          return nil
        end

        encrypted = File.file?(File.join(skill_dir, "SKILL.md.enc"))
        plain     = File.file?(File.join(skill_dir, "SKILL.md"))
        unless encrypted || plain
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "skill/#{spec['id']}",
                              message: "skill dir missing SKILL.md or SKILL.md.enc", file: skill_dir)
          return nil
        end

        protected_default = container[:origin] == "marketplace"
        protected_flag = spec.key?("protected") ? !!spec["protected"] : protected_default

        Unit.new(kind: :skill, id: spec["id"].to_s, ext_id: ext_id,
                 layer: container[:layer], origin: container[:origin],
                 dir: container[:dir],
                 spec: { "dir" => rel_dir, "skill_dir_abs" => skill_dir,
                         "protected" => protected_flag, "encrypted" => encrypted })
      end

      private def build_agent_unit(container, spec, errors)
        ext_id = container[:ext_id]
        unless spec.is_a?(Hash) && spec["id"] && spec["prompt"]
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "agent",
                              message: "agent needs both `id` and `prompt`")
          return nil
        end

        prompt_abs = File.join(container[:dir], spec["prompt"])
        unless File.file?(prompt_abs)
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "agent/#{spec['id']}",
                              message: "prompt file not found: #{spec['prompt']}", file: prompt_abs)
          return nil
        end

        avatar_rel = spec["avatar"].to_s
        avatar_abs = avatar_rel.empty? ? "" : File.join(container[:dir], avatar_rel)
        avatar_abs = "" unless !avatar_abs.empty? && File.file?(avatar_abs)

        Unit.new(kind: :agent, id: spec["id"].to_s, ext_id: ext_id,
                 layer: container[:layer], origin: container[:origin],
                 dir: container[:dir],
                 spec: {
                   "title"          => spec["title"].to_s,
                   "title_zh"       => spec["title_zh"].to_s,
                   "prompt"         => spec["prompt"],
                   "prompt_abs"     => prompt_abs,
                   "avatar"         => avatar_rel,
                   "avatar_abs"     => avatar_abs,
                   "description"    => spec["description"].to_s,
                   "description_zh" => spec["description_zh"].to_s,
                   "order"          => spec["order"],
                   "author"         => container[:author],
                   "homepage"       => container[:homepage],
                   "license"        => container[:license],
                   "panels"         => Array(spec["panels"]).map(&:to_s),
                   "skills"         => Array(spec["skills"]).map(&:to_s),
                 })
      end

      private def build_channel_unit(container, spec, errors)
        ext_id = container[:ext_id]
        unless spec.is_a?(Hash) && spec["id"] && spec["adapter"]
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "channel",
                              message: "channel needs both `id` and `adapter`")
          return nil
        end

        adapter_abs = File.join(container[:dir], spec["adapter"])
        unless File.file?(adapter_abs)
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "channel/#{spec['id']}",
                              message: "adapter file not found: #{spec['adapter']}", file: adapter_abs)
          return nil
        end

        Unit.new(kind: :channel, id: spec["id"].to_s, ext_id: ext_id,
                 layer: container[:layer], origin: container[:origin],
                 dir: container[:dir],
                 spec: { "adapter" => spec["adapter"], "adapter_abs" => adapter_abs })
      end

      private def build_patch_unit(container, spec, errors)
        ext_id = container[:ext_id]
        unless spec.is_a?(Hash) && spec["target"] && spec["file"]
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "patch",
                              message: "patch needs both `target` and `file`")
          return nil
        end

        file_abs = File.join(container[:dir], spec["file"])
        unless File.file?(file_abs)
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "patch/#{spec['target']}",
                              message: "patch file not found: #{spec['file']}", file: file_abs)
          return nil
        end

        Unit.new(kind: :patch, id: spec["target"].to_s, ext_id: ext_id,
                 layer: container[:layer], origin: container[:origin],
                 dir: container[:dir],
                 spec: {
                   "target"      => spec["target"].to_s,
                   "file"        => spec["file"],
                   "file_abs"    => file_abs,
                   "fingerprint" => spec["fingerprint"].to_s,
                   "on_mismatch" => (spec["on_mismatch"] || "disable").to_s,
                 })
      end

      private def build_hook_unit(container, spec, errors)
        ext_id = container[:ext_id]
        unless spec.is_a?(Hash) && spec["event"] && spec["file"]
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "hook",
                              message: "hook needs both `event` and `file`")
          return nil
        end

        file_abs = File.join(container[:dir], spec["file"])
        unless File.file?(file_abs)
          errors << Error.new(ext_id: ext_id, layer: container[:layer].to_s, unit: "hook/#{spec['event']}",
                              message: "hook file not found: #{spec['file']}", file: file_abs)
          return nil
        end

        Unit.new(kind: :hook, id: "#{spec['event']}/#{File.basename(spec['file'], '.rb')}", ext_id: ext_id,
                 layer: container[:layer], origin: container[:origin],
                 dir: container[:dir],
                 spec: { "event" => spec["event"].to_s, "file" => spec["file"], "file_abs" => file_abs })
      end
    end
  end
end
