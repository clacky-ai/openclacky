# frozen_string_literal: true

require "clacky/server/channel/adapters/qq/gateway_client"

RSpec.describe Clacky::Channel::Adapters::Qq::GatewayClient do
  let(:client) do
    described_class.new(
      url: "wss://example.com/gateway",
      token: "access-token",
      intents: 1 << 25
    )
  end

  describe "#backoff_seconds" do
    it "grows exponentially, staying within +/-50% jitter bounds" do
      delays = Array.new(4) { client.send(:backoff_seconds) }
      expect(delays[0]).to be_between(1, 3)
      expect(delays[1]).to be_between(2, 6)
      expect(delays[2]).to be_between(4, 12)
      expect(delays[3]).to be_between(8, 24)
    end

    it "never exceeds MAX_BACKOFF_S even after many attempts" do
      delays = Array.new(12) { client.send(:backoff_seconds) }
      expect(delays.last).to be <= described_class::MAX_BACKOFF_S
    end
  end

  describe "#reset_backoff" do
    it "restarts the attempt counter" do
      3.times { client.send(:backoff_seconds) }
      client.send(:reset_backoff)
      delay = client.send(:backoff_seconds)
      expect(delay).to be <= described_class::BASE_BACKOFF_S * 1.5
    end
  end

  describe "payload dispatch" do
    def dispatch(payload)
      client.send(:handle_payload, payload)
    end

    def hello
      { "op" => 10, "d" => { "heartbeat_interval" => 41_250 } }
    end

    it "records seq on every payload" do
      dispatch(hello.merge("s" => 42))
      expect(client.instance_variable_get(:@last_seq)).to eq(42)
    end

    it "on Hello stores the interval and sends Identify with no session" do
      identified = nil
      allow(client).to receive(:send_identify) { identified = true }
      dispatch(hello)
      expect(client.instance_variable_get(:@heartbeat_interval)).to eq(41_250)
      expect(identified).to be(true)
    end

    it "on Hello sends Resume when a session/seq exists" do
      resumed = nil
      client.instance_variable_set(:@session_id, "sess-1")
      client.instance_variable_get(:@last_seq)
      client.instance_variable_set(:@last_seq, 7)
      allow(client).to receive(:send_resume) { resumed = true }
      dispatch(hello)
      expect(resumed).to be(true)
    end

    it "captures the session id on READY" do
      client.instance_variable_set(:@on_event, proc {})
      dispatch(
        "op" => 0, "s" => 1, "t" => "READY",
        "d" => { "session_id" => "sess-9", "user" => { "id" => "1", "username" => "bot" } }
      )
      expect(client.instance_variable_get(:@session_id)).to eq("sess-9")
      expect(client.instance_variable_get(:@reconnect_attempts)).to eq(0)
    end

    it "forwards non-system dispatches as events" do
      events = []
      client.instance_variable_set(:@on_event, proc { |e| events << e })
      dispatch(
        "op" => 0, "s" => 2, "t" => "C2C_MESSAGE_CREATE",
        "d" => { "id" => "m1", "content" => "hi" }
      )
      expect(events).to eq([{ type: "C2C_MESSAGE_CREATE", data: { "id" => "m1", "content" => "hi" } }])
    end

    it "answers op 1 with a heartbeat" do
      sent = nil
      allow(client).to receive(:send_heartbeat) { sent = true }
      dispatch("op" => 1, "d" => nil)
      expect(sent).to be(true)
    end

    it "on op 7 (Reconnect) closes the socket" do
      socket = double("socket")
      client.instance_variable_set(:@socket, socket)
      expect(socket).to receive(:close)
      dispatch("op" => 7, "d" => nil)
    end

    it "on op 9 non-resumable drops the session" do
      socket = double("socket")
      client.instance_variable_set(:@socket, socket)
      client.instance_variable_set(:@session_id, "old")
      allow(socket).to receive(:close)
      dispatch("op" => 9, "d" => false)
      expect(client.instance_variable_get(:@session_id)).to be_nil
      expect(client.instance_variable_get(:@force_identify)).to be(true)
    end

    it "on op 9 resumable keeps the session" do
      socket = double("socket")
      client.instance_variable_set(:@socket, socket)
      client.instance_variable_set(:@session_id, "keep")
      allow(socket).to receive(:close)
      dispatch("op" => 9, "d" => true)
      expect(client.instance_variable_get(:@session_id)).to eq("keep")
    end

    it "marks the heartbeat acked on op 11" do
      client.instance_variable_set(:@heartbeat_acked, false)
      dispatch("op" => 11, "d" => nil)
      expect(client.instance_variable_get(:@heartbeat_acked)).to be(true)
    end

    it "does not propagate errors from a faulty dispatch handler" do
      expect do
        client.send(:handle_dispatch, "C2C_MESSAGE_CREATE", nil)
      end.not_to raise_error
    end
  end

  describe "close handling" do
    it "raises AuthError and stops for fatal close codes" do
      [4010, 4014, 4914, 4915].each do |code|
        c = described_class.new(url: "wss://x", token: "t", intents: 1)
        expect do
          c.send(:handle_close_frame, double(code: code, data: "nope"))
        end.to raise_error(described_class::AuthError)
        expect(c.instance_variable_get(:@running)).to be(false)
      end
    end

    it "drops the session for needs-identify close codes" do
      close_data = double(code: 4006, data: "bad session")
      client.send(:handle_close_frame, close_data)
      expect(client.instance_variable_get(:@force_identify)).to be(true)
      expect(client.instance_variable_get(:@session_id)).to be_nil
    end

    it "ignores unknown close codes" do
      close_data = double(code: 1006, data: "abnormal")
      expect { client.send(:handle_close_frame, close_data) }.not_to raise_error
    end
  end

  describe "identify / resume payloads" do
    it "builds an Identify frame with the QQBot token and intents" do
      captured = nil
      allow(client).to receive(:send_raw_frame) do |_type, data|
        captured = JSON.parse(data)
      end
      client.send(:send_identify)
      expect(captured["op"]).to eq(2)
      expect(captured["d"]["token"]).to eq("QQBot access-token")
      expect(captured["d"]["intents"]).to eq(1 << 25)
      expect(captured["d"]["shard"]).to eq([0, 1])
    end

    it "builds a Resume frame with session id and seq" do
      client.instance_variable_set(:@session_id, "sess-2")
      client.instance_variable_set(:@last_seq, 99)
      captured = nil
      allow(client).to receive(:send_raw_frame) do |_type, data|
        captured = JSON.parse(data)
      end
      client.send(:send_resume)
      expect(captured["op"]).to eq(6)
      expect(captured["d"]["session_id"]).to eq("sess-2")
      expect(captured["d"]["seq"]).to eq(99)
    end
  end

  describe "token refresh" do
    it "uses the token provider before connecting" do
      c = described_class.new(
        url: "wss://x", token: "old", intents: 1,
        token_provider: proc { "fresh-token" }
      )
      c.send(:refresh_token!)
      expect(c.instance_variable_get(:@token)).to eq("fresh-token")
    end

    it "keeps the old token when the provider fails" do
      c = described_class.new(
        url: "wss://x", token: "old", intents: 1,
        token_provider: proc { raise "boom" }
      )
      c.send(:refresh_token!)
      expect(c.instance_variable_get(:@token)).to eq("old")
    end
  end
end
