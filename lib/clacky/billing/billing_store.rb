# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "billing_record"

module Clacky
  module Billing
    # Persistent storage for billing records using JSONL files
    # Records are stored in monthly files: ~/.clacky/billing/YYYY-MM.jsonl
    class BillingStore
      BILLING_DIR = File.join(Dir.home, ".clacky", "billing")

      def initialize(billing_dir: nil)
        @billing_dir = billing_dir || BILLING_DIR
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
      # @param limit [Integer, nil] Maximum number of records to return
      # @return [Array<BillingRecord>] Matching records, newest first
      def query(from: nil, to: nil, model: nil, session_id: nil, limit: nil)
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
      # @return [Hash] Summary with total_cost, total_tokens, by_model, etc.
      def summary(period: :month, model: nil)
        from_time = period_start(period)
        records = query(from: from_time, model: model)

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

      # Get daily cost breakdown for the last N days
      # @param days [Integer] Number of days to include
      # @param model [String, nil] Filter by model name
      # @return [Array<Hash>] Daily summaries with date and cost
      def daily_breakdown(days: 30, model: nil)
        from_time = Time.now - (days * 24 * 60 * 60)
        records = query(from: from_time, model: model)

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
          now - (7 * 24 * 60 * 60)
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
