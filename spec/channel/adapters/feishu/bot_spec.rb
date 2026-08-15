# frozen_string_literal: true

require "clacky/server/channel/adapters/feishu/bot"

RSpec.describe Clacky::Channel::Adapters::Feishu::Bot do
  let(:bot) do
    described_class.new(app_id: "cli_test", app_secret: "secret")
  end

  describe "#with_token_retry" do
    it "returns the response when the token is valid" do
      result = bot.send(:with_token_retry) { { "code" => 0 } }
      expect(result).to eq("code" => 0)
    end

    it "clears the token cache and retries once when token is invalid (99991663)" do
      bot.instance_variable_set(:@token_cache, "stale-token")
      bot.instance_variable_set(:@token_expires_at, Time.now + 3600)

      calls = 0
      result = bot.send(:with_token_retry) do
        calls += 1
        calls == 1 ? { "code" => 99991663 } : { "code" => 0, "msg" => "success" }
      end

      expect(result).to eq("code" => 0, "msg" => "success")
      expect(calls).to eq(2)
      expect(bot.instance_variable_get(:@token_cache)).to be_nil
      expect(bot.instance_variable_get(:@token_expires_at)).to be_nil
    end

    it "does not retry when the error is unrelated" do
      calls = 0
      result = bot.send(:with_token_retry) do
        calls += 1
        { "code" => 99991672, "msg" => "scope missing" }
      end

      expect(result["code"]).to eq(99991672)
      expect(calls).to eq(1)
    end
  end

  describe "authenticated requests retry on token revocation" do
    it "wraps post with token retry and refreshes the cached token" do
      bot.instance_variable_set(:@token_cache, "stale-token")
      bot.instance_variable_set(:@token_expires_at, Time.now + 3600)

      conn = double("conn")
      resp1 = double("resp1", success?: true, body: JSON.generate("code" => 99991663))
      resp2 = double("resp2", success?: true, body: JSON.generate("code" => 0, "msg" => "ok"))

      calls = 0
      allow(conn).to receive(:post) do |&_block|
        calls += 1
        calls == 1 ? resp1 : resp2
      end

      allow(bot).to receive(:build_connection).and_return(conn)
      allow(bot).to receive(:post_without_auth).and_return(
        "code" => 0, "tenant_access_token" => "fresh-token"
      )

      result = bot.send(:post, "/open-apis/im/v1/messages", { receive_id: "oc_1" })

      expect(result["code"]).to eq(0)
      expect(calls).to eq(2)
      expect(bot.instance_variable_get(:@token_cache)).to eq("fresh-token")
    end
  end
end
