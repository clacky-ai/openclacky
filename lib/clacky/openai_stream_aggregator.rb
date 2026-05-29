# frozen_string_literal: true

require "json"

module Clacky
  # Reassembles an OpenAI-compatible chat-completion event stream into the
  # non-streaming response shape that MessageFormat::OpenAI.parse_response
  # consumes, while invoking on_chunk(input_tokens:, output_tokens:) every
  # time the upstream emits a new usage frame.
  #
  # Streaming frames look like:
  #
  #   {"id":"...","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}
  #   {"id":"...","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}
  #   {"id":"...","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"shell","arguments":"{\"cmd"}}]}}]}
  #   {"id":"...","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":\"ls\"}"}}]}}]}
  #   {"id":"...","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
  #   {"id":"...","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":2}}}
  #   data: [DONE]
  class OpenAIStreamAggregator
    def initialize(on_chunk: nil)
      @on_chunk = on_chunk
      @content = +""
      @reasoning_content = +""
      @role = "assistant"
      @finish_reason = nil
      @tool_calls = {}
      @usage = nil
      @last_input_tokens = 0
      @last_output_tokens = 0
    end

    def handle(data_str)
      return if data_str == "[DONE]"
      data = parse_or_nil(data_str)
      return unless data

      if (choice = (data["choices"] || []).first)
        delta = choice["delta"] || {}
        @role = delta["role"] if delta["role"]
        @content << delta["content"] if delta["content"].is_a?(String)
        @reasoning_content << delta["reasoning_content"] if delta["reasoning_content"].is_a?(String)
        if (tcs = delta["tool_calls"])
          tcs.each { |tc| merge_tool_call(tc) }
        end
        @finish_reason = choice["finish_reason"] if choice["finish_reason"]
        emit_estimate_progress
      end

      if (u = data["usage"])
        @usage = u
        emit_usage_progress(u)
      end
    end

    # Render the canonical non-streaming response shape.
    def to_h
      tool_calls = @tool_calls.keys.sort.map do |idx|
        tc = @tool_calls[idx]
        {
          "id"       => tc[:id],
          "type"     => tc[:type] || "function",
          "function" => {
            "name"      => tc[:name],
            "arguments" => tc[:arguments].to_s
          }
        }
      end

      message = {
        "role"    => @role,
        "content" => @content.empty? ? nil : @content
      }
      message["tool_calls"] = tool_calls unless tool_calls.empty?
      message["reasoning_content"] = @reasoning_content unless @reasoning_content.empty?

      {
        "choices" => [{ "index" => 0, "message" => message, "finish_reason" => @finish_reason }],
        "usage"   => @usage || {}
      }
    end

    private def merge_tool_call(tc)
      idx = tc["index"] || @tool_calls.size
      slot = (@tool_calls[idx] ||= { id: nil, type: nil, name: nil, arguments: +"" })
      slot[:id] ||= tc["id"] if tc["id"]
      slot[:type] ||= tc["type"] if tc["type"]
      if (fn = tc["function"])
        slot[:name] ||= fn["name"] if fn["name"]
        slot[:arguments] << fn["arguments"].to_s if fn["arguments"]
      end
    end

    private def parse_or_nil(s)
      JSON.parse(s)
    rescue JSON::ParserError
      nil
    end

    private def emit_estimate_progress
      return unless @on_chunk
      output = approximate_output_tokens
      return if output == @last_output_tokens
      @last_output_tokens = output
      @on_chunk.call(input_tokens: @last_input_tokens, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[OpenAIStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end

    # Rough char/4 estimate; replaced by the real count when the upstream
    # finally emits a usage frame (with stream_options.include_usage=true).
    private def approximate_output_tokens
      total_chars = @content.bytesize + @reasoning_content.bytesize +
        @tool_calls.values.sum { |tc| tc[:arguments].to_s.bytesize }
      (total_chars / 4.0).ceil
    end

    private def emit_usage_progress(u)
      return unless @on_chunk
      total_prompt = u["prompt_tokens"].to_i
      output       = u["completion_tokens"].to_i
      return if total_prompt == @last_input_tokens && output == @last_output_tokens
      @last_input_tokens = total_prompt
      @last_output_tokens = output
      @on_chunk.call(input_tokens: total_prompt, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[OpenAIStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end
  end
end
