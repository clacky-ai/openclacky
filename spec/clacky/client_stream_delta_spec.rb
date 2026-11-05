# frozen_string_literal: true

require "spec_helper"
require "clacky/client"

RSpec.describe Clacky::Client, "streamed reply deltas" do
  let(:client) { described_class.new("k", base_url: "https://api.example.com", model: "gpt-4") }

  def frame(json)
    "data: #{json}\n\n"
  end

  # Each element of reads is delivered to on_data as one network read.
  def stub_reads(reads)
    req_stub = double("faraday_request", headers: {})
    allow(req_stub).to receive(:body=)
    options = double("faraday_options")
    allow(req_stub).to receive(:options).and_return(options)
    allow(options).to receive(:on_data=) do |proc_|
      reads.each { |read| proc_.call(read, read.bytesize, nil) }
    end
    response = Struct.new(:status, :body, :env, :headers).new(200, "", Struct.new(:body).new(""), {})
    conn = instance_double(Faraday::Connection)
    allow(conn).to receive(:post).and_yield(req_stub).and_return(response)
    client.instance_variable_set(:@openai_connection, conn)
  end

  it "merges the frames of one network read into one delta per kind" do
    stub_reads([
      frame('{"choices":[{"index":0,"delta":{"reasoning_content":"a"}}]}') +
        frame('{"choices":[{"index":0,"delta":{"content":"He"}}]}') +
        frame('{"choices":[{"index":0,"delta":{"content":"llo"}}]}'),
      frame('{"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}')
    ])
    deltas = []

    result = client.send(:send_openai_stream_request, { model: "gpt-4" }, proc {},
                         on_delta: ->(kind, text) { deltas << [kind, text] })

    expect(deltas).to eq([[:reasoning, "a"], [:text, "Hello"], [:text, " world"]])
    expect(result[:content]).to eq("Hello world")
  end

  it "still returns the full response when on_delta raises" do
    stub_reads([frame('{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}')])

    result = client.send(:send_openai_stream_request, { model: "gpt-4" }, proc {},
                         on_delta: ->(_kind, _text) { raise "boom" })

    expect(result[:content]).to eq("ok")
  end
end
