# frozen_string_literal: true

require "json"

module Clacky
  # Reassembles an Anthropic Messages SSE stream (event: message_start /
  # content_block_start / content_block_delta / content_block_stop /
  # message_delta / message_stop / ping) into the same hash shape that
  # MessageFormat::Anthropic.parse_response expects from a non-streaming
  # response, while invoking on_chunk(input_tokens:, output_tokens:) as
  # usage accumulates.
  #
  # Wire reference: https://docs.anthropic.com/en/api/messages-streaming
  class AnthropicStreamAggregator
    def initialize(on_chunk: nil)
      @on_chunk = on_chunk
      @blocks = {}
      @stop_reason = nil
      @usage = {}
      @last_input_tokens = 0
      @last_output_tokens = 0
    end

    def handle(event, data_str)
      data = parse_or_nil(data_str)
      return unless data

      case event
      when "message_start"
        msg = data["message"] || {}
        if (u = msg["usage"])
          @usage.merge!(u)
          emit_usage_progress
        end
      when "content_block_start"
        idx = data["index"] || @blocks.size
        cb = data["content_block"] || {}
        case cb["type"]
        when "tool_use"
          @blocks[idx] = { kind: :tool_use, id: cb["id"], name: cb["name"], input_str: +"" }
        else
          @blocks[idx] = { kind: :text, text: +"" }
        end
      when "content_block_delta"
        idx = data["index"] || 0
        delta = data["delta"] || {}
        block = (@blocks[idx] ||= { kind: :text, text: +"" })
        case delta["type"]
        when "text_delta"
          block[:kind] ||= :text
          block[:text] ||= +""
          block[:text] << delta["text"].to_s
        when "input_json_delta"
          block[:kind] = :tool_use
          block[:input_str] ||= +""
          block[:input_str] << delta["partial_json"].to_s
        when "thinking_delta"
          block[:kind] = :thinking
          block[:thinking] ||= +""
          block[:thinking] << delta["thinking"].to_s
        end
        emit_estimate_progress
      when "content_block_stop"
        # Nothing to do: blocks are finalised in to_h.
      when "message_delta"
        if (d = data["delta"])
          @stop_reason = d["stop_reason"] if d["stop_reason"]
        end
        if (u = data["usage"])
          @usage.merge!(u)
          emit_usage_progress
        end
      when "message_stop", "ping", "error"
        # no-op
      end
    end

    # Canonical non-streaming Anthropic response shape consumed by
    # MessageFormat::Anthropic.parse_response.
    def to_h
      content_blocks = @blocks.keys.sort.map do |idx|
        b = @blocks[idx]
        case b[:kind]
        when :tool_use
          input_value =
            if b[:input_str].to_s.empty?
              {}
            else
              JSON.parse(b[:input_str]) rescue b[:input_str]
            end
          { "type" => "tool_use", "id" => b[:id], "name" => b[:name], "input" => input_value }
        else
          { "type" => "text", "text" => b[:text].to_s }
        end
      end

      { "content" => content_blocks, "stop_reason" => @stop_reason, "usage" => @usage }
    end

    private def parse_or_nil(s)
      JSON.parse(s)
    rescue JSON::ParserError
      nil
    end

    private def emit_usage_progress
      return unless @on_chunk
      input  = @usage["input_tokens"].to_i + @usage["cache_read_input_tokens"].to_i
      output = @usage["output_tokens"].to_i
      return if input == @last_input_tokens && output == @last_output_tokens
      @last_input_tokens = input
      @last_output_tokens = output
      @on_chunk.call(input_tokens: input, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[AnthropicStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end

    private def emit_estimate_progress
      return unless @on_chunk
      output = approximate_output_tokens
      return if output == @last_output_tokens
      @last_output_tokens = output
      @on_chunk.call(input_tokens: @last_input_tokens, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[AnthropicStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end

    private def approximate_output_tokens
      total_chars = @blocks.values.sum do |b|
        b[:text].to_s.bytesize + b[:input_str].to_s.bytesize + b[:thinking].to_s.bytesize
      end
      (total_chars / 4.0).ceil
    end
  end
end
