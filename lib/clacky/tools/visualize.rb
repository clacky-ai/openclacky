# frozen_string_literal: true

module Clacky
  module Tools
    class Visualize < Base
      DEFAULT_HEIGHT = 420
      MIN_HEIGHT = 240
      MAX_HEIGHT = 720

      self.tool_name = "visualize"
      self.tool_description = <<~DESC.strip
        Render a self-contained interactive HTML visualization in the conversation. Use this when
        interaction materially improves understanding, and include the key conclusion in your text
        response too. The HTML must not depend on external scripts, styles, fonts, or network requests.
      DESC
      self.tool_category = "general"
      self.tool_parameters = {
        type: "object",
        properties: {
          title: {
            type: "string",
            description: "Short title shown above the visualization"
          },
          html: {
            type: "string",
            description: "Self-contained HTML fragment with optional inline CSS and JavaScript. " \
                         "Theme tokens include --clacky-bg, --clacky-surface, --clacky-text, " \
                         "--clacky-muted, --clacky-border, and --clacky-accent."
          },
          height: {
            type: "integer",
            description: "Initial height in pixels",
            minimum: MIN_HEIGHT,
            maximum: MAX_HEIGHT,
            default: DEFAULT_HEIGHT
          }
        },
        required: %w[title html]
      }

      def initialize(store: ArtifactStore.new)
        @store = store
      end

      def execute(title:, html:, height: DEFAULT_HEIGHT, working_dir: nil)
        display_title = title.to_s.strip
        return { error: "Title cannot be empty" } if display_title.empty?

        stored = @store.write(html)
        {
          artifact_id: stored[:id],
          title: display_title[0, 120],
          height: clamp_height(height),
          bytes: stored[:bytes],
          error: nil
        }
      rescue ArtifactStore::Error => e
        { error: e.message }
      end

      def format_call(args)
        title = args[:title] || args["title"] || ""
        %(visualize("#{title.to_s[0, 40]}"))
      end

      def format_result(result)
        error = result[:error] || result["error"]
        return "[Error] #{error}" if error

        bytes = result[:bytes] || result["bytes"] || 0
        "[OK] Created visualization (#{bytes} bytes)"
      end

      def ui_result(result)
        error = result[:error] || result["error"]
        return nil if error

        {
          type: "artifact",
          kind: "html",
          artifact_id: result[:artifact_id] || result["artifact_id"],
          title: result[:title] || result["title"],
          height: clamp_height(result[:height] || result["height"])
        }
      end

      private def clamp_height(height)
        [[Integer(height || DEFAULT_HEIGHT), MIN_HEIGHT].max, MAX_HEIGHT].min
      rescue ArgumentError, TypeError
        DEFAULT_HEIGHT
      end
    end
  end
end
