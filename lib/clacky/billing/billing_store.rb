# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "billing_record"
require_relative "../session_manager"
require_relative "../providers"
module Clacky
  module Billing
    # Persistent storage for billing records using JSONL files
    # Records are stored in monthly files: ~/.clacky/billing/YYYY-MM.jsonl
    class BillingStore
      BILLING_DIR = File.join(Dir.home, ".clacky", "billing")

      # Preset keys that hold the openclacky model lineup (chat + media sidecars).
      OPENCLACKY_MODEL_KINDS = %w[models image_models video_models audio_models stt_models video_understanding_models].freeze

      # All openclacky model aliases, collected from the provider preset so the
      # list never drifts from providers.rb as models are added or removed.
      def openclacky_models
        @openclacky_models ||= begin
          preset = Clacky::Providers.get("openclacky")
          return [] unless preset
          OPENCLACKY_MODEL_KINDS.flat_map { |kind| preset[kind] || [] }.uniq
        end
      end

      # True when a record belongs to the openclacky provider. New records
      # carry an explicit provider id; legacy records (written before the
      # field existed) are detected by matching the full openclacky model list.
      def openclacky_record?(record)
        return true if record.provider == "openclacky"
        openclacky_models.include?(record.model.to_s)
      end

      def initialize(billing_dir: nil)
        @billing_dir = billing_dir || ENV["CLACKY_BILLING_DIR"] || BILLING_DIR
        ensure_billing_dir
      end

      # Append a billing record to the current month's file
      # @param record [BillingRecord] The record to append
      # @return [String] The record ID
      def append(record)
        record.id ||= SecureRandom.uuid
        record.timestamp ||= Time.now

        month_file = current_month_file
        File.open(month_file, "a") do |f|
          f.puts(JSON.generate(record.to_h))
        end
        FileUtils.chmod(0o600, month_file)

        record.id
      end

      # Query billing records with optional filters
      # @param from [Time, nil] Start time (inclusive)
      # @param to [Time, nil] End time (inclusive)
      # @param model [String, nil] Filter by model name
      # @param session_id [String, nil] Filter by session ID
      # @param exclude_openclacky [Boolean] Skip openclacky-provider records
      # @param limit [Integer, nil] Maximum number of records to return
      # @return [Array<BillingRecord>] Matching records, newest first
      def query(from: nil, to: nil, model: nil, session_id: nil, exclude_openclacky: false, limit: nil)
        records = []

        billing_files.each do |file|
          File.foreach(file) do |line|
            next if line.strip.empty?

            begin
              hash = JSON.parse(line, symbolize_names: true)
              record = BillingRecord.from_h(hash)

              # Apply filters
              next if from && record.timestamp < from
              next if to && record.timestamp > to
              next if model && record.model != model
              next if session_id && record.session_id != session_id
              next if exclude_openclacky && openclacky_record?(record)

              records << record
            rescue JSON::ParserError
              # Skip malformed lines
              next
            end
          end
        end

        # Sort by timestamp descending (newest first)
        records.sort_by! { |r| r.timestamp }.reverse!

        # Apply limit
        limit ? records.first(limit) : records
      end

      # Get summary statistics for a time period
      # @param period [Symbol] :day, :week, :month, :year, or :all
      # @param model [String, nil] Filter by model name
      # @param exclude_openclacky [Boolean] Skip openclacky-provider records
      # @return [Hash] Summary with total_cost, total_tokens, by_model, etc.
      def summary(period: :month, model: nil, exclude_openclacky: false)
        from_time = period_start(period)
        records = query(from: from_time, model: model, exclude_openclacky: exclude_openclacky)

        total_cost = records.sum { |r| r.cost_usd || 0 }
        total_prompt = records.sum { |r| r.prompt_tokens || 0 }
        total_completion = records.sum { |r| r.completion_tokens || 0 }
        total_cache_read = records.sum { |r| r.cache_read_tokens || 0 }
        total_cache_write = records.sum { |r| r.cache_write_tokens || 0 }

        by_model = records.group_by(&:model).transform_values do |rs|
          {
            cost: rs.sum { |r| r.cost_usd || 0 },
            prompt_tokens: rs.sum { |r| r.prompt_tokens || 0 },
            completion_tokens: rs.sum { |r| r.completion_tokens || 0 },
            requests: rs.size
          }
        end

        by_day = records.group_by { |r| r.timestamp.strftime("%Y-%m-%d") }.transform_values do |rs|
          rs.sum { |r| r.cost_usd || 0 }
        end

        {
          period: period,
          from: from_time&.iso8601,
          to: Time.now.iso8601,
          total_cost: total_cost.round(6),
          total_tokens: total_prompt + total_completion,
          prompt_tokens: total_prompt,
          completion_tokens: total_completion,
          cache_read_tokens: total_cache_read,
          cache_write_tokens: total_cache_write,
          by_model: by_model,
          by_day: by_day,
          record_count: records.size
        }
      end

      # Get session-level summary statistics
      # @param period [Symbol] :day, :week, :month, :year, or :all
      # @param model [String, nil] Filter by model name
      # @param limit [Integer] Maximum number of sessions to return
      # @return [Array<Hash>] Session summaries sorted by cost descending
      def session_summary(period: :month, model: nil, limit: 50)
        from_time = period_start(period)
        records = query(from: from_time, model: model)

        # Load session names from session manager
        session_names = load_session_names

        # Group by session_id
        by_session = records.group_by { |r| r.session_id || "unknown" }

        active_sessions = []
        deleted_records = []

        by_session.each do |session_id, rs|
          total_cost = rs.sum { |r| r.cost_usd || 0 }
          total_prompt = rs.sum { |r| r.prompt_tokens || 0 }
          total_completion = rs.sum { |r| r.completion_tokens || 0 }
          total_cache_read = rs.sum { |r| r.cache_read_tokens || 0 }
          total_cache_write = rs.sum { |r| r.cache_write_tokens || 0 }
          first_record = rs.min_by { |r| r.timestamp }
          last_record = rs.max_by { |r| r.timestamp }

          entry = {
            session_id: session_id,
            session_name: session_names[session_id],
            total_cost: total_cost.round(6),
            total_tokens: total_prompt + total_completion,
            prompt_tokens: total_prompt,
            completion_tokens: total_completion,
            cache_read_tokens: total_cache_read,
            cache_write_tokens: total_cache_write,
            requests: rs.size,
            first_request: first_record&.timestamp&.iso8601,
            last_request: last_record&.timestamp&.iso8601,
            models: rs.map(&:model).uniq
          }

          if session_names[session_id]
            active_sessions << entry
          else
            deleted_records << entry
          end
        end

        # Merge all deleted sessions into a single row
        if deleted_records.any?
          merged = {
            session_id: "_deleted_",
            session_name: nil,
            is_deleted: true,
            total_cost: deleted_records.sum { |r| r[:total_cost] }.round(6),
            total_tokens: deleted_records.sum { |r| r[:total_tokens] },
            prompt_tokens: deleted_records.sum { |r| r[:prompt_tokens] },
            completion_tokens: deleted_records.sum { |r| r[:completion_tokens] },
            cache_read_tokens: deleted_records.sum { |r| r[:cache_read_tokens] },
            cache_write_tokens: deleted_records.sum { |r| r[:cache_write_tokens] },
            requests: deleted_records.sum { |r| r[:requests] },
            first_request: deleted_records.map { |r| r[:first_request] }.compact.min,
            last_request: deleted_records.map { |r| r[:last_request] }.compact.max,
            models: deleted_records.flat_map { |r| r[:models] }.uniq
          }
          active_sessions << merged
        end

        # Sort by total cost descending
        active_sessions.sort_by! { |s| -s[:total_cost] }

        # Apply limit
        limit ? active_sessions.first(limit) : active_sessions
      end

      # Load session names from session manager (including trashed sessions)
      # Returns a hash mapping session_id to session name
      def load_session_names
        names = {}
        begin
          # Load from active sessions
          manager = Clacky::SessionManager.new
          manager.all_sessions.each do |session|
            id = session[:session_id]
            name = session[:name]
            names[id] = name if id && name && !name.to_s.empty?
          end

          # Also load from trashed sessions
          trash_dir = File.join(Dir.home, ".clacky", "trash", "sessions-trash")
          if Dir.exist?(trash_dir)
            Dir.glob(File.join(trash_dir, "*.json")).each do |filepath|
              session = JSON.parse(File.read(filepath), symbolize_names: true) rescue next
              id = session[:session_id]
              name = session[:name]
              names[id] = name if id && name && !name.to_s.empty?
            end
          end
        rescue => e
          # Silently fail if session manager is not available
        end
        names
      end

      # Get daily cost breakdown for the last N days      # @param days [Integer] Number of days to include
      # @param model [String, nil] Filter by model name
      # @param exclude_openclacky [Boolean] Skip openclacky-provider records
      # @return [Array<Hash>] Daily summaries with date and cost
      def daily_breakdown(days: 30, model: nil, exclude_openclacky: false)
        from_time = Time.now - (days * 24 * 60 * 60)
        records = query(from: from_time, model: model, exclude_openclacky: exclude_openclacky)

        by_day = records.group_by { |r| r.timestamp.strftime("%Y-%m-%d") }

        (0...days).map do |i|
          date = (Time.now - (i * 24 * 60 * 60)).strftime("%Y-%m-%d")
          day_records = by_day[date] || []
          {
            date: date,
            cost: day_records.sum { |r| r.cost_usd || 0 }.round(6),
            tokens: day_records.sum { |r| r.total_tokens },
            prompt_tokens: day_records.sum { |r| r.prompt_tokens || 0 },
            completion_tokens: day_records.sum { |r| r.completion_tokens || 0 },
            cache_read_tokens: day_records.sum { |r| r.cache_read_tokens || 0 },
            cache_write_tokens: day_records.sum { |r| r.cache_write_tokens || 0 },
            requests: day_records.size
          }
        end.reverse
      end

      # Delete old billing records
      # @param before [Time] Delete records before this time
      # @return [Integer] Number of files deleted
      def cleanup(before:)
        deleted = 0
        billing_files.each do |file|
          # Parse month from filename (YYYY-MM.jsonl)
          basename = File.basename(file, ".jsonl")
          file_month = Time.parse("#{basename}-01") rescue nil
          next unless file_month

          # Delete if the entire month is before the cutoff
          if file_month < before - (31 * 24 * 60 * 60)
            File.delete(file)
            deleted += 1
          end
        end
        deleted
      end

      # Clear billing records
      # @param scope [Symbol] :today or :all
      # @return [Integer] Number of records/files deleted
      def clear(scope: :today)
        case scope
        when :today
          clear_today
        when :all
          clear_all
        else
          0
        end
      end

      private def clear_today
        # Remove today's records from the current month file
        month_file = current_month_file
        return 0 unless File.exist?(month_file)

        today_start = Time.new(Time.now.year, Time.now.month, Time.now.day)
        kept_lines = []
        deleted_count = 0

        File.foreach(month_file) do |line|
          next if line.strip.empty?

          begin
            hash = JSON.parse(line, symbolize_names: true)
            record_time = Time.parse(hash[:timestamp].to_s) rescue nil

            if record_time && record_time >= today_start
              deleted_count += 1
            else
              kept_lines << line
            end
          rescue JSON::ParserError
            kept_lines << line
          end
        end

        # Rewrite the file without today's records
        File.open(month_file, "w") do |f|
          kept_lines.each { |line| f.print(line) }
        end
        FileUtils.chmod(0o600, month_file) if File.exist?(month_file)

        deleted_count
      end

      private def clear_all
        # Delete all billing files
        files = billing_files
        files.each { |f| File.delete(f) }
        files.size
      end

      private def ensure_billing_dir
        FileUtils.mkdir_p(@billing_dir) unless Dir.exist?(@billing_dir)
      end

      private def current_month_file
        File.join(@billing_dir, "#{Time.now.strftime('%Y-%m')}.jsonl")
      end

      private def billing_files
        Dir.glob(File.join(@billing_dir, "*.jsonl")).sort.reverse
      end

      private def period_start(period)
        now = Time.now
        case period
        when :day
          Time.new(now.year, now.month, now.day)
        when :week
          days_since_monday = now.wday == 0 ? 6 : now.wday - 1
          Time.new(now.year, now.month, now.day) - (days_since_monday * 24 * 60 * 60)
        when :month
          Time.new(now.year, now.month, 1)
        when :year
          Time.new(now.year, 1, 1)
        when :all
          nil
        else
          Time.new(now.year, now.month, 1)
        end
      end
    end
  end
end
