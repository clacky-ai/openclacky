# frozen_string_literal: true

module Clacky
  # Pending guidance belongs to the fixed composer area, not the transcript.
  module CliGuidance
    def on_guidance_action(&block)
      @guidance_action = block
    end

    def request_guidance_action(action)
      entry = (@guidance_entries || []).last
      return false unless entry && @guidance_action
      dispatch_guidance_action(action, entry[:id])
      true
    end

    def dispatch_guidance_action(action, id)
      @guidance_action.call(action, id)
    end

    def guidance_control?(text)
      text.to_s.match?(%r{\A/input-mode(?:\s|\z)})
    end

    def guidance_deferred?(text)
      guidance_control?(text) || !!queue_input_while_running&.call
    end

    def guidance_lines
      entries = @guidance_entries || []
      return [] if entries.empty?

      previews = entries.last(3).map do |entry|
        text = entry[:content].to_s
        if text.strip.empty?
          text = Array(entry.dig(:options, :files)).map { |f| f[:name] || f["name"] }.compact.join(", ")
        end
        "  · #{text.gsub(/[[:cntrl:]]/, ' ').gsub(/\s+/, ' ').strip}"
      end
      ["Pending · Ctrl+D delete last · Ctrl+G send now", *(entries.size > 3 ? ["  … #{entries.size - 3} earlier"] : []), *previews]
    end

    def show_input_queue(entries)
      @guidance_entries = entries
      refresh_guidance if respond_to?(:refresh_guidance)
    end
  end
end
