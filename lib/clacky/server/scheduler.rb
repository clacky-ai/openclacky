# frozen_string_literal: true

require "yaml"
require "json"
require "time"
require "securerandom"
require "fileutils"
require "monitor"
require "date"

module Clacky
  module Server
    # Scheduler reads ~/.clacky/schedules.yml and runs tasks on a cron-like schedule.
    #
    # It starts a background thread that ticks every 60 seconds, checks all
    # configured schedules, and dispatches due tasks. Persisted next-run cursors
    # allow a resumed process to catch up the latest missed occurrence.
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

      def initialize(session_registry:, session_builder:, task_runner:, scheduled_dispatcher: nil)
        @scheduled_dispatcher = scheduled_dispatcher
        @schedule_mutex = Monitor.new
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
      def add_schedule(name:, task:, cron:, enabled: true, target: nil)
        due = cron_next_run(cron)
        raise ArgumentError, "Invalid or impossible cron schedule" unless due
        @schedule_mutex.synchronize do
          list = load_schedules
          list.reject! { |s| s["name"] == name }
          list << {
            "id" => SecureRandom.hex(12), "name" => name, "task" => task,
            "cron" => cron, "enabled" => enabled,
            "target" => target, "next_run_at" => due.utc.iso8601
          }
          save_schedules(list)
        end
      end

      # Remove a schedule entry by name.
      def remove_schedule(name)
        @schedule_mutex.synchronize do
          list = load_schedules
          before_count = list.size
          list.reject! { |s| s["name"] == name }
          save_schedules(list)
          list.size < before_count
        end
      end

      # Update an existing schedule entry (cron and/or enabled).
      # Returns false if the schedule does not exist.
      def update_schedule(name, cron: nil, enabled: nil)
        @schedule_mutex.synchronize do
          list = load_schedules
          entry = list.find { |s| s["name"] == name }
          return false unless entry
          reset = cron || (enabled == true && entry["enabled"] == false)
          entry["cron"] = cron unless cron.nil?
          entry["enabled"] = enabled unless enabled.nil?
          if reset
            due = cron_next_run(entry["cron"])
            raise ArgumentError, "Invalid or impossible cron schedule" unless due
            entry["next_run_at"] = due.utc.iso8601
          end
          save_schedules(list)
          true
        end
      end

      # ── Composite cron-task helpers ──────────────────────────────────────────

      # Create a task file and its schedule in one step.
      def create_cron_task(name:, content:, cron:, enabled: true, target: nil)
        @schedule_mutex.synchronize do
          existing = load_schedules.find { |plan| plan["name"] == name }
          if existing && (target || existing["target"])
            raise ArgumentError, "Plan already exists; update it with PATCH or choose another name"
          end
          raise ArgumentError, "Invalid or impossible cron schedule" unless cron_next_run(cron)
          write_task(name, content)
          add_schedule(name: name, task: name, cron: cron, enabled: enabled, target: target)
        end
      end

      # Update a cron-task: optionally update content and/or schedule fields.
      def update_cron_task(name, content: nil, cron: nil, enabled: nil)
        raise "Cron task not found: #{name}" unless list_tasks.include?(name)

        @schedule_mutex.synchronize do
          update_schedule(name, cron: cron, enabled: enabled) if cron || !enabled.nil?
          write_task(name, content) unless content.nil?
        end
      end

      # Delete a cron-task: remove both the task file and its schedule.
      def delete_cron_task(name)
        @schedule_mutex.synchronize do
          removed_schedule = remove_schedule(name)
          removed_task = delete_task(name)
          removed_schedule || removed_task
        end
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
            "target" => schedule["target"],
            "next_run" => schedule["enabled"] == false ? nil : (schedule["next_run_at"] || (cron && cron_next_run(cron)))
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

      # Persist the next occurrence. On resume, collapse missed occurrences to
      # the latest one; a rejected dispatch retains its deadline for retry.
      private def tick(now)
        maybe_run_backup(now)
        @schedule_mutex.synchronize do
          list = load_schedules
          list.each do |schedule|
            next if schedule["enabled"] == false
            begin
              unless schedule["next_run_at"]
                # Legacy plans have no cursor: begin with this minute, not an
                # invented backlog from before the plan existed.
                schedule["id"] ||= SecureRandom.hex(12)
                from = Time.at(now.to_i / 60 * 60 - 1)
                schedule["next_run_at"] = cron_next_run(schedule["cron"], from: from)&.utc&.iso8601
                save_schedules(list)
              end
              next unless schedule["next_run_at"] && Time.iso8601(schedule["next_run_at"]) <= now
              due = cron_occurrence(schedule["cron"], from: now, direction: -1)
              next unless due && due >= Time.iso8601(schedule["next_run_at"])
              accepted = if schedule["target"]
                           @scheduled_dispatcher&.call(schedule, read_task(schedule["task"]), due)
                         else
                           fire_task(schedule)
                         end
              next unless accepted
              schedule["next_run_at"] = cron_next_run(schedule["cron"], from: now)&.utc&.iso8601
              save_schedules(list)
            rescue => e
              Clacky::Logger.error("scheduler_tick_error", schedule: schedule["name"], error: e)
            end
          end
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
        dispatched = @task_runner.call(session_id, agent) do
          track_run(task_name, session_id, trigger: :schedule) { agent.run(prompt) }
        end

        Clacky::Logger.info("scheduler_task_dispatched", task: task_name, session: session_id)
        dispatched
      rescue => e
        Clacky::Logger.error("scheduler_fire_error", task: schedule["task"], error: e)
        nil
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

      # Search calendar days in server-local time, retaining DOM AND DOW semantics.
      private def cron_next_run(expr, from: Time.now)
        cron_occurrence(expr, from: from, direction: 1)
      end

      private def cron_occurrence(expr, from:, direction:)
        fields = expr.to_s.strip.split(/\s+/)
        return nil unless fields.size == 5
        sets = fields.zip([[0, 59], [0, 23], [1, 31], [1, 12], [0, 6]]).map do |field, bounds|
          cron_field_values(field, *bounds)
        end
        return nil if sets.any? { |set| set.nil? || set.empty? }
        minutes, hours, doms, months, dows = sets
        local = from.getlocal
        date = Date.new(local.year, local.month, local.day)
        (0..2922).each do |offset|
          day = date + offset * direction
          next unless months.include?(day.month) && doms.include?(day.day) && dows.include?(day.wday)
          candidates = hours.flat_map do |hour|
            minutes.map do |minute|
              Time.local(day.year, day.month, day.day, hour, minute)
            end
          end
          valid = candidates.select { |time| direction == 1 ? time > from : time <= from }
          result = direction == 1 ? valid.min : valid.max
          return result if result
        end
        nil
      end

      # Concrete values a single cron field can take, mirroring the semantics of
      # #cron_part_matches?. Returns nil when the field is unparseable.
      private def cron_field_values(field, min, max)
        return nil unless field.to_s.match?(/\A(?:\*|\d+(?:-\d+)?)(?:\/\d+)?(?:,(?:\*|\d+(?:-\d+)?)(?:\/\d+)?)*\z/)
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
          return nil if lo.nil? || hi.nil? || hi < lo || lo < min || hi > max

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
        tmp = "#{SCHEDULES_FILE}.#{SecureRandom.hex(6)}.tmp"
        begin
          File.open(tmp, "w", 0o600) do |file|
            file.write(YAML.dump(list))
            file.flush
            file.fsync
          end
          File.rename(tmp, SCHEDULES_FILE)
        ensure
          FileUtils.rm_f(tmp)
        end
      end
    end
  end
end
