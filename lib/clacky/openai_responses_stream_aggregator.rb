# frozen_string_literal: true

require "json"

module Clacky
  # Reassembles an OpenAI Responses API event stream into the non-streaming
  # response shape that MessageFormat::OpenAIResponses.parse_response consumes,
  # while invoking on_chunk(input_tokens:, output_tokens:) for progress updates.
  #
  # The Responses API uses typed SSE events rather than the Chat Completions
  # delta-based format. Key event types:
  #
  #   response.created                  -> response object created
  #   response.output_item.added        -> new output item (message or function_call)
  #   response.output_text.delta        -> text content delta
  #   response.output_text.done         -> text content complete
  #   response.reasoning_text.delta     -> reasoning content delta (OpenAI official / DeepSeek)
  #   response.function_call_arguments.delta -> tool call argument delta
  #   response.output_item.done         -> output item complete
  #   response.completed                -> final event with full response + usage
  #   response.done                     -> terminal event (OpenAI official API)
  #   response.incomplete               -> response ended prematurely
  #
  # Unlike Chat Completions, there is no "[DONE]" sentinel; the stream ends
  # with a "response.completed" / "response.done" (or "response.incomplete") event.
  class OpenAIResponsesStreamAggregator
    def initialize(on_chunk: nil)
      @on_chunk = on_chunk
      @text = +""
      @reasoning_text = +""
      @function_calls = {}   # call_id -> { name:, arguments: }
      @call_id_by_item_id = {} # item_id -> call_id (for delta routing)
      @usage = nil
      @status = nil
      @incomplete_details = nil
      @last_input_tokens = 0
      @last_output_tokens = 0
      @parse_failures = 0
      @frames_seen = 0
      @bytes_seen = 0
    end

    attr_reader :parse_failures, :frames_seen, :bytes_seen

    def saw_done?
      !@status.nil?
    end

    def handle(data_str)
      @bytes_seen += data_str.bytesize
      @frames_seen += 1
      data = parse_or_nil(data_str)
      return unless data

      event_type = data["type"]

      case event_type
      when "response.output_text.delta"
        @text << data["delta"].to_s
        emit_estimate_progress
      # OpenAI's official API emits response.reasoning_text.delta; keep
      # response.reasoning.delta as a tolerant alias for providers that
      # rename it.
      when "response.reasoning_text.delta", "response.reasoning.delta"
        @reasoning_text << data["delta"].to_s
      when "response.output_item.added"
        handle_item_added(data)
      when "response.function_call_arguments.delta"
        handle_function_call_delta(data)
      when "response.output_item.done"
        handle_item_done(data)
      when "response.completed", "response.done"
        # OpenAI's official API sends response.completed followed by
        # response.done as the terminal event; DeepSeek sends only
        # response.completed. Either one marks a successful end.
        @status = "completed"
        response = data["response"]
        @usage ||= response["usage"] if response && response["usage"]
        # Also sync output items from the final response if our incremental
        # tracking missed anything (e.g. provider sent complete items only).
        sync_from_final_output(response["output"]) if response && response["output"]
        emit_usage_progress(@usage) if @usage
      when "response.incomplete"
        @status = "incomplete"
        # Preserve incomplete_details (e.g. reason: "max_output_tokens" vs
        # "content_filter") so finish_reason mapping can distinguish a token
        # limit from a safety-filtered response.
        response = data["response"]
        @incomplete_details = response["incomplete_details"] if response.is_a?(Hash) && response["incomplete_details"]
      when "response.created", "response.in_progress"
        # Informational events, no action needed
      end
    end

    # Render into the non-streaming Responses API response shape
    # so MessageFormat::OpenAIResponses.parse_response works unchanged.
    def to_h
      output = []

      # Message item with text content
      unless @text.empty?
        output << {
          "type"    => "message",
          "role"    => "assistant",
          "content" => [{ "type" => "output_text", "text" => @text.to_s }]
        }
      end

      # Function call items
      @function_calls.each_value do |fc|
        output << {
          "type"      => "function_call",
          "call_id"   => fc[:call_id],
          "name"      => fc[:name],
          "arguments" => fc[:arguments].to_s
        }
      end

      result = {
        "output" => output,
        "status" => @status || "completed",
        "usage"  => @usage || {}
      }
      result["incomplete_details"] = @incomplete_details if @incomplete_details
      result
    end

    private def handle_item_added(data)
      item = data["item"]
      return unless item

      if item["type"] == "function_call"
        call_id = item["call_id"]
        item_id = item["id"]
        @call_id_by_item_id[item_id] = call_id if item_id
        @function_calls[call_id] = {
          call_id:    call_id,
          name:       item["name"],
          arguments:  +""
        }
      end
    end

    private def handle_function_call_delta(data)
      # The delta event carries item_id to identify which function call
      # the arguments belong to. Map it to the call_id we registered in
      # handle_item_added. Fall back to the most recent call if mapping fails.
      item_id = data["item_id"]
      call_id = @call_id_by_item_id[item_id] || @function_calls.keys.last

      return unless call_id && @function_calls[call_id]

      @function_calls[call_id][:arguments] << data["delta"].to_s
    end

    private def handle_item_done(data)
      item = data["item"]
      return unless item

      if item["type"] == "function_call"
        call_id = item["call_id"]
        fc = @function_calls[call_id]
        # Use the complete arguments from the done event if available -
        # more reliable than accumulated deltas.
        if fc && item["arguments"]
          fc[:arguments] = item["arguments"]
        end
      end
    end

    private def sync_from_final_output(output)
      return unless output.is_a?(Array)

      # Sync per-item: only backfill what incremental tracking missed.
      # A provider may send complete message items but only deltas for
      # function calls (or vice versa), so don't require both to be empty.
      output.each do |item|
        case item["type"]
        when "message"
          next unless @text.empty?
          content = item["content"]
          if content.is_a?(Array)
            content.each do |block|
              if block["type"] == "output_text"
                @text << block["text"].to_s
              end
            end
          end
        when "function_call"
          next if @function_calls.key?(item["call_id"])
          @function_calls[item["call_id"]] = {
            call_id:    item["call_id"],
            name:       item["name"],
            arguments:  item["arguments"].to_s
          }
        end
      end
    end

    private def parse_or_nil(s)
      # Some providers / proxies append a "[DONE]" sentinel (inherited from
      # Chat Completions SSE) even for the Responses API.  Silently ignore it
      # instead of logging a parse failure.
      return nil if s.to_s.strip == "[DONE]"

      JSON.parse(s)
    rescue JSON::ParserError => e
      @parse_failures += 1
      if @parse_failures == 1
        Clacky::Logger.warn("stream.parse_failure",
          provider: "openai-responses",
          error: "#{e.class}: #{e.message}",
          frame_head: s.to_s[0, 200],
          frame_bytes: s.to_s.bytesize
        )
      end
      nil
    end

    private def emit_estimate_progress
      return unless @on_chunk
      output = approximate_output_tokens
      return if output == @last_output_tokens
      @last_output_tokens = output
      @on_chunk.call(input_tokens: @last_input_tokens, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[OpenAIResponsesStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end

    # Rough char/4 estimate; replaced by the real count when the upstream
    # emits the response.completed event with usage data.
    private def approximate_output_tokens
      total_chars = @text.bytesize + @reasoning_text.bytesize +
        @function_calls.values.sum { |tc| tc[:arguments].to_s.bytesize }
      (total_chars / 4.0).ceil
    end

    private def emit_usage_progress(u)
      return unless @on_chunk
      total_prompt = u["input_tokens"].to_i
      output       = u["output_tokens"].to_i
      return if total_prompt == @last_input_tokens && output == @last_output_tokens
      @last_input_tokens = total_prompt
      @last_output_tokens = output
      @on_chunk.call(input_tokens: total_prompt, output_tokens: output)
    rescue => e
      Clacky::Logger.warn("[OpenAIResponsesStreamAggregator] on_chunk: #{e.class}: #{e.message}")
    end
  end
end
