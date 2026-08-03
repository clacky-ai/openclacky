# frozen_string_literal: true

# Regression tests for the "duplicate system prompt after compression" bug.
#
# Bug report:
#   After uploading an image, the system prompt appeared N times in session.json.
#   Each compression round re-inserted the system message because
#   get_recent_messages_with_tool_pairs did NOT exclude it, so `recent_messages`
#   contained the system msg AND rebuild_with_compression prepended another one.
#   The ever-growing system prompts caused token counts to stay above
#   COMPRESSION_THRESHOLD, triggering an infinite compression loop.

RSpec.describe "Compression system-prompt duplication bug" do
  # ── helpers ──────────────────────────────────────────────────────────────────

  # Build a minimal agent-like object that mixes in the helper module
  def build_agent(messages:, previous_total_tokens: 0)
    klass = Class.new do
      include Clacky::Agent::MessageCompressorHelper

      attr_accessor :history, :compression_level, :compressed_summaries,
                    :previous_total_tokens, :session_id, :created_at

      def initialize(messages, prev_tokens)
        @history               = Clacky::MessageHistory.new(messages)
        @compression_level     = 0
        @compressed_summaries  = []
        @previous_total_tokens = prev_tokens
        @session_id            = nil   # disable chunk saving
        @created_at            = nil
        # MessageCompressorHelper accesses @config directly as an ivar
        config_klass = Struct.new(:enable_compression, :enable_idle_compression)
        @config      = config_klass.new(true, true)
        # compress_messages_if_needed calls @message_compressor.build_compression_message
        @message_compressor = Clacky::MessageCompressor.new(nil)
      end

      def config; @config; end
      def ui;     nil;          end

      # Expose private helper for white-box testing
      public :get_recent_messages_with_tool_pairs
    end

    klass.new(messages, previous_total_tokens)
  end

  # Minimal system message (simulates the real thing — large but represented small here)
  let(:system_msg) { { role: "system", content: "You are a helpful assistant. " * 50 } }

  # A session_context injection (system_injected user message)
  let(:session_ctx) do
    { role: "user", content: "[Session context: Today is 2026-03-27]",
      system_injected: true, session_context: true, session_date: "2026-03-27" }
  end

  # Simulates the image upload user message (base64 would be huge; we fake content)
  let(:image_msg) do
    { role: "user",
      content: [
        { type: "text", text: "Please analyze this image." },
        { type: "image_url", image_url: { url: "data:image/png;base64,#{"A" * 500}" } }
      ] }
  end

  let(:assistant_reply) do
    { role: "assistant", content: "I can see the image. It shows..." }
  end

  # ── Bug 1: get_recent_messages_with_tool_pairs must never return system msg ──

  describe "get_recent_messages_with_tool_pairs" do
    it "does NOT include the system message in recent messages" do
      messages = [system_msg, session_ctx, image_msg, assistant_reply]
      agent    = build_agent(messages: messages)

      # Request enough recent messages to potentially reach the system msg
      recent = agent.get_recent_messages_with_tool_pairs(messages, 10)

      system_in_recent = recent.any? { |m| m[:role] == "system" }
      expect(system_in_recent).to be(false),
        "system message must not appear in recent_messages — it would be duplicated by rebuild_with_compression"
    end

    it "still returns non-system messages correctly" do
      messages = [system_msg, session_ctx, image_msg, assistant_reply]
      agent    = build_agent(messages: messages)

      recent = agent.get_recent_messages_with_tool_pairs(messages, 10)

      expect(recent.map { |m| m[:role] }).to include("user", "assistant")
    end
  end

  # ── Bug 2: rebuild_with_compression must produce exactly one system message ──

  describe Clacky::MessageCompressor do
    let(:compressor) { described_class.new(nil) }

    it "produces exactly one system message in the rebuilt history" do
      original_messages = [system_msg, session_ctx, image_msg, assistant_reply]
      # Simulate the bug: recent_messages accidentally contains the system msg
      recent_with_system = [system_msg, image_msg, assistant_reply]

      result = compressor.rebuild_with_compression(
        "<summary>User uploaded image and asked for analysis.</summary>",
        original_messages: original_messages,
        recent_messages: recent_with_system,
        chunk_path: nil
      )

      system_count = result.count { |m| m[:role] == "system" }
      expect(system_count).to eq(1),
        "expected exactly 1 system message after rebuild, got #{system_count}"
    end

    it "places the single system message at position 0" do
      original_messages = [system_msg, image_msg, assistant_reply]
      recent_messages   = [image_msg, assistant_reply]

      result = compressor.rebuild_with_compression(
        "<summary>Image analysis session.</summary>",
        original_messages: original_messages,
        recent_messages: recent_messages,
        chunk_path: nil
      )

      expect(result.first[:role]).to eq("system")
    end
  end

  # ── Bug 3: end-to-end — after compression token count must drop below threshold ──

  describe "compress_messages_if_needed after compression" do
    it "does not re-trigger compression immediately after a successful compression" do
      # Build a history that is just above the idle threshold but below normal threshold
      # so we can use force: true to simulate the scenario
      messages = [system_msg]
      # Add enough messages to cross MAX_RECENT_MESSAGES + 1
      25.times do |i|
        messages << { role: "user",    content: "Question #{i}" }
        messages << { role: "assistant", content: "Answer #{i}" }
      end

      # Simulate tokens slightly above IDLE_COMPRESSION_THRESHOLD
      prev_tokens = Clacky::Agent::MessageCompressorHelper::IDLE_COMPRESSION_THRESHOLD + 1_000

      agent = build_agent(messages: messages, previous_total_tokens: prev_tokens)

      # First call should return a compression context
      context = agent.compress_messages_if_needed(force: true)
      expect(context).not_to be_nil, "expected compression to be triggered"

      # Simulate what handle_compression_response does:
      #   1. replace history with small rebuilt version
      #   2. reset @previous_total_tokens to estimated new size
      small_messages = [system_msg, { role: "user", content: "<summary>All previous work summarised.</summary>", compressed_summary: true, system_injected: true }]
      agent.history.replace_all(small_messages)
      agent.previous_total_tokens = agent.history.estimate_tokens  # THE FIX

      # Reset compression_level as it would be after one successful compression
      # (compress_messages_if_needed already incremented it once — leave it as-is)

      # Second call: compression must NOT re-trigger
      context2 = agent.compress_messages_if_needed(force: true)
      expect(context2).to be_nil,
        "@previous_total_tokens must be reset after compression so the next call does not loop"
    end
  end
end
