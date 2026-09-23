# frozen_string_literal: true

require "clacky/server/channel/adapters/feishu/adapter"

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
      allow(conn).to receive(:post) do |_path, &block|
        # Faraday executes the request block, which calls tenant_access_token
        req = double("req")
        allow(req).to receive(:headers).and_return({})
        allow(req).to receive(:params).and_return({})
        allow(req).to receive(:body=)
        block.call(req)
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

    it "wraps put with token retry" do
      conn = double("conn")
      response = double("response", success?: true, body: JSON.generate("code" => 0))
      request = double("request", headers: {})
      allow(request).to receive(:body=)
      allow(conn).to receive(:put).and_yield(request).and_return(response)
      allow(bot).to receive(:build_connection).and_return(conn)
      allow(bot).to receive(:tenant_access_token).and_return("token")

      result = bot.send(:put, "/open-apis/cardkit/v1/cards/card_1/settings", { sequence: 2 })

      expect(result).to eq("code" => 0)
      expect(conn).to have_received(:put)
    end
  end

  describe "progress cards" do
    before do
      allow(bot).to receive(:post) do |path, payload, params: {}|
        case path
        when "/open-apis/cardkit/v1/cards"
          { "code" => 0, "data" => { "card_id" => "card_progress" } }
        when "/open-apis/im/v1/messages/om_user/reply"
          { "code" => 0, "data" => { "message_id" => "om_progress" } }
        else
          raise "Unexpected POST #{path} payload=#{payload.inspect} params=#{params.inspect}"
        end
      end
    end

    it "creates a native streaming CardKit card and replies with its card reference" do
      result = bot.send_progress_card("oc_chat", "Thinking...", reply_to: "om_user")

      expect(bot).to have_received(:post).with("/open-apis/cardkit/v1/cards", satisfy { |payload|
        card = JSON.parse(payload[:data])
        payload[:type] == "card_json" &&
          card["schema"] == "2.0" &&
          card.dig("config", "streaming_mode") == true &&
          card.dig("config", "summary", "content") == "[Generating...]" &&
          card.dig("body", "elements", 0, "element_id") == "content" &&
          card.dig("body", "elements", 1, "content") == "<font color='grey'>Thinking...</font>"
      })
      expect(bot).to have_received(:post).with(
        "/open-apis/im/v1/messages/om_user/reply",
        {
          msg_type: "interactive",
          content: JSON.generate({ type: "card", data: { card_id: "card_progress" } })
        }
      )

      expect(result).to eq(message_id: "om_progress", progress_id: "card_progress")
    end

    it "updates the status element for a working task" do
      bot.send_progress_card("oc_chat", "Thinking...", reply_to: "om_user")
      expect(bot).to receive(:put).with(
        "/open-apis/cardkit/v1/cards/card_progress/elements/status/content",
        hash_including(content: "<font color='grey'>Working...</font>", sequence: 2)
      ).and_return("code" => 0)

      expect(bot.update_progress_card("card_progress", "Working...", state: :working)).to be true
    end

    it "writes final content, marks the status done, and closes streaming mode" do
      bot.send_progress_card("oc_chat", "Thinking...", reply_to: "om_user")
      calls = []
      allow(bot).to receive(:put) do |path, payload|
        calls << [path, payload]
        { "code" => 0 }
      end
      expect(bot).to receive(:patch) do |path, payload|
        expect(path).to eq("/open-apis/cardkit/v1/cards/card_progress/settings")
        settings = JSON.parse(payload[:settings])
        expect(settings.dig("config", "streaming_mode")).to be false
        expect(settings.dig("config", "summary", "content")).to eq("Finished")
        expect(payload[:sequence]).to eq(4)
        { "code" => 0 }
      end

      expect(bot.update_progress_card("card_progress", "Finished", state: :success)).to be true
      expect(calls.size).to eq(2)
      expect(calls[0][0]).to eq(
        "/open-apis/cardkit/v1/cards/card_progress/elements/status/content"
      )
      expect(calls[0][1]).to include(
        content: "<font color='grey'>Done</font>",
        sequence: 2
      )
      expect(calls[1][0]).to eq(
        "/open-apis/cardkit/v1/cards/card_progress/elements/content/content"
      )
      expect(calls[1][1]).to include(content: "Finished", sequence: 3)
    end

    it "reports a failed final content update so the caller can fall back" do
      bot.send_progress_card("oc_chat", "Thinking...", reply_to: "om_user")
      allow(bot).to receive(:put) do |path, _payload|
        if path.include?("/elements/content/content")
          { "code" => 230001, "msg" => "invalid card" }
        else
          { "code" => 0 }
        end
      end
      allow(bot).to receive(:patch).and_return("code" => 0)

      expect(bot.update_progress_card("card_progress", "Finished", state: :success)).to be false
      expect(bot.update_progress_card("card_progress", "Finished", state: :success)).to be false
    end

    {
      failed: "Failed",
      interrupted: "Stopped",
      waiting: "Waiting for input"
    }.each do |state, label|
      it "marks a #{state} task as #{label}" do
        bot.send_progress_card("oc_chat", "Thinking...", reply_to: "om_user")
        status_content = nil
        allow(bot).to receive(:put) do |path, payload|
          status_content = payload[:content] if path.include?("/elements/status/content")
          { "code" => 0 }
        end
        allow(bot).to receive(:patch).and_return("code" => 0)

        expect(bot.update_progress_card("card_progress", "Result", state: state)).to be true
        expect(status_content).to eq("<font color='grey'>#{label}</font>")
      end
    end
  end
end
