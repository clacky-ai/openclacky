# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    MAX_RETRIES = 10
    RETRY_DELAY = 5 # seconds

    def initialize(api_key, base_url:)
      @api_key = api_key
      @base_url = base_url
    end

    def send_message(content, model:, max_tokens:)
      response = connection.post("chat/completions") do |req|
        req.body = {
          model: model,
          max_tokens: max_tokens,
          messages: [
            {
              role: "user",
              content: content
            }
          ]
        }.to_json
      end

      handle_response(response)
    end

    def send_messages(messages, model:, max_tokens:)
      response = connection.post("chat/completions") do |req|
        req.body = {
          model: model,
          max_tokens: max_tokens,
          messages: messages
        }.to_json
      end

      handle_response(response)
    end

    # Send messages with function calling (tools) support
    # Options:
    #   - enable_caching: Enable prompt caching for system prompt and tools (default: false)
    def send_messages_with_tools(messages, model:, tools:, max_tokens:, verbose: false, enable_caching: false)
      body = {
        model: model,
        max_tokens: max_tokens,
        messages: messages
      }

      # Add tools if provided
      # For Claude API with caching: mark the last tool definition with cache_control
      if tools&.any?
        if enable_caching && supports_prompt_caching?(model)
          # Deep clone tools to avoid modifying original
          cached_tools = tools.map { |tool| deep_clone(tool) }
          # Mark the last tool for caching (Claude caches from cache breakpoint to end)
          cached_tools.last[:cache_control] = { type: "ephemeral" }
          body[:tools] = cached_tools
        else
          body[:tools] = tools
        end
      end

      # Debug output
      if verbose || ENV["CLACKY_DEBUG"]
        puts "\n[DEBUG] Current directory: #{Dir.pwd}"
        puts "[DEBUG] Request to API:"

        # Create a simplified version of the body for display
        display_body = body.dup
        if display_body[:tools]&.any?
          tool_names = display_body[:tools].map { |t| t.dig(:function, :name) }.compact
          display_body[:tools] = "use tools: #{tool_names.join(', ')}"
        end

        puts JSON.pretty_generate(display_body)
      end

      response = connection.post("chat/completions") do |req|
        req.body = body.to_json
      end

      handle_tool_response(response)
    end

    private

    # Check if the model supports prompt caching
    # Currently only Claude 3.5 Sonnet and newer Claude models support this
    def supports_prompt_caching?(model)
      model_str = model.to_s.downcase
      # Claude 3.5 Sonnet (20241022 and newer) supports prompt caching
      # Also Claude 3.7 Sonnet and Opus models when they're released
      model_str.include?("claude-3.5-sonnet") ||
        model_str.include?("claude-3-7") ||
        model_str.include?("claude-4")
    end

    # Deep clone a hash/array structure (for tool definitions)
    def deep_clone(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k] = deep_clone(v) }
      when Array
        obj.map { |item| deep_clone(item) }
      when String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass
        obj
      else
        obj.dup rescue obj
      end
    end

    def connection
      @connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"] = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.options.timeout = 120  # Read timeout in seconds
        conn.options.open_timeout = 10  # Connection timeout in seconds
        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        data["choices"].first["message"]["content"]
      when 401
        raise Error, "Invalid API key"
      when 429
        raise Error, "Rate limit exceeded"
      when 500..599
        raise Error, "Server error: #{response.status}"
      else
        raise Error, "Unexpected error: #{response.status} - #{response.body}"
      end
    end

    def handle_tool_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        message = data["choices"].first["message"]
        usage = data["usage"]

        # Debug: show raw API response content
        if ENV["CLACKY_DEBUG"]
          puts "\n[DEBUG] Raw API response content:"
          puts "  content: #{message["content"].inspect}"
          puts "  content length: #{message["content"]&.length || 0}"
        end

        # Parse usage with cache information
        usage_data = {
          prompt_tokens: usage["prompt_tokens"],
          completion_tokens: usage["completion_tokens"],
          total_tokens: usage["total_tokens"]
        }
        
        # Add cache metrics if present (Claude API with prompt caching)
        if usage["cache_creation_input_tokens"]
          usage_data[:cache_creation_input_tokens] = usage["cache_creation_input_tokens"]
        end
        if usage["cache_read_input_tokens"]
          usage_data[:cache_read_input_tokens] = usage["cache_read_input_tokens"]
        end
        
        {
          content: message["content"],
          tool_calls: parse_tool_calls(message["tool_calls"]),
          finish_reason: data["choices"].first["finish_reason"],
          usage: usage_data
        }
      when 401
        raise Error, "Invalid API key"
      when 429
        raise Error, "Rate limit exceeded"
      when 500..599
        error_body = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          response.body
        end
        raise Error, "Server error: #{response.status}\nResponse: #{error_body.inspect}"
      else
        raise Error, "Unexpected error: #{response.status} - #{response.body}"
      end
    end

    def parse_tool_calls(tool_calls)
      return nil if tool_calls.nil? || tool_calls.empty?

      tool_calls.map do |call|
        {
          id: call["id"],
          type: call["type"],
          name: call["function"]["name"],
          arguments: call["function"]["arguments"]
        }
      end
    end
  end
end
