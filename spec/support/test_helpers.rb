# frozen_string_literal: true

module TestHelpers
  # Capture stdout and stderr output
  def capture_output
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new

    begin
      yield
      $stdout.string + $stderr.string
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end

  # Create a temporary config file for testing
  def with_temp_config(config_data = {})
    Dir.mktmpdir do |dir|
      config_file = File.join(dir, "config.yml")
      File.write(config_file, config_data.to_yaml) unless config_data.empty?

      yield config_file
    end
  end

  # Mock API response for testing
  def mock_api_response(content: "Test response", tool_calls: nil)
    {
      content: content,
      tool_calls: tool_calls,
      finish_reason: tool_calls ? "tool_calls" : "stop",
      usage: {
        prompt_tokens: 10,
        completion_tokens: 20,
        total_tokens: 30
      }
    }
  end

  # Mock tool call for testing
  def mock_tool_call(name: "calculator", args: '{"expression":"1+1"}')
    {
      id: "call_#{SecureRandom.hex(4)}",
      type: "function",
      name: name,
      arguments: args
    }
  end
end

RSpec.configure do |config|
  config.include TestHelpers
end
