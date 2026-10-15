# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples "streaming HTTP error classification" do
  [true, false].each do |streamed_body|
    context "when the error body is #{streamed_body ? 'delivered through on_data' : 'retained in the response'}" do
      {
        503 => Clacky::RetryableError,
        429 => Clacky::RetryableError,
        401 => Clacky::AgentError,
        402 => Clacky::InsufficientCreditError,
        400 => Clacky::BadRequestError
      }.each do |status, error_class|
        it "preserves error classification and context for HTTP #{status}" do
          error_body = { error: { message: "upstream failure #{status}" } }.to_json
          response = Faraday::Response.new(
            status: status,
            body: streamed_body ? "" : error_body,
            response_headers: { "X-Clacky-Routed-Tier" => "upgrade" }
          )
          connection = instance_double(Faraday::Connection)
          allow(connection).to receive(:post) do |_path, &request_block|
            request = Faraday::Request.new
            request.headers = {}
            request.options = Faraday::RequestOptions.new
            request_block.call(request)
            if streamed_body
              # JSON HTTP error bodies have no SSE delimiter and stay buffered.
              midpoint = error_body.bytesize / 2
              request.options.on_data.call(error_body[0...midpoint], midpoint, nil)
              request.options.on_data.call(error_body[midpoint..-1], error_body.bytesize, nil)
            end
            response
          end
          client.instance_variable_set(connection_ivar, connection)

          expect {
            client.send_messages_with_tools(
              [{ role: "user", content: "hello" }], model: model,
              tools: [], max_tokens: 100, on_chunk: proc {}
            )
          }.to raise_error(error_class) { |error|
            if error.is_a?(Clacky::RetryableError)
              expect(error.routed_tier).to eq("upgrade")
            else
              expect(error.raw_message).to eq("upstream failure #{status}")
            end
          }
        end
      end
    end
  end
end

RSpec.describe Clacky::Client, "streaming HTTP errors" do
  [
    ["Anthropic", "https://api.anthropic.com", "claude-sonnet-4.6", "anthropic-messages"],
    ["DeepSeek OpenAI format", "https://api.deepseek.com", "deepseek-v4-pro", nil],
    ["DeepSeek Anthropic format", "https://api.deepseek.com/anthropic", "deepseek-v4-pro", "anthropic-messages"],
    ["OpenClacky DeepSeek", "https://api.openclacky.com", "dsk-deepseek-v4-pro", nil]
  ].each do |label, base_url, model_name, api_format|
    context label do
      let(:model) { model_name }
      let(:client) do
        described_class.new("test-key", base_url: base_url, model: model, api_format: api_format)
      end
      let(:connection_ivar) do
        api_format == "anthropic-messages" ? :@anthropic_connection : :@openai_connection
      end

      include_examples "streaming HTTP error classification"
    end
  end
end
