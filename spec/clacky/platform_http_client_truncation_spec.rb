# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::PlatformHttpClient, "#stream_download Content-Length verification" do
  let(:client) { described_class.new }
  let(:tmpdir) { Dir.mktmpdir }
  let(:dest)   { File.join(tmpdir, "out.bin") }

  after { FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir) }

  class FakeTruncatedResp
    def initialize(code:, body:, content_length: nil)
      @code = code.to_s
      @body = body
      @content_length = content_length
    end
    attr_reader :code

    def [](key)
      case key.to_s.downcase
      when "content-length" then @content_length&.to_s
      when "location"       then nil
      end
    end

    def read_body
      yield @body
    end
  end

  def stub_http_with(resp)
    fake_http = instance_double(Net::HTTP)
    allow(fake_http).to receive(:use_ssl=)
    allow(fake_http).to receive(:open_timeout=)
    allow(fake_http).to receive(:read_timeout=)
    allow(fake_http).to receive(:start).and_yield(fake_http)
    allow(fake_http).to receive(:request).and_yield(resp)
    allow(Net::HTTP).to receive(:new).and_return(fake_http)
  end

  it "raises RetryableNetworkError when bytes written < Content-Length" do
    stub_http_with(FakeTruncatedResp.new(code: 200, body: "abc", content_length: 100))

    expect {
      client.send(:stream_download, "https://example.com/file.zip", dest, read_timeout: 5)
    }.to raise_error(Clacky::PlatformHttpClient::RetryableNetworkError, /Truncated download/)
  end

  it "succeeds when bytes written equal Content-Length" do
    stub_http_with(FakeTruncatedResp.new(code: 200, body: "hello", content_length: 5))

    bytes = client.send(:stream_download, "https://example.com/file.zip", dest, read_timeout: 5)

    expect(bytes).to eq(5)
    expect(File.read(dest)).to eq("hello")
  end

  it "succeeds when Content-Length is absent (chunked transfer)" do
    stub_http_with(FakeTruncatedResp.new(code: 200, body: "hello", content_length: nil))

    bytes = client.send(:stream_download, "https://example.com/file.zip", dest, read_timeout: 5)

    expect(bytes).to eq(5)
  end
end
