require "spec_helper"

RSpec.describe Clacky::Fanout do
  describe "#run" do
    it "returns an empty array for no jobs" do
      expect(described_class.new.run([])).to eq([])
    end

    it "aligns results to input order regardless of completion order" do
      jobs = [
        -> { sleep 0.15
 :slow },
        -> { :fast },
        -> { sleep 0.05
 :medium }
      ]

      results = described_class.new(max_concurrency: 3).run(jobs)

      expect(results.map(&:value)).to eq(%i[slow fast medium])
      expect(results.map(&:index)).to eq([0, 1, 2])
      expect(results).to all(be_ok)
    end

    it "runs jobs concurrently up to the limit" do
      peak = 0
      lock = Mutex.new
      active = 0

      jobs = Array.new(4) do
        lambda do
          lock.synchronize do
            active += 1
            peak = [peak, active].max
          end
          sleep 0.05
          lock.synchronize { active -= 1 }
          :done
        end
      end

      described_class.new(max_concurrency: 2).run(jobs)

      expect(peak).to eq(2)
    end

    it "never exceeds the pool size even with many jobs" do
      peak = 0
      active = 0
      lock = Mutex.new

      jobs = Array.new(20) do
        lambda do
          lock.synchronize do
            active += 1
            peak = [peak, active].max
          end
          sleep 0.01
          lock.synchronize { active -= 1 }
        end
      end

      described_class.new(max_concurrency: 3).run(jobs)

      expect(peak).to be <= 3
    end

    it "isolates a raising job without affecting its siblings" do
      jobs = [
        -> { :ok_before },
        -> { raise ArgumentError, "boom" },
        -> { :ok_after }
      ]

      results = described_class.new(max_concurrency: 3).run(jobs)

      expect(results[0].value).to eq(:ok_before)
      expect(results[2].value).to eq(:ok_after)
      expect(results[1]).not_to be_ok
      expect(results[1].error).to be_a(ArgumentError)
      expect(results[1].error.message).to eq("boom")
      expect(results[1].value).to be_nil
    end

    it "records a timeout result for jobs that outlive the budget" do
      jobs = [
        -> { :quick },
        -> { sleep 5
 :never }
      ]

      results = described_class.new(max_concurrency: 2, timeout: 0.2).run(jobs)

      expect(results[0].value).to eq(:quick)
      expect(results[1]).not_to be_ok
      expect(results[1].error).to be_a(Clacky::FanoutTimeoutError)
    end

    it "does not wait for the full duration of a timed-out batch" do
      jobs = [-> { sleep 5 }]

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.new(timeout: 0.2).run(jobs)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2
    end

    it "measures each job's duration" do
      results = described_class.new.run([-> { sleep 0.05 }])

      expect(results[0].duration).to be >= 0.04
    end

    it "rejects a non-positive concurrency limit" do
      expect { described_class.new(max_concurrency: 0) }.to raise_error(ArgumentError)
    end

    it "runs every job exactly once" do
      counter = Mutex.new
      calls = []
      jobs = Array.new(10) { |i| -> { counter.synchronize { calls << i } } }

      described_class.new(max_concurrency: 4).run(jobs)

      expect(calls.sort).to eq((0..9).to_a)
    end

    it "forwards an interrupt on the caller thread to running workers" do
      unwound = Queue.new
      started = Queue.new
      jobs = Array.new(2) do
        lambda do
          started << :go
          begin
            sleep 5
          rescue Clacky::AgentInterrupted
            unwound << :ensure
            raise
          end
        end
      end

      raised = nil
      caller_thread = Thread.new do
        described_class.new(max_concurrency: 2).run(jobs)
      rescue Clacky::AgentInterrupted => e
        raised = e
      end

      2.times { started.pop } # both workers are inside their sleep
      caller_thread.raise(Clacky::AgentInterrupted, "stop")
      caller_thread.join(3)

      expect(caller_thread.alive?).to be(false)
      # The interrupt propagates out of #run so the caller can unwind too.
      expect(raised).to be_a(Clacky::AgentInterrupted)
      # Each worker unwound through its own rescue rather than being abandoned.
      expect([unwound.pop, unwound.pop]).to eq(%i[ensure ensure])
    end

    it "invokes on_cancel before unwinding when interrupted" do
      cancelled = Queue.new
      started = Queue.new
      jobs = [-> { started << :go; sleep 5 }]

      caller_thread = Thread.new do
        described_class.new.run(jobs, on_cancel: -> { cancelled << :flag })
      rescue Clacky::AgentInterrupted
        nil
      end

      started.pop
      caller_thread.raise(Clacky::AgentInterrupted, "stop")
      caller_thread.join(3)

      expect(cancelled.pop).to eq(:flag)
    end
  end
end
