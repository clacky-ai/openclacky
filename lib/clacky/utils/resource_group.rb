# frozen_string_literal: true

require "securerandom"

module Clacky
  module Utils
    # Optional Linux cgroup v2 placement. The host owns the aggregate limits;
    # each child group attributes OOM kills to its terminal/MCP process tree.
    class ResourceGroup
      MEMORY_ERROR = "Task memory limit reached: a process was killed by the resource limit. " \
                     "Reduce the workload or run it in smaller batches before retrying."
      attr_reader :path

      def self.validate!(root)
        raise ArgumentError, "Task cgroup must be an absolute path" unless root.start_with?("/")
        controllers = File.read(File.join(root, "cgroup.subtree_control")).split
        unless %w[memory cpu].all? { |name| controllers.include?(name) }
          raise ArgumentError, "Task cgroup must delegate memory and cpu controllers"
        end
      end

      def self.create(kind)
        root = ENV["CLACKY_TASK_CGROUP"].to_s
        return nil if root.empty?

        validate!(root)
        path = File.join(root, "clacky-#{kind}-#{Process.pid}-#{SecureRandom.hex(6)}")
        Dir.mkdir(path)
        new(path)
      end

      def initialize(path)
        @path = path
        @oom_kills = oom_kills
      end

      def wrap(argv)
        # Join before exec, not by moving the PID after spawn: that would let
        # early descendants escape. argv stays separate from shell source.
        ["/bin/sh", "-c", 'echo $$ > "$1/cgroup.procs" || exit 125; shift; exec "$@"',
         "clacky-resource-group", path, *argv]
      end

      def consume_oom_error
        count = oom_kills
        changed = count > @oom_kills
        @oom_kills = count
        changed ? MEMORY_ERROR : nil
      end

      def cleanup
        Dir.rmdir(path)
      rescue Errno::EBUSY, Errno::ENOTEMPTY, Errno::ENOENT
        # Intentionally backgrounded descendants remain within the shared cap.
        nil
      end

      private def oom_kills
        File.foreach(File.join(path, "memory.events.local")) do |line|
          name, value = line.split
          return Integer(value) if name == "oom_kill"
        end
        raise "Missing oom_kill counter in #{path}"
      end
    end
  end
end
