# frozen_string_literal: true

require "json"

module Clacky
  # Reassembles a Bedrock Converse event stream into the same hash shape that
  # MessageFormat::Bedrock.parse_response expects from a non-streaming response,
  # while invoking on_chunk(input_tokens:, output_tokens:) as usage information
  # accumulates.
  #
  # Bedrock event-stream events handled (passed through as raw event JSON):
  #
  #   messageStart      → { role: "assistant" }
  #   contentBlockStart → { start: {toolUse: {toolUseId, name}} | {}, contentBlockIndex: N }
  #   contentBlockDelta → { delta: {text: "..."} | {toolUse: {input: "..."}}, contentBlockIndex: N }
  #   contentBlockStop  → { contentBlockIndex: N }
  #   messageStop       → { stopReason: "end_turn" | "tool_use" | "max_tokens" | ... }
  #   metadata          → { usage: {inputTokens, outputTokens, cacheReadInputTokens, cacheWriteInputTokens}, metrics: {...} }
  #
  # Tool-use input is streamed as a sequence of partial JSON strings; we
  # concatenate and let the response parser leave it as a string for downstream
  # tool dispatch (which calls JSON.parse with a {} fallback).
  class BedrockStreamAggregator
    def initialize(on_chunk: nil, checkpoint: nil)
      @on_chunk = on_chunk
      @checkpoint = checkpoint
      @role = "assistant"
      @blocks = {}
      @stop_reason = nil
      @usage = {}
      @last_input_tokens = 0
      @last_output_tokens = 0
      @parse_failures = 0
      @frames_seen = 0
      @bytes_seen = 0
    end

    attr_reader :parse_failures, :frames_seen, :bytes_seen

    def handle(event, data_str)
      @bytes_seen += data_str.to_s.bytesize
      @frames_seen += 1
      data = parse_or_nil(data_str)
      return unless data

      case event
      when "messageStart"
        @role = data["role"] || @role
      when "contentBlockStart"
        idx = data["contentBlockIndex"] || @blocks.size
        start = data["start"] || {}
        if (tu = start["toolUse"])
          @blocks[idx] = { kind: :tool_use, id: tu["toolUseId"], name: tu["name"], input_str: +"" }
        else
          @blocks[idx] = { kind: :text, text: +"" }
        end
      when "contentBlockDelta"
        idx = data["contentBlockIndex"] || 0
        delta = data["delta"] || {}
        block = (@blocks[idx] ||= { kind: :text, text: +"" })
        if delta["text"]
          block[:kind] ||= :text
          block[:text] ||= +""
          block[:text] << delta["text"]
        elsif (tu = delta["toolUse"])
          block[:kind] = :tool_use
          block[:input_str] ||= +""
          block[:input_str] << tu["input"].to_s
          block[:id]   ||= tu["toolUseId"]
          block[:name] ||= tu["name"]
        elsif (rc = delta["reasoningContent"])
          block[:kind] = :reasoning
          block[:reasoning] ||= +""
          block[:reasoning] << rc["text"].to_s
        end
        emit_estimate_progress
        @checkpoint&.update(to_checkpoint_snapshot)
      when "contentBlockStop"
        # Nothing to assemble: blocks are kept as-is until messageStop.
      when "messageStop"
        @stop_reason = data["stopReason"] || @stop_reason
      when "metadata"
        if (u = data["usage"])
          @usage.merge!(u)
          emit_usage_progress(u)
        end
      end
    end

    # Render the canonical non-streaming Bedrock response hash so the existing
    # MessageFormat::Bedrock.parse_response can consume it unchanged.
    def to_h
      content_blocks = @blocks.keys.sort.map do |idx|
        b = @blocks[idx]
        case b[:kind]
        when :tool_use
          input_value = b[:input_str].to_s.empty? ? {} : (JSON.parse(b[:input_str]) rescue b[:input_str])
          { "toolUse" => { "toolUseId" => b[:id], "name" => b[:name], "input" => input_value } }
        else
          { "text" => b[:text].to_s }
        end
      end

      {
        "output"     => { "message" => { "role" => @role, "content" => content_blocks } },
        "stopReason" => @stop_reason,
        "usage"      => @usage
      }
    end

    # Extract a provider-agnostic snapshot for StreamCheckpoint.
    def to_checkpoint_snapshot
      text_parts, reasoning_parts, tool_calls = [], [], []
      @blocks.keys.sort.each do |idx|
        b = @blocks[idx]
        case b[:kind]
        when :tool_use
          tool_calls << { id: b[:id], name: b[:name], arguments: b[:input_str].to_s }
        when :reasoning
          reasoning_parts << b[:reasoning].to_s
        else
          text_parts << b[:text].to_s
        end
      end
      snap = { role: "assistant", content: text_parts.join, incomplete: true, provider: "bedrock" }
      snap[:reasoning_content] = reasoning_parts.join unless reasoning_parts.empty?
      snap[:tool_calls] = tool_calls unless tool_calls.empty?
      snap
    end

    private def parse_or_nil(s)
      JSON.parse(s)
    rescue JSON::ParserError => e
      @parse_failures += 1
      if @parse_failures == 1
        Clacky::Logger.warn("stream.parse_failure",
          provider: "bedrock",
          error: "#{e.class}: #{e.message}",
          frame_head: s.to_s[0, 200],
          frame_bytes: s.to_s.bytesize
        )
      end
      nil
    end

    private def emit_usage_progress(u)
      return unless @on_chunk
      input  = u["inputTokens"].to_i + u["cacheReadInputTokens"].to_i
      output = u["outputTokens"].to_i
      return if input == @last_input_tokens && output == @last_output_tokens
      @last_input_tokens = input
      @last_output_tokens = output
      @on_chunk.call(input_tokens: input, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[BedrockStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end

    private def emit_estimate_progress
      return unless @on_chunk
      output = approximate_output_tokens
      return if output == @last_output_tokens
      @last_output_tokens = output
      @on_chunk.call(input_tokens: @last_input_tokens, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[BedrockStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end

    private def approximate_output_tokens
      total_chars = @blocks.values.sum do |b|
        b[:text].to_s.bytesize + b[:input_str].to_s.bytesize + b[:reasoning].to_s.bytesize
      end
      (total_chars / 4.0).ceil
    end
  end
end
