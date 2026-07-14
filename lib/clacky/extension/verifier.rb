# frozen_string_literal: true

require "set"

module Clacky
  # Static checks layered on top of ExtensionLoader's structural validation.
  #
  # ExtensionLoader already enforces required fields and file existence per unit
  # while loading. The Verifier adds whole-program checks an AI author needs to
  # close the feedback loop: unknown manifest keys, cross-unit reference
  # integrity, and id collisions across layers (formal "override" warnings).
  #
  # Output is a flat array of Issue records — { ext, unit, level, code, message,
  # file, hint } — each individually addressable so callers can render them in
  # any UI (CLI, Web, JSON for tooling).
  module ExtensionVerifier
    Issue = Struct.new(:ext, :unit, :level, :code, :message, :file, :hint, keyword_init: true)

    KNOWN_TOP_KEYS    = %w[id name title description version origin author homepage license public license_required keywords contributes].freeze
    KNOWN_CONTRIBUTES = %w[panels api skills agents channels patches hooks].freeze

    PANEL_KEYS   = %w[id title title_zh description description_zh view order attach entry_points].freeze
    API_KEYS     = %w[id handler].freeze
    SKILL_KEYS   = %w[id dir protected].freeze
    AGENT_KEYS   = %w[id title title_zh description description_zh order prompt panels skills avatar].freeze
    CHANNEL_KEYS = %w[id platform adapter].freeze
    PATCH_KEYS   = %w[target file fingerprint on_mismatch].freeze
    HOOK_KEYS    = %w[event file].freeze

    ATTACH_TOKEN_RE = /\A(\*|[\w\-]+)\z/.freeze

    class << self
      # Run all checks against a fully-loaded ExtensionLoader::Result. Returns
      # an array of Issue. The result already contains structural Errors from
      # the loader; those are converted to Issues so callers see one stream.
      def verify(result)
        issues = []
        issues.concat(loader_errors_as_issues(result))
        issues.concat(override_issues(result))
        issues.concat(manifest_schema_issues(result))
        issues.concat(reference_issues(result))
        issues
      end

      private def loader_errors_as_issues(result)
        Array(result.errors).map do |err|
          Issue.new(
            ext: err.ext_id, unit: err.unit, level: :error,
            code: "loader.error", message: err.message, file: err.file, hint: nil
          )
        end
      end

      private def override_issues(result)
        Array(result.overridden).map do |(ext_id, losing, winning)|
          Issue.new(
            ext: ext_id, unit: nil, level: :warning, code: "override",
            message: "container present in #{losing} layer is shadowed by #{winning}",
            file: nil, hint: "Remove or rename one copy if the override is unintended."
          )
        end
      end

      private def manifest_schema_issues(result)
        issues = []
        Array(result.containers).each do |ext_id, container|
          dir = container[:dir]
          manifest = read_manifest_safely(dir)
          next unless manifest.is_a?(Hash)

          (manifest.keys.map(&:to_s) - KNOWN_TOP_KEYS).each do |unknown|
            issues << Issue.new(
              ext: ext_id, unit: nil, level: :warning, code: "schema.unknown_key",
              message: "unknown top-level key #{unknown.inspect} in ext.yml",
              file: File.join(dir, "ext.yml"),
              hint: "Allowed: #{KNOWN_TOP_KEYS.join(', ')}"
            )
          end

          contributes = manifest["contributes"]
          next unless contributes.is_a?(Hash)

          (contributes.keys.map(&:to_s) - KNOWN_CONTRIBUTES).each do |unknown|
            issues << Issue.new(
              ext: ext_id, unit: nil, level: :warning, code: "schema.unknown_contributes",
              message: "unknown contributes type #{unknown.inspect}",
              file: File.join(dir, "ext.yml"),
              hint: "Allowed: #{KNOWN_CONTRIBUTES.join(', ')}"
            )
          end

          issues.concat(per_unit_schema_issues(ext_id, dir, contributes))
        end
        issues
      end

      private def per_unit_schema_issues(ext_id, dir, contributes)
        issues = []
        manifest_path = File.join(dir, "ext.yml")

        check_unit_keys(issues, ext_id, manifest_path, contributes["panels"],   PANEL_KEYS,   "panel")
        check_unit_keys(issues, ext_id, manifest_path, contributes["api"],      API_KEYS,     "api")
        check_unit_keys(issues, ext_id, manifest_path, contributes["skills"],   SKILL_KEYS,   "skill")
        check_unit_keys(issues, ext_id, manifest_path, contributes["agents"],   AGENT_KEYS,   "agent")
        check_unit_keys(issues, ext_id, manifest_path, contributes["channels"], CHANNEL_KEYS, "channel")
        check_unit_keys(issues, ext_id, manifest_path, contributes["patches"],  PATCH_KEYS,   "patch")
        check_unit_keys(issues, ext_id, manifest_path, contributes["hooks"],    HOOK_KEYS,    "hook")

        Array(contributes["panels"]).each do |entry|
          next unless entry.is_a?(Hash)
          attach = entry["attach"]
          next if attach.nil?
          unless attach.is_a?(Array) && attach.all? { |t| t.is_a?(String) && t.match?(ATTACH_TOKEN_RE) }
            issues << Issue.new(
              ext: ext_id, unit: entry["id"], level: :error, code: "schema.bad_attach",
              message: "panel `attach` must be an array of agent ids or `\"*\"`, got #{attach.inspect}",
              file: manifest_path, hint: 'Example: attach: [coding]  or  attach: ["*"]'
            )
          end
        end

        issues
      end

      private def check_unit_keys(issues, ext_id, manifest_path, list, allowed, kind_label)
        Array(list).each do |entry|
          next unless entry.is_a?(Hash)
          unknown = entry.keys.map(&:to_s) - allowed
          next if unknown.empty?
          issues << Issue.new(
            ext: ext_id, unit: entry["id"], level: :warning, code: "schema.unknown_field",
            message: "#{kind_label} unit has unknown key(s): #{unknown.join(', ')}",
            file: manifest_path,
            hint: "Allowed for #{kind_label}: #{allowed.join(', ')}"
          )
        end
      end

      private def reference_issues(result)
        issues = []
        panel_ids   = result.panels.map { |u| "#{u.ext_id}/#{u.id}" }.to_set
        agent_ids   = result.agents.map { |u| u.id }.to_set
        skill_ids   = result.skills.map { |u| u.id }.to_set

        result.agents.each do |agent|
          spec = agent.spec || {}

          Array(spec["panels"]).each do |pid|
            ref = pid.include?("/") ? pid : "#{agent.ext_id}/#{pid}"
            next if panel_ids.include?(ref)
            issues << Issue.new(
              ext: agent.ext_id, unit: agent.id, level: :error, code: "ref.missing_panel",
              message: "agent references panel #{pid.inspect} which does not exist",
              file: File.join(agent.dir, "ext.yml"),
              hint: "Define it under contributes.panels or remove the reference."
            )
          end

          Array(spec["skills"]).each do |sid|
            next if skill_ids.include?(sid)
            issues << Issue.new(
              ext: agent.ext_id, unit: agent.id, level: :warning, code: "ref.missing_skill",
              message: "agent references skill #{sid.inspect} which is not contributed by this container",
              file: File.join(agent.dir, "ext.yml"),
              hint: "User-installed default skills resolve at runtime; this is a hint, not a hard error."
            )
          end
        end

        result.panels.each do |panel|
          Array(panel.spec && panel.spec["attach"]).each do |target|
            next if target == "*"
            next if agent_ids.include?(target)
            issues << Issue.new(
              ext: panel.ext_id, unit: panel.id, level: :warning, code: "ref.missing_attach_agent",
              message: "panel `attach` references agent #{target.inspect} not present in any container",
              file: File.join(panel.dir, "ext.yml"),
              hint: "User-defined agents resolve at runtime; verify the id spelling."
            )
          end
        end

        issues
      end

      private def read_manifest_safely(dir)
        require "yaml"
        path = File.join(dir, "ext.yml")
        return nil unless File.file?(path)
        YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {}
      rescue StandardError
        nil
      end
    end
  end
end
