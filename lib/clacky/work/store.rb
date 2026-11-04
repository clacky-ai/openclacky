# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "thread"

module Clacky
  module Work
    # One local server owns this store. Cards and their outbox are committed in
    # the same atomic replacement; a crash cannot leave half a JSON document.
    class Store
      def initialize(path)
        @path = path
        @mutex = Mutex.new
      end

      def read
        @mutex.synchronize { load_data }
      end

      def transaction
        @mutex.synchronize do
          data = load_data
          result = yield data
          FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
          tmp = "#{@path}.#{SecureRandom.hex(6)}.tmp"
          begin
            File.open(tmp, "w", 0o600) do |file|
              file.write(JSON.pretty_generate(data))
              file.flush
              file.fsync
            end
            File.rename(tmp, @path)
          ensure
            FileUtils.rm_f(tmp)
          end
          result
        end
      end


      private def load_data
        return { "cards" => {}, "events" => [] } unless File.exist?(@path)
        data = JSON.parse(File.read(@path)) # Fail closed on corrupt data.
        # Read old cards/outboxes without rewriting history or requiring migration.
        data["cards"].each_value do |card|
          card["status"] = { "waiting_reply" => "waiting_event", "waiting_user" => "needs_input" }.fetch(card["status"], card["status"])
          Array(card["outbox"]).each do |event|
            event["kind"] = "needs_input" if event["kind"] == "needs_user"
          end
        end
        data
      end
    end
  end
end
