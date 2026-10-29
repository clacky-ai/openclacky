# frozen_string_literal: true

require "yaml"
require "json"
require "time"
require "securerandom"
require "fileutils"

module Clacky
  module Server
    # Scheduler reads ~/.clacky/schedules.yml and runs tasks on a cron-like schedule.
    #
    # It starts a background thread that ticks every 60 seconds, checks all
    # configured schedules, and fires any task whose cron expression matches
    # the current time.
    #
    # Schedule file format (~/.clacky/schedules.yml):
    #
    #   - name: daily_report
    #     task: daily_report          # references ~/.clacky/tasks/daily_report.md
    #     cron: "0 9 * * 1-5"        # standard 5-field cron expression
    #     enabled: true               # optional, defaults to true
    #
    # Cron field order: minute hour day-of-month month day-of-week
    class Scheduler
      SCHEDULES_FILE = File.expand_path("~/.clacky/schedules.yml")
      TASKS_DIR      = File.expand_path("~/.clacky/tasks")
      RUNS_FILE      = File.expand_path("~/.clacky/cron_runs.json")
      MAX_RUNS       = 500

      def initialize(session_registry:, session_builder:, task_runner:)
        @registry        = session_registry
        @session_builder = session_builder  # callable: (name:, working_dir:) -> session_id
        # Callable that runs a task on an agent with unified status/save/broadcast
        # handling — signature: (session_id, agent, &block). Same contract as
        # the one ChannelManager receives.
        @task_runner     = task_runner
        @thread          = nil
        @running         = false
        @mutex           = Mutex.new
        @runs_mutex      = Mutex.new
      end

      # Start the background scheduler thread.
      def start
        @mutex.synchronize do
          return if @running

          # A run still marked running here was cut off by a previous process exit.
          mark_stale_runs_interrupted
          @running = true
          @thread  = Clacky::ThreadRegistry.spawn(name: "clacky-scheduler") { run_loop }
        end
      end

      # Stop the background scheduler thread gracefully.
      # NOTE: intentionally avoids Mutex here so it is safe to call from a
      # signal trap context (Ruby disallows Mutex#synchronize inside traps).
      def stop
        @running = false
        @thread&.wakeup rescue nil
        @thread&.join(5)
      end

      def running?
        @running
      end

      # Return all schedules from the config file.
      def schedules
        load_schedules
      end

      # ── Schedule CRUD ────────────────────────────────────────────────────────

      # Add or update a schedule entry in schedules.yml.
      def add_schedule(name:, task:, cron:, enabled: true)
        list = load_schedules
        # Remove existing entry with the same name
        list.reject! { |s| s["name"] == name }
        list << {
          "name"    => name,
          "task"    => task,
          "cron"    => cron,
          "enabled" => enabled
        }
        save_schedules(list)
      end

      # Remove a schedule entry by name.
      def remove_schedule(name)
        list = load_schedules
        before_count = list.size
        list.reject! { |s| s["name"] == name }
        save_schedules(list)
        list.size < before_count
      end

      # Update an existing schedule entry (cron and/or enabled).
      # Returns false if the schedule does not exist.
      def update_schedule(name, cron: nil, enabled: nil)
        list = load_schedules
        entry = list.find { |s| s["name"] == name }
        return false unless entry

        entry["cron"]    = cron    unless cron.nil?
        entry["enabled"] = enabled unless enabled.nil?
        save_schedules(list)
        true
      end

      # ── Composite cron-task helpers ──────────────────────────────────────────

      # Create a task file and its schedule in one step.
      def create_cron_task(name:, content:, cron:, enabled: true)
        write_task(name, content)
        add_schedule(name: name, task: name, cron: cron, enabled: enabled)
      end

      # Update a cron-task: optionally update content and/or schedule fields.
      def update_cron_task(name, content: nil, cron: nil, enabled: nil)
        raise "Cron task not found: #{name}" unless list_tasks.include?(name)

        write_task(name, content) unless content.nil?
        update_schedule(name, cron: cron, enabled: enabled) if cron || !enabled.nil?
      end

      # Delete a cron-task: remove both the task file and its schedule.
      def delete_cron_task(name)
        removed_schedule = remove_schedule(name)
        removed_task     = delete_task(name)
        removed_schedule || removed_task
      end

      # Return a merged list of cron-tasks (task content + schedule metadata).
      def list_cron_tasks
        schedule_map = load_schedules.each_with_object({}) do |s, h|
          h[s["task"]] = s if s.is_a?(Hash)
        end

        list_tasks.map do |task_name|
          content  = begin; read_task(task_name); rescue StandardError; ""; end
          schedule = schedule_map[task_name] || {}
          cron     = schedule["cron"]
          {
            "name"    => task_name,
            "content" => content,
            "cron"    => cron,
            "enabled" => schedule.fetch("enabled", true),
            "scheduled" => !schedule.empty?,
            "last_run" => last_runs[task_name],
            "next_run" => cron ? cron_next_run(cron) : nil
          }
        end
      end

      # ── Run history ──────────────────────────────────────────────────────────

      # Newest-first run records, optionally narrowed to one task and/or a
      # case-insensitive substring of the task name or error text.
      def list_runs(task: nil, q: nil, limit: 200)
        runs = load_runs.reverse
        runs = runs.select { |r| r["task"] == task } if task && !task.empty?
        if q && !q.strip.empty?
          needle = q.strip.downcase
          runs = runs.select do |r|
            r["task"].to_s.downcase.include?(needle) || r["error"].to_s.downcase.include?(needle)
          end
        end
        runs.first(limit)
      end

      # Record a run around the block, finishing it as success / interrupted /
      # error depending on how the block exits. Re-raises so the caller's own
      # error handling still sees the failure.
      def track_run(task_name, session_id, trigger:)
        run_id = start_run(task_name, session_id, trigger: trigger)
        result = yield
        finish_run(run_id, "success")
        result
      rescue Clacky::AgentInterrupted
        finish_run(run_id, "interrupted")
        raise
      rescue => e
        finish_run(run_id, "error", error: e.message)
        raise
      end

      def start_run(task_name, session_id, trigger:)
        run = {
          "id"          => SecureRandom.hex(6),
          "task"        => task_name,
          "session_id"  => session_id,
          "trigger"     => trigger.to_s,
          "status"      => "running",
          "started_at"  => Time.now.iso8601,
          "finished_at" => nil,
          "error"       => nil
        }
        mutate_runs { |runs| runs << run }
        run["id"]
      end

      def finish_run(run_id, status, error: nil)
        return unless run_id

        mutate_runs do |runs|
          run = runs.find { |r| r["id"] == run_id }
          next unless run

          run["status"]      = status
          run["finished_at"] = Time.now.iso8601
          run["error"]       = error
        end
      end

      def delete_run(run_id)
        removed = false
        mutate_runs { |runs| removed = !runs.reject! { |r| r["id"] == run_id }.nil? }
        removed
      end

      private def last_runs
        load_runs.each_with_object({}) do |r, h|
          h[r["task"]] = r.slice("status", "started_at", "finished_at")
        end
      end

      private def mark_stale_runs_interrupted
        mutate_runs do |runs|
          runs.each do |r|
            next unless r["status"] == "running"

            r["status"]      = "interrupted"
            r["finished_at"] ||= Time.now.iso8601
          end
        end
      rescue => e
        Clacky::Logger.error("scheduler_runs_recover_error", error: e)
      end

      private def mutate_runs
        @runs_mutex.synchronize do
          runs = load_runs
          yield runs
          runs = runs.last(MAX_RUNS)
          FileUtils.mkdir_p(File.dirname(RUNS_FILE))
          File.write(RUNS_FILE, JSON.generate(runs))
        end
      end

      private def load_runs
        return [] unless File.exist?(RUNS_FILE)

        data = JSON.parse(File.read(RUNS_FILE))
        data.is_a?(Array) ? data.select { |r| r.is_a?(Hash) } : []
      rescue JSON::ParserError
        []
      end

      # ── Task file helpers ────────────────────────────────────────────────────

      # Read the prompt content of a named task.
      def read_task(task_name)
        path = task_file_path(task_name)
        raise "Task not found: #{task_name} (expected #{path})" unless File.exist?(path)

        File.read(path)
      end

      # Write the prompt content for a named task.
      def write_task(task_name, content)
        FileUtils.mkdir_p(TASKS_DIR)
        File.write(task_file_path(task_name), content)
      end

      # List all existing task names.
      def list_tasks
        return [] unless Dir.exist?(TASKS_DIR)

        Dir.glob(File.join(TASKS_DIR, "*.md")).map do |path|
          File.basename(path, ".md")
        end.sort
      end

      # Delete a task file and remove all schedules that reference it.
      # Returns true if the task file existed and was deleted, false otherwise.
      def delete_task(task_name)
        path = task_file_path(task_name)
        return false unless File.exist?(path)

        File.delete(path)
        # Remove all schedules referencing this task
        load_schedules.select { |s| s["task"] == task_name }.each do |s|
          remove_schedule(s["name"])
        end
        true
      end

      # Return the file path for a task.
      def task_file_path(task_name)
        File.join(TASKS_DIR, "#{task_name}.md")
      end

      # ── Internal ─────────────────────────────────────────────────────────────

      private def run_loop
        loop do
          begin
            break unless @running

            tick(Time.now)

            # Sleep until the start of the next minute
            now     = Time.now
            sleep_s = 60 - now.sec
            Clacky::Shutdown.sleep(sleep_s)
          rescue => e
            Clacky::Logger.error("scheduler_tick_error", error: e)
            Clacky::Shutdown.sleep(5) # back off before retrying next tick
          end
        end
      end

      # Check all enabled schedules against the given time and fire matching ones.
      private def tick(now)
        maybe_run_backup(now)

        load_schedules.each do |schedule|
          next unless schedule["enabled"] != false
          next unless cron_matches?(schedule["cron"].to_s, now)

          fire_task(schedule)
        rescue => e
          Clacky::Logger.error("scheduler_tick_error", schedule: schedule["name"], error: e)
        end
      end

      # Execute a scheduled task by creating a new agent session.
      private def fire_task(schedule)
        task_name = schedule["task"].to_s
        prompt    = read_task(task_name)
        name      = "⏰ #{schedule["name"]} #{Time.now.strftime("%H:%M")}"

        # Scheduled tasks run unattended — use auto_approve so ask_user doesn't block.
        session_id = @session_builder.call(name: name, permission_mode: :auto_approve, source: :cron)

        Clacky::Logger.info("scheduler_task_fired", task: task_name, session: session_id)

        agent = nil
        @registry.with_session(session_id) { |s| agent = s[:agent] }
        return unless agent

        # Delegate to the unified task runner (same code path as manual runs and
        # channel-triggered runs). It handles:
        #   * status transitions (:running → :idle/:error)
        #   * broadcasting session_update
        #   * persisting the session JSON on success/interrupted/error   ← the bit we were missing
        #   * idle-compression timer lifecycle
        @task_runner.call(session_id, agent) do
          track_run(task_name, session_id, trigger: :schedule) { agent.run(prompt) }
        end

        Clacky::Logger.info("scheduler_task_dispatched", task: task_name, session: session_id)
      rescue => e
        Clacky::Logger.error("scheduler_fire_error", task: schedule["task"], error: e)
      end

      # Built-in automatic backup hook. Runs as a plain system operation —
      # no AI session — when the backup cron matches and auto-backup is enabled.
      private def maybe_run_backup(now)
        cfg = BackupManager.config
        return unless cfg["enabled"]
        return unless cron_matches?(cfg["cron"].to_s, now)

        minute_key = now.strftime("%Y%m%d%H%M")
        return if @last_backup_minute == minute_key

        @last_backup_minute = minute_key
        result = BackupManager.run!
        Clacky::Logger.info("scheduler_backup_done", archive: File.basename(result[:archive]), size: result[:size])
      rescue => e
        Clacky::Logger.error("scheduler_backup_error", error: e)
      end

      # ── Cron parsing ─────────────────────────────────────────────────────────

      # First time the 5-field cron expression fires strictly after +from+.
      # Walks day by day (two years max) and only expands the hour/minute grid
      # for days that match, so a yearly task costs ~365 cheap comparisons.
      # Returns nil for malformed expressions and impossible ones (Feb 30).
      private def cron_next_run(expr, from: Time.now)
        fields = expr.to_s.strip.split(/\s+/)
        return nil unless fields.size == 5

        sets = [
          cron_field_values(fields[0], 0, 59),
          cron_field_values(fields[1], 0, 23),
          cron_field_values(fields[2], 1, 31),
          cron_field_values(fields[3], 1, 12),
          cron_field_values(fields[4], 0, 6)
        ]
        return nil if sets.any?(&:nil?)

        minutes, hours, doms, months, dows = sets
        return nil if minutes.empty? || hours.empty? || doms.empty? || months.empty? || dows.empty?

        # Anchor at noon so a day-step never lands on the wrong date across a
        # DST boundary (Time#+ is absolute seconds, not calendar days).
        noon  = Time.local(from.year, from.month, from.day, 12)
        # Minute-of-day of the first candidate; same-day scans start here.
        floor = from.hour * 60 + from.min + 1

        (0..731).each do |offset|
          day = noon + offset * 86_400
          next unless months.include?(day.month) && doms.include?(day.day) && dows.include?(day.wday)

          limit = offset.zero? ? floor : 0
          hours.each do |h|
            next if h * 60 + minutes.last < limit

            minutes.each do |m|
              next if h * 60 + m < limit

              return Time.local(day.year, day.month, day.day, h, m, 0)
            end
          end
        end

        nil
      end

      # Concrete values a single cron field can take, mirroring the semantics of
      # #cron_part_matches?. Returns nil when the field is unparseable.
      private def cron_field_values(field, min, max)
        values = []
        field.to_s.split(",").each do |part|
          part      = part.strip
          base, step = part.split("/")
          step      = step ? step.to_i : 1
          return nil if step <= 0

          lo, hi = if base == "*"
                     [min, max]
                   elsif base.include?("-")
                     base.split("-").map(&:to_i)
                   else
                     value = Integer(base, exception: false)
                     return nil if value.nil?
                     [value, value]
                   end
          return nil if lo.nil? || hi.nil? || hi < lo

          (lo..hi).each do |v|
            next unless v.between?(min, max)
            # `*` steps from zero (matches value % step), ranges step from lo.
            next unless base == "*" ? (v % step).zero? : ((v - lo) % step).zero?

            values << v
          end
        end
        values.uniq.sort
      end

      # Returns true if the 5-field cron expression matches the given Time.
      # Fields: minute hour day-of-month month day-of-week
      private def cron_matches?(expr, time)
        fields = expr.strip.split(/\s+/)
        return false unless fields.size == 5

        minute, hour, dom, month, dow = fields

        cron_field_matches?(minute, time.min)   &&
          cron_field_matches?(hour,   time.hour)  &&
          cron_field_matches?(dom,    time.day)   &&
          cron_field_matches?(month,  time.month) &&
          cron_field_matches?(dow,    time.wday)
      end

      # Match a single cron field value against the actual time value.
      # Supports: * (any), */n (step), n-m (range), n-m/s (range with step),
      #           and comma-separated lists of the above.
      private def cron_field_matches?(field, value)
        field.split(",").any? { |part| cron_part_matches?(part.strip, value) }
      end

      private def cron_part_matches?(part, value)
        if part == "*"
          true
        elsif part.include?("/")
          base, step = part.split("/")
          step = step.to_i
          return false if step.zero?

          if base == "*"
            (value % step).zero?
          else
            min, max = base.split("-").map(&:to_i)
            max ||= value
            value.between?(min, max) && ((value - min) % step).zero?
          end
        elsif part.include?("-")
          min, max = part.split("-").map(&:to_i)
          value.between?(min, max)
        else
          part.to_i == value
        end
      end

      # ── File I/O ─────────────────────────────────────────────────────────────

      private def load_schedules
        return [] unless File.exist?(SCHEDULES_FILE)

        data = YAMLCompat.load_file(SCHEDULES_FILE, permitted_classes: [Symbol])
        raw  = data.is_a?(Hash) ? data["schedules"] : data
        Array(raw).select { |s| s.is_a?(Hash) }
      rescue => e
        Clacky::Logger.error("scheduler_load_schedules_error", error: e)
        []
      end

      private def save_schedules(list)
        FileUtils.mkdir_p(File.dirname(SCHEDULES_FILE))
        File.write(SCHEDULES_FILE, YAML.dump(list))
      end
    end
  end
end
