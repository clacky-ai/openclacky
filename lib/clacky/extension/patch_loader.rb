# frozen_string_literal: true

require "digest"
require "fileutils"
require "yaml"

begin
  require "prism"
rescue LoadError
  # Prism is a stdlib on Ruby 3.3+. On older Rubies we fall back to
  # RubyVM::AbstractSyntaxTree (available since 2.6).
end

module Clacky
  # Runtime patch layer. Loads user/AI-authored patches from ~/.clacky/patches/
  # that override existing methods via Module#prepend, WITHOUT touching the
  # installed gem source (so `gem update` never loses them).
  #
  # Each patch lives in its own directory:
  #   ~/.clacky/patches/<id>/
  #     meta.yml    declares target + a fingerprint of the original method source
  #     patch.rb    a prepend module that overrides the target method
  #
  # Safety — fingerprint drift:
  #   meta.yml records a SHA256 of the targeted method's source at authoring time.
  #   Before applying, the loader recomputes the fingerprint of the method as it
  #   exists in the CURRENTLY installed gem. If they differ, the upstream code has
  #   changed and the patch may no longer be valid, so by default the patch is
  #   DISABLED (moved to _disabled/) rather than applied — a stale patch must never
  #   silently corrupt behavior.
  #
  # meta.yml:
  #   id: fix-web-search-timeout
  #   description: bump default timeout to 30s
  #   target: "Clacky::Tools::WebSearch#execute"   # '#' = instance, '.' = class method
  #   fingerprint: "a3f8c…"
  #   gem_version: "0.7.0"
  #   on_mismatch: disable                         # disable | warn (default disable)
  module PatchLoader
    DEFAULT_DIR  = File.join(Clacky.data_dir, "patches")
    DISABLED_DIR = "_disabled"

    Result = Struct.new(:applied, :disabled, :skipped, keyword_init: true)

    class << self
      def load_all(dir: DEFAULT_DIR)
        result = Result.new(applied: [], disabled: [], skipped: [])
        if Dir.exist?(dir)
          Dir.glob(File.join(dir, "*", "meta.yml")).sort.each do |meta_path|
            patch_dir = File.dirname(meta_path)
            next if File.basename(File.dirname(patch_dir)) == DISABLED_DIR

            apply_one(patch_dir, meta_path, result)
          end
        end
        load_extension_patches(result)
        @last_result = result
        result
      end

      # Apply patches contributed by ext.yml containers (contributes.patches).
      # ext.yml-driven patches use a flat shape (target + file [+ fingerprint])
      # rather than the per-dir meta.yml + patch.rb layout, since the container
      # author already owns the upgrade lifecycle. If `fingerprint` is given in
      # ext.yml we still verify it; if absent we trust the author and require
      # the file directly. Errors are isolated to that single patch.
      def load_extension_patches(result)
        units = Array(Clacky::ExtensionLoader.last_result&.patches)
        units.each do |unit|
          target   = unit.spec["target"]
          file_abs = unit.spec["file_abs"]
          recorded = unit.spec["fingerprint"].to_s
          id       = "#{unit.ext_id}/#{File.basename(unit.spec['file'], '.rb')}"

          if recorded.empty?
            require file_abs
            result.applied << id
            log(:info, id, "applied → #{target} (no fingerprint, trusted)")
            next
          end

          current = fingerprint(target)
          if current != recorded
            reason = "fingerprint mismatch — upstream code for #{target} changed"
            if unit.spec["on_mismatch"] == "warn"
              result.skipped << [id, "#{reason} (kept, not applied)"]
              log(:warn, id, result.skipped.last[1])
            else
              result.skipped << [id, "#{reason} — disabled"]
              log(:warn, id, result.skipped.last[1])
            end
            next
          end

          require file_abs
          result.applied << id
          log(:info, id, "applied → #{target}")
        rescue StandardError, ScriptError => e
          fallback_id = "#{unit&.ext_id}/#{File.basename(unit&.spec&.[]('file').to_s, '.rb')}"
          result.skipped << [fallback_id, e.message]
          log(:warn, fallback_id, e.message)
        end
      end

      def last_result
        @last_result || load_all
      end

      # Generate a ready-to-edit patch (meta.yml + patch.rb) for a target method.
      # Computes the current fingerprint automatically so the author never does it
      # by hand. The patch.rb skeleton prepends a module that overrides the method
      # and calls super by default.
      # @param target [String] "Const::Path#method" or "Const::Path.method"
      # @return [String] path to the new patch directory
      def scaffold(id, target, description: "", dir: DEFAULT_DIR)
        slug = id.to_s.strip.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A-+|-+\z/, "")
        raise ArgumentError, "invalid patch id: #{id.inspect}" if slug.empty?

        fp = fingerprint(target)  # also validates the target resolves

        patch_dir = File.join(dir, slug)
        raise ArgumentError, "patch already exists: #{patch_dir}" if Dir.exist?(patch_dir)

        FileUtils.mkdir_p(patch_dir)
        File.write(File.join(patch_dir, "meta.yml"), <<~YAML)
          id: #{slug}
          description: #{description.to_s.empty? ? "(describe what this fixes)" : description}
          target: "#{target}"
          fingerprint: "#{fp}"
          gem_version: "#{Clacky::VERSION}"
          on_mismatch: disable
        YAML
        File.write(File.join(patch_dir, "patch.rb"), patch_skeleton(slug, target))
        patch_dir
      end

      def patch_skeleton(slug, target)
        const_name, sep, method_name = target.partition(/[#.]/)
        mod_const = "Patch_#{slug.gsub(/[^a-zA-Z0-9_]/, "_")}"
        prepend_target = sep == "#" ? const_name : "#{const_name}.singleton_class"

        <<~RUBY
          # frozen_string_literal: true

          # Patch for #{target}
          # Only edit the method body below. Call `super` to keep the original behavior.
          module #{mod_const}
            def #{method_name}(*args, **kwargs, &blk)
              # TODO: your fix here. Examples:
              #   result = super
              #   result
              super
            end
          end

          #{prepend_target}.prepend(#{mod_const})
        RUBY
      end

      # Recompute the fingerprint of a target's method as currently installed.
      # @param target [String] "Const::Path#instance_method" or "Const::Path.class_method"
      # @return [String] SHA256 hex of the method's source
      # @raise [RuntimeError] if the target can't be resolved
      def fingerprint(target)
        meth = original_method(resolve_method(target))
        file, lineno = meth.source_location
        raise "no source location for #{target} (defined in C or eval?)" unless file && lineno

        first, last = method_line_range(file, lineno, meth.name, meth)
        raise "cannot locate source for #{target} in #{file}:#{lineno}" unless first && last

        lines = File.readlines(file)[(first - 1)...last]
        Digest::SHA256.hexdigest(lines.join)
      end

      def method_line_range(file, lineno, name, meth)
        if defined?(Prism)
          range = prism_line_range(file, lineno, name)
          return range if range
        end

        ast_line_range(meth)
      end

      def prism_line_range(file, lineno, name)
        result = Prism.parse_file(file)
        return nil unless result.success?

        node = find_def_at(result.value, lineno, name.to_sym)
        return nil unless node

        loc = node.location
        [loc.start_line, loc.end_line]
      end

      def find_def_at(node, lineno, name)
        return nil unless node

        if node.is_a?(Prism::DefNode) && node.name == name && node.location.start_line == lineno
          return node
        end

        node.compact_child_nodes.each do |child|
          found = find_def_at(child, lineno, name)
          return found if found
        end
        nil
      end

      def ast_line_range(meth)
        return nil unless defined?(RubyVM::AbstractSyntaxTree)

        node = RubyVM::AbstractSyntaxTree.of(meth)
        return nil unless node

        [node.first_lineno, node.last_lineno]
      rescue StandardError
        nil
      end

      # Walk past any methods introduced by our own patches (files under the
      # patches dir) so the fingerprint always reflects the original upstream
      # definition, even after a prepend has already been applied.
      def original_method(meth)
        current = meth
        while current
          file, = current.source_location
          break if file.nil? || !file.start_with?(DEFAULT_DIR)

          nxt = current.super_method
          break if nxt.nil?

          current = nxt
        end
        current
      end

      def resolve_method(target)
        if target.include?("#")
          const_name, method_name = target.split("#", 2)
          const = resolve_const(const_name)
          const.instance_method(method_name.to_sym)
        elsif target.include?(".")
          const_name, method_name = target.split(".", 2)
          const = resolve_const(const_name)
          const.method(method_name.to_sym)
        else
          raise "invalid target (need '#' or '.'): #{target}"
        end
      end

      def apply_one(patch_dir, meta_path, result)
        id = File.basename(patch_dir)
        meta = YAMLCompat.load_file(meta_path) || {}
        target = meta["target"].to_s
        recorded = meta["fingerprint"].to_s

        if target.empty? || recorded.empty?
          result.skipped << [id, "meta.yml missing target or fingerprint"]
          log(:warn, id, result.skipped.last[1])
          return
        end

        current = begin
          fingerprint(target)
        rescue StandardError => e
          result.skipped << [id, "cannot fingerprint #{target}: #{e.message}"]
          log(:warn, id, result.skipped.last[1])
          return
        end

        if current != recorded
          handle_mismatch(patch_dir, id, meta, result)
          return
        end

        patch_rb = File.join(patch_dir, "patch.rb")
        unless File.exist?(patch_rb)
          result.skipped << [id, "patch.rb not found"]
          log(:warn, id, result.skipped.last[1])
          return
        end

        require patch_rb
        result.applied << id
        log(:info, id, "applied → #{target}")
      rescue StandardError, ScriptError => e
        result.skipped << [id, e.message]
        log(:warn, id, e.message)
      end

      def handle_mismatch(patch_dir, id, meta, result)
        reason = "fingerprint mismatch — upstream code for #{meta["target"]} changed"
        if meta["on_mismatch"].to_s == "warn"
          result.skipped << [id, "#{reason} (kept, not applied)"]
          log(:warn, id, result.skipped.last[1])
          return
        end

        disable!(patch_dir, id)
        result.disabled << [id, reason]
        log(:warn, id, "#{reason} — disabled")
      end

      def disable!(patch_dir, id)
        base = File.dirname(patch_dir)
        dest_root = File.join(base, DISABLED_DIR)
        FileUtils.mkdir_p(dest_root)
        dest = File.join(dest_root, id)
        FileUtils.rm_rf(dest)
        FileUtils.mv(patch_dir, dest)
      rescue StandardError => e
        log(:error, id, "failed to disable: #{e.message}")
      end

      def resolve_const(name)
        name.split("::").reject(&:empty?).inject(Object) do |mod, part|
          mod.const_get(part)
        end
      end

      def log(level, id, msg)
        Clacky::Logger.public_send(level, "[PatchLoader] #{id}: #{msg}")
      end
    end
  end
end
