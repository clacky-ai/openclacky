# frozen_string_literal: true

module Clacky
  # Runs a batch of blocking jobs on a bounded thread pool and collects their
  # results in the order the jobs were given, regardless of completion order.
  #
  # Built for subagent fan-out: each job blocks inside Agent#run, so the pool is
  # sized for concurrency rather than CPU count. A job that raises is captured
  # as a failed slot instead of tearing down its siblings.
  class Fanout
    Result = Struct.new(:index, :value, :error, :duration, keyword_init: true) do
      def ok?
        error.nil?
      end
    end

    DEFAULT_MAX_CONCURRENCY = 4

    # @param max_concurrency [Integer] jobs allowed to run at once
    # @param timeout [Numeric, nil] wall-clock budget for the whole batch
    def initialize(max_concurrency: DEFAULT_MAX_CONCURRENCY, timeout: nil)
      raise ArgumentError, "max_concurrency must be positive" unless max_concurrency.to_i.positive?

      @max_concurrency = max_concurrency.to_i
      @timeout = timeout
    end

    # @param jobs [Array<#call>] each job is invoked with no arguments
    # @return [Array<Result>] one entry per job, aligned to the input order
    def run(jobs)
      return [] if jobs.empty?

      pending = build_queue(jobs)
      results = Array.new(jobs.size)
      deadline = @timeout && (monotonic_now + @timeout)

      workers = Array.new([@max_concurrency, jobs.size].min) do
        Thread.new { drain(pending, results, deadline) }
      end
      join_all(workers, deadline)

      fill_unfinished(results)
    end

    private def build_queue(jobs)
      queue = Queue.new
      jobs.each_with_index { |job, index| queue << [index, job] }
      queue
    end

    private def drain(pending, results, deadline)
      # pop(true) raises ThreadError when the queue is drained, which is the
      # only exit condition — workers outlive individual jobs.
      loop do
        index, job = pending.pop(true)
        break if deadline && monotonic_now >= deadline

        results[index] = invoke(index, job)
      end
    rescue ThreadError
      nil
    end

    private def invoke(index, job)
      started = monotonic_now
      value = job.call
      Result.new(index: index, value: value, error: nil, duration: monotonic_now - started)
    rescue StandardError, ScriptError => e
      Result.new(index: index, value: nil, error: e, duration: monotonic_now - started)
    end

    private def join_all(workers, deadline)
      workers.each do |worker|
        if deadline
          remaining = deadline - monotonic_now
          worker.join(remaining.positive? ? remaining : 0) or worker.kill
        else
          worker.join
        end
      end
    end

    private def fill_unfinished(results)
      results.each_with_index do |result, index|
        next if result

        results[index] = Result.new(
          index: index,
          value: nil,
          error: FanoutTimeoutError.new("fan-out job #{index} did not finish within #{@timeout}s"),
          duration: @timeout
        )
      end
    end

    private def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
