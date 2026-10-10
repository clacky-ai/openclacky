# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/adapters/qq/qr_binder"

RSpec.describe Clacky::Channel::Adapters::Qq::QrBinder do
  subject(:binder) { described_class.new }

  # Fixed AES-256-GCM vector. The payload is iv (12) || ciphertext || tag (16).
  let(:key_b64)    { "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" }
  let(:encrypt_b64) { "YWJjZGVmMDEyMzQ19ZOReoHmNjCVK9CvuMbijH/F0wjFRIGv+OupEoZrx+1A33znVA==" }
  let(:plaintext) { "test-app-secret-value" }

  describe "#connect_url" do
    it "builds the official connect page URL" do
      url = binder.connect_url("task123", "openclacky")
      expect(url).to start_with("https://q.qq.com/qqbot/openclaw/connect.html?")
      expect(url).to include("task_id=task123")
      expect(url).to include("source=openclacky")
      expect(url).to include("_wv=2")
    end
  end

  describe "#create_task" do
    it "generates a key and returns the task id and url" do
      response = { "retcode" => 0, "data" => { "task_id" => "T1" } }
      allow(binder).to receive(:post_json).and_return(response)

      result = binder.create_task(source: "openclacky")
      expect(result[:task_id]).to eq("T1")
      expect(result[:key]).to be_a(String)
      expect(Base64.decode64(result[:key]).bytesize).to eq(32)
      expect(result[:connect_url]).to include("task_id=T1")
    end

    it "raises when the response lacks a task id" do
      allow(binder).to receive(:post_json).and_return({ "retcode" => 0, "data" => {} })
      expect { binder.create_task(source: "openclacky") }.to raise_error(described_class::BindError, /task_id/)
    end

    it "raises when retcode is non-zero" do
      allow(binder).to receive(:post_json).and_raise(described_class::BindError.new("non-zero retcode 1000"))
      expect { binder.create_task(source: "openclacky") }.to raise_error(described_class::BindError, /retcode/)
    end
  end

  describe "#poll" do
    it "returns a pending status" do
      response = { "retcode" => 0, "data" => { "status" => 1 } }
      allow(binder).to receive(:post_json).and_return(response)

      result = binder.poll("T1")
      expect(result[:status]).to eq(1)
      expect(result[:bot_app_id]).to be_nil
    end

    it "returns credentials on completion" do
      response = { "retcode" => 0,
                   "data" => { "status" => 2, "bot_appid" => "appid", "bot_encrypt_secret" => "enc",
                               "user_openid" => "openid" } }
      allow(binder).to receive(:post_json).and_return(response)

      result = binder.poll("T1")
      expect(result[:status]).to eq(2)
      expect(result[:bot_app_id]).to eq("appid")
      expect(result[:encrypt_secret]).to eq("enc")
      expect(result[:user_openid]).to eq("openid")
    end
  end

  describe "#extract_credentials" do
    it "decrypts a fixed GCM vector to the AppSecret" do
      creds = binder.extract_credentials(bot_app_id: "appid", encrypt_secret: encrypt_b64,
                                         user_openid: "openid", key: key_b64)
      expect(creds[:app_id]).to eq("appid")
      expect(creds[:app_secret]).to eq(plaintext)
      expect(creds[:user_openid]).to eq("openid")
    end

    it "raises when the key is missing" do
      expect do
        binder.extract_credentials(bot_app_id: "appid", encrypt_secret: encrypt_b64, key: nil)
      end.to raise_error(described_class::BindError, /key/i)
    end

    it "raises when the payload is tampered with" do
      raw = Base64.decode64(encrypt_b64)
      tampered = raw.dup
      tampered.setbyte(-1, tampered.getbyte(-1) ^ 0xff)
      enc = Base64.strict_encode64(tampered)

      expect do
        binder.extract_credentials(bot_app_id: "appid", encrypt_secret: enc, key: key_b64)
      end.to raise_error(described_class::BindError, /decrypt|AppSecret/)
    end
  end
end
