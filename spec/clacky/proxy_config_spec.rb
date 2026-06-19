# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ProxyConfig do
  let(:cfg) { instance_double(Clacky::AgentConfig, proxy_url: nil) }

  before do
    allow(Clacky::AgentConfig).to receive(:load).and_return(cfg)
    described_class::PROXY_ENV_KEYS.each { |k| ENV.delete(k) }
    described_class.instance_variable_set(:@installed_signature, nil)
    described_class.instance_variable_set(:@epoch, 0)
  end

  after do
    described_class::PROXY_ENV_KEYS.each { |k| ENV.delete(k) }
    described_class.instance_variable_set(:@installed_signature, nil)
    described_class.instance_variable_set(:@epoch, 0)
  end

  describe ".install!" do
    context "when no proxy is configured" do
      it "strips all proxy ENV keys regardless of what the shell exported" do
        ENV["HTTP_PROXY"] = "http://envproxy:1080"
        ENV["http_proxy"] = "http://envproxy:1080"
        ENV["all_proxy"]  = "socks5://127.0.0.1:1086"

        described_class.install!

        described_class::PROXY_ENV_KEYS.each do |k|
          expect(ENV[k]).to be_nil, "expected ENV[#{k.inspect}] to be cleared"
        end
      end

      it "leaves Faraday.ignore_env_proxy = false so future ENV writes are honoured" do
        described_class.install!
        expect(Faraday.ignore_env_proxy).to eq(false)
      end
    end

    context "when proxy_url is configured" do
      before { allow(cfg).to receive(:proxy_url).and_return("http://my.proxy:8080") }

      it "writes proxy_url into http_proxy/https_proxy ENV keys" do
        described_class.install!
        %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY].each do |k|
          expect(ENV[k]).to eq("http://my.proxy:8080")
        end
      end

      it "leaves Faraday.ignore_env_proxy = false so Faraday picks up the new ENV" do
        described_class.install!
        expect(Faraday.ignore_env_proxy).to eq(false)
      end

      it "ignores the shell's existing proxy ENV before applying its own" do
        ENV["all_proxy"] = "socks5://127.0.0.1:1086"
        described_class.install!
        expect(ENV["all_proxy"]).to be_nil
      end
    end
  end

  describe "idempotency and epoch" do
    it "does not increment epoch on a repeat call with identical settings" do
      described_class.install!
      epoch_before = described_class.epoch
      described_class.install!
      expect(described_class.epoch).to eq(epoch_before)
    end

    it "increments epoch when proxy_url changes" do
      allow(cfg).to receive(:proxy_url).and_return("http://first:1111")
      described_class.install!
      epoch_first = described_class.epoch

      allow(cfg).to receive(:proxy_url).and_return("http://second:2222")
      described_class.install!
      expect(described_class.epoch).to eq(epoch_first + 1)
    end

    it "increments epoch when toggling between configured and empty proxy_url" do
      allow(cfg).to receive(:proxy_url).and_return("http://my.proxy:8080")
      described_class.install!
      epoch_with_proxy = described_class.epoch

      allow(cfg).to receive(:proxy_url).and_return("")
      described_class.install!
      expect(described_class.epoch).to eq(epoch_with_proxy + 1)
    end
  end

  describe ".reset_cache!" do
    it "clears the cached signature and re-applies install!" do
      allow(cfg).to receive(:proxy_url).and_return("http://first:1111")
      described_class.install!
      expect(ENV["HTTP_PROXY"]).to eq("http://first:1111")

      allow(cfg).to receive(:proxy_url).and_return("http://second:2222")
      described_class.reset_cache!
      expect(ENV["HTTP_PROXY"]).to eq("http://second:2222")
    end
  end

  describe "AgentConfig.load failure tolerance" do
    it "falls back to no-proxy (strip ENV) when load raises" do
      allow(Clacky::AgentConfig).to receive(:load).and_raise(StandardError, "boom")
      ENV["HTTP_PROXY"] = "http://envproxy:1080"
      described_class.install!
      expect(ENV["HTTP_PROXY"]).to be_nil
    end
  end
end
