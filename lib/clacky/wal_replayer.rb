# frozen_string_literal: true

require "json"

module Clacky
  # WalReplayer replays a Write-Ahead Log (.wal) file against a base message list
  # to recover state lost when the process was killed (SIGKILL / OOM) between
  # in-memory @history mutations and the next session.json save.
  #
  # Lifecycle (see SessionSerializer#restore_session):
  #   1. load session.json → base messages + saved wal_seq
  #   2. if {session_id}.wal exists → WalReplayer.replay(messages, wal_path, skip_seq_below: wal_seq)
  #   3. delete old .wal; new writes create a fresh one
  #
  # Each WAL line is a JSON event: { "seq": N, "op": "...", ... }
  # The seq field provides idempotency — events with seq ≤ wal_seq (already in
  # session.json) are skipped during replay.
  class WalReplayer
    # Replay all events in a WAL file against the given message list.
    #
    # @param messages [Array<Hash>] base messages from session.json
    # @param wal_path [String] path to the .wal file
    # @param skip_seq_below [Integer] skip events with seq ≤ this value (idempotency)
    # @return [Array(Array<Hash>, Integer)] recovered messages and max seq applied
    def self.replay(messages, wal_path, skip_seq_below: 0)
      events = parse_wal(wal_path)
      return [messages, skip_seq_below] if events.empty?

      max_seq = skip_seq_below

      events.sort_by { |e| e[:seq] }.each do |ev|
        next if ev[:seq] <= skip_seq_below

        max_seq = [max_seq, ev[:seq]].max
        messages = apply_event(messages, ev)
      end

      [messages, max_seq]
    end

    # Parse a WAL file (JSONL) into an array of event hashes.
    # Corrupted lines (e.g. partial write before crash) are skipped with a warning.
    def self.parse_wal(path)
      events = []
      File.foreach(path, encoding: "UTF-8") do |line|
        line = line.strip
        next if line.empty?

        begin
          events << JSON.parse(line, symbolize_names: true)
        rescue JSON::ParserError
          # Last line may be a partial write — skip it
          Clacky::Logger&.warn("WAL: skipping corrupted line: #{line[0..80]}...")
        end
      end
      events
    rescue Errno::ENOENT
      []
    rescue => e
      Clacky::Logger&.warn("WAL parse failed: #{e.message}")
      []
    end

    # Apply a single WAL event to the message list, returning the updated list.
    def self.apply_event(messages, ev)
      case ev[:op]
      when "append"
        messages + [ev[:msg]]
      when "replace_all"
        ev[:messages].dup
      when "replace_system_prompt"
        idx = messages.index { |m| m[:role] == "system" }
        if idx
          messages.dup.tap { |ms| ms[idx] = ev[:msg] }
        else
          [ev[:msg]] + messages
        end
      when "pop_last"
        messages[0..-2]
      when "delete_where"
        # indices were captured at write time; apply in reverse to preserve positions
        indices = Array(ev[:indices]).sort.reverse
        result = messages.dup
        indices.each { |i| result.delete_at(i) if i < result.length }
        result
      when "truncate_from", "rollback_before"
        messages[0...ev[:index]]
      when "truncate_from_created_at"
        idx = messages.index { |m| m[:role] == "user" && m[:created_at].to_s == ev[:created_at].to_s }
        idx ? messages[0...idx] : messages
      when "attach_to_tool_result"
        messages.map do |m|
          if (m[:role] == "tool" && m[:tool_call_id] == ev[:tool_call_id]) ||
             (m[:role] == "user" && m[:content].is_a?(Array) &&
               m[:content].any? { |b| b.is_a?(Hash) && b[:type] == "tool_result" && b[:tool_use_id] == ev[:tool_call_id] })
            m.merge(ev[:key] => ev[:value])
          else
            m
          end
        end
      when "mutate_last_matching"
        idx = ev[:index]
        if idx && idx < messages.length
          messages.dup.tap { |ms| ms[idx] = ev[:msg] }
        else
          messages
        end
      else
        Clacky::Logger&.warn("WAL: unknown op #{ev[:op]}, skipping")
        messages
      end
    end
  end
end
