# frozen_string_literal: true

require "fileutils"

module Clacky
  # Scaffolds extension containers for the `ext new` command.
  # Generated containers are complete, runnable examples — the best
  # documentation for an AI author is a working "hello panel" it can copy.
  module ExtensionScaffold
    TEMPLATES_DIR = File.expand_path("scaffold/templates", __dir__)

    class << self
      # Create a new local container with a runnable hello panel + backend.
      # @param full [Boolean] when true, generate a "kitchen-sink" container
      #   exercising all 8 contributes types (panels, api, skills, agents,
      #   channels, patches, hooks, tools) — useful as a learn-by-example
      #   reference.
      # @return [String] path to the created container directory
      def new_container(id, dir: Clacky::ExtensionLoader::LOCAL_DIR, full: false)
        slug = slugify(id)
        raise ArgumentError, "invalid extension id: #{id.inspect}" if slug.empty?

        target = File.join(dir, slug)
        raise ArgumentError, "extension already exists: #{target}" if Dir.exist?(target)

        return new_full_container(slug, target) if full

        FileUtils.mkdir_p(target)
        TemplateRenderer.render(
          template_dir: File.join(TEMPLATES_DIR, "hello"),
          target: target,
          locals: { slug: slug, const_prefix: camelize(slug) }
        )
        target
      end

      private def slugify(id)
        id.to_s.strip.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A-+|-+\z/, "")
      end

      private def camelize(slug)
        slug.split(/[-_]/).map(&:capitalize).join
      end

      private def new_full_container(slug, target)
        FileUtils.mkdir_p(target)
        TemplateRenderer.render(
          template_dir: File.join(TEMPLATES_DIR, "full"),
          target: target,
          locals: { slug: slug, const_prefix: camelize(slug) }
        )
        target
      end
    end
  end
end
