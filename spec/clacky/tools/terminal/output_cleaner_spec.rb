# frozen_string_literal: true

# Unit tests for OutputCleaner — the PTY output normalizer.
#
# These specs focus on backspace-erase semantics and the performance
# regression guard for the single-pass scan that replaced the O(n^2)
# `while + gsub` loop. The cases here mirror the comment block in
# output_cleaner.rb.
RSpec.describe Clacky::Tools::Terminal::OutputCleaner do
  BS = "\x08".freeze
  let(:mod) { described_class }

  # Simulate raw PTY bytes arriving as ASCII-8BIT; clean() runs them
  # through pty_to_utf8 which restores valid UTF-8. `+` thaws the
  # string because this file uses frozen_string_literal.
  def raw(str)
    (+str).force_encoding("BINARY")
  end

  describe ".clean backspace-erase semantics" do
    it "returns empty for nil/empty input" do
      expect(mod.clean(nil)).to eq("")
      expect(mod.clean("")).to eq("")
    end

    it "leaves plain text without backspaces unchanged" do
      expect(mod.clean(raw("hello world"))).to eq("hello world")
    end

    it "erases a single preceding char for one backspace" do
      expect(mod.clean(raw("abcd#{BS}"))).to eq("abc")
    end

    it "erases multiple preceding chars for multiple backspaces" do
      expect(mod.clean(raw("abcde#{BS * 3}"))).to eq("ab")
    end

    it "erases down to empty when backspaces exhaust the buffer" do
      expect(mod.clean(raw("ab#{BS * 2}"))).to eq("")
    end

    it "preserves leading backspaces that have nothing to pair with" do
      # The regex [^\x08]\x08 requires a non-BS char before the BS, so
      # leading/isolated backspaces are never erased by either impl.
      expect(mod.clean(raw("#{BS}#{BS}hi"))).to eq("#{BS}#{BS}hi")
    end

    it "stops erasing once the buffer is empty, keeping the extra BS" do
      # "x" is erased by the first BS; the buffer is now empty, so the
      # second BS has nothing to pair with and is kept. Then "y" appends.
      expect(mod.clean(raw("x#{BS}#{BS}y"))).to eq("#{BS}y")
    end

    it "handles interleaved type-and-correct patterns" do
      expect(mod.clean(raw("worQ#{BS}d"))).to eq("word")
    end

    it "erases a multibyte UTF-8 char as a whole char" do
      expect(mod.clean(raw("你好#{BS}"))).to eq("你")
    end

    it "is unaffected by interspersed carriage returns" do
      expect(mod.clean(raw("foo\rbar#{BS}"))).to eq("ba")
    end
  end

  describe ".clean performance (regression guard)" do
    # A long run of chars followed by a long run of backspaces (e.g. a
    # readline rubout of a long line) previously triggered O(n^2)
    # behaviour. With the single-pass scan it completes in milliseconds.
    # The threshold is deliberately generous to avoid flakiness on slow
    # CI runners, but an O(n^2) regression would blow past it by orders
    # of magnitude (~5s at n=20000).
    it "handles a large char+backspace run in linear time" do
      n = 20_000
      input = raw(("x" * n) + (BS * n))

      expect(mod.clean(input)).to eq("")

      # Process.clock_gettime is in core (no gem) on Ruby >= 2.1, so
      # this avoids relying on `benchmark`, which left the default gems
      # set in Ruby 4.0.
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      mod.clean(input)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      expect(elapsed).to be < 2.0
    end
  end
end
