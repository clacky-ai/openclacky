# frozen_string_literal: true

require "spec_helper"
require "webrick"

RSpec.describe Clacky::PlatformHttpClient, "#download_file" do
  let(:client) { described_class.new }
  let(:tmpdir) { Dir.mktmpdir }
  let(:dest)   { File.join(tmpdir, "payload.bin") }

  after do
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
  end

  # Simulate a tiny HTTP chunk stream without actually opening a socket by
  # stubbing Net::HTTP#request to yield a response whose #read_body emits
  # the given payload. Avoids flaky SSL / port setup on CI.
  #
  # Yields the spy so tests can assert which URLs were hit.
  class FakeResp
    def initialize(code, body: "", location: nil)
      @code     = code
      @body     = body
      @location = location
    end
    attr_reader :code

    def [](key)
      "location" == key.downcase ? @location : nil
    end

    def read_body
      yield @body unless @body.nil?
    end
  end

  # Helper: stub PlatformHttpClient#stream_download so we control the outcome
  # per-URL. This keeps the test focused on failover orchestration logic.
  def stub_stream(sequence)
    calls = []
    allow(client).to receive(:stream_download) do |url, _tmp_dest, **_kwargs|
      calls << url
      outcome = sequence.shift
      raise "stub_stream: ran out of scripted responses for URL #{url}" if outcome.nil?

      case outcome
      when :ok
        File.write(_tmp_dest, "OK")
        2
      when StandardError
        raise outcome
      else
        raise "Unknown outcome #{outcome.inspect}"
      end
    end
    calls
  end

  describe "primary → fallback failover" do
    let(:primary_url)  { "#{described_class::PRIMARY_HOST}/rails/active_storage/blobs/redirect/abc/file.zip" }
    let(:fallback_url) { "#{described_class::FALLBACK_HOST}/rails/active_storage/blobs/redirect/abc/file.zip" }

    it "succeeds on the first attempt without touching the fallback" do
      calls = stub_stream([:ok])

      result = client.download_file(primary_url, dest)

      expect(result[:success]).to be true
      expect(File.read(dest)).to eq("OK")
      expect(calls).to eq([primary_url])
    end

    it "retries the primary host once, then swaps to fallback host" do
      err = Clacky::PlatformHttpClient::RetryableNetworkError.new("Timeout")
      calls = stub_stream([err, :ok])
      allow(client).to receive(:sleep) # skip back-off

      result = client.download_file(primary_url, dest)

      expect(result[:success]).to be true
      # 1 attempt on primary + 1 successful on fallback (ATTEMPTS_PER_HOST = 1)
      expect(calls).to eq([primary_url, fallback_url])
    end

    it "reports a structured failure when every host is exhausted" do
      err = Clacky::PlatformHttpClient::RetryableNetworkError.new("Connection error: reset")
      stub_stream([err, err])
      allow(client).to receive(:sleep)

      result = client.download_file(primary_url, dest)

      expect(result[:success]).to be false
      expect(result[:error]).to include("Download failed")
      expect(result[:error]).to include("Connection error")
      expect(File.exist?(dest)).to be false
      expect(File.exist?("#{dest}.part")).to be false
    end

    it "does NOT swap host for non-primary URLs (e.g. S3 presigned URLs)" do
      external = "https://openclacky-skills.s3.amazonaws.com/abc.zip?sig=xyz"
      err = Clacky::PlatformHttpClient::RetryableNetworkError.new("Timeout")
      calls = stub_stream([err])
      allow(client).to receive(:sleep)

      result = client.download_file(external, dest)

      expect(result[:success]).to be false
      # Only one attempt against the original host — no rewritten URL (ATTEMPTS_PER_HOST = 1).
      expect(calls).to eq([external])
    end
  end

  describe "URL host rewriting" do
    it "preserves path + query when swapping to the fallback host" do
      url = "#{described_class::PRIMARY_HOST}/path/a/b?x=1&y=2"
      calls = stub_stream([
        Clacky::PlatformHttpClient::RetryableNetworkError.new("Timeout"),
        :ok
      ])
      allow(client).to receive(:sleep)

      client.download_file(url, dest)

      expect(calls.last).to eq("#{described_class::FALLBACK_HOST}/path/a/b?x=1&y=2")
    end
  end
end
