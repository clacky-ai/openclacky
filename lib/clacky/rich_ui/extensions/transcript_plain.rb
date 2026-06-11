# frozen_string_literal: true

require "ruby_rich"

module Clacky
  module RichUI
    module Extensions
      module TranscriptPlain
        def self.apply!
          RubyRich::Transcript.class_eval do
            unless private_method_defined?(:clacky_render_entry_without_plain)
              alias_method :clacky_render_entry_without_plain, :render_entry

              def render_entry(entry, index)
                if entry.metadata[:plain]
                  entry.content.to_s.split("\n", -1)
                else
                  clacky_render_entry_without_plain(entry, index)
                end
              end

              private :render_entry
            end
          end
        end
      end
    end
  end
end
