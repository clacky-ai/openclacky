# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"
require "clacky/server/web_ui_controller"

RSpec.describe Clacky::Channel::ChannelManager do
  let(:sent) { [] }
  let(:adapter) do
    rec = sent
    double("adapter").tap do |a|
      allow(a).to receive(:send_text) { |_chat_id, text, _opts| rec << text }
    end
  end

  let(:session_id) { "sess_1111aaaa" }
  let(:event) { { platform: :weixin, chat_id: "chat_1", user_id: "user_1", message_id: "msg_1" } }
  let(:key) { "weixin:chat:chat_1" }
  let(:web_ui) { Clacky::Server::WebUIController.new(session_id, ->(_sid, _ev) {}) }
  let(:channel_ui) do
    Clacky::Channel::ChannelUIController.new(event, -> { adapter }, -> { false }, -> { false })
  end
  let(:agent) { double("agent", channel_info: { platform: "weixin", chat_id: "chat_1", user_id: "user_1" }) }

  let(:persisted) { [] }

  let(:session) do
    {
      ui: web_ui,
      channel_ui: channel_ui,
      agent: agent,
      channel_keys: Set.new([key])
    }
  end

  let(:registry) do
    store = session
    sid = session_id
    double("registry").tap do |r|
      allow(r).to receive(:list).and_return([{ id: sid, source: "channel" }])
      allow(r).to receive(:list).with(limit: nil).and_return([{ id: sid, source: "channel" }])
      allow(r).to receive(:ensure).and_return(true)
      allow(r).to receive(:with_session).with(sid).and_yield(store)
    end
  end

  let(:manager) do
    rec = persisted
    described_class.new(
      session_registry: registry,
      session_builder: ->(**_kw) { session_id },
      run_agent_task: ->(*) {},
      interrupt_session: ->(*) {},
      persist_session: ->(a) { rec << a },
      channel_config: double("channel_config"),
      binding_mode: :chat
    )
  end

  before do
    web_ui.subscribe_channel(channel_ui)
    allow(agent).to receive(:channel_info=)
  end

  def unbind
    manager.handle_command(adapter, event, "/unbind")
  end

  describe "/bind" do
    let(:target_id) { "sess_2222bbbb" }
    let(:target_agent) { double("target_agent", channel_info: nil) }
    let(:target_ui) { Clacky::Server::WebUIController.new(target_id, ->(_sid, _ev) {}) }
    let(:target_session) { { ui: target_ui, agent: target_agent, channel_keys: Set.new } }

    before do
      allow(target_agent).to receive(:channel_info=)
      rows = [{ id: session_id, source: "channel" }, { id: target_id, source: "channel" }]
      allow(registry).to receive(:list).and_return(rows)
      allow(registry).to receive(:list).with(limit: nil).and_return(rows)
      allow(registry).to receive(:with_session).with(target_id).and_yield(target_session)
    end

    it "stamps and persists channel_info on the newly bound session" do
      expect(target_agent).to receive(:channel_info=)
        .with(hash_including(platform: :weixin, chat_id: "chat_1"))

      manager.handle_command(adapter, event, "/bind #{target_id}")

      expect(target_session[:channel_keys]).to include(key)
      expect(persisted).to include(target_agent)
      expect(sent).to eq(["Bound to session `#{target_id[0, 8]}`."])
    end

    it "clears channel_info from the previously bound session" do
      expect(agent).to receive(:channel_info=).with(nil)

      manager.handle_command(adapter, event, "/bind #{target_id}")

      expect(web_ui.channel_subscribed?).to be false
      expect(session[:channel_keys]).not_to include(key)
    end
  end

  describe "/unbind" do
    it "detaches channel_ui from the session web_ui so outbound events stop reaching the chat" do
      expect(web_ui.channel_subscribed?).to be true

      unbind

      expect(web_ui.channel_subscribed?).to be false
      expect(session).not_to have_key(:channel_ui)
      expect(sent).to eq(["Unbound."])
    end

    it "clears both channel_keys and channel_info" do
      expect(agent).to receive(:channel_info=).with(nil)

      unbind

      expect(session[:channel_keys]).to be_empty
    end

    it "keeps channel_ui subscribed while another key still points at the session" do
      session[:channel_keys].add("weixin:chat:chat_2")

      unbind

      expect(web_ui.channel_subscribed?).to be true
      expect(session[:channel_ui]).to eq(channel_ui)
      expect(session[:channel_keys].to_a).to eq(["weixin:chat:chat_2"])
    end

    it "reports no binding and leaves subscriptions untouched when the key is unknown" do
      session[:channel_keys] = Set.new(["weixin:chat:other"])

      unbind

      expect(sent).to eq(["No binding found."])
      expect(web_ui.channel_subscribed?).to be true
      expect(session[:channel_ui]).to eq(channel_ui)
    end

    it "persists the cleared channel_info so a restart cannot restore the binding" do
      expect(agent).to receive(:channel_info=).with(nil)

      unbind

      expect(persisted).to eq([agent])
    end
  end

  describe "/unbind with a stale binding left on an older session" do
    let(:stale_id) { "sess_964a5317" }
    let(:stale_agent) do
      double("stale_agent", channel_info: { platform: "weixin", chat_id: "chat_1", user_id: "user_1" })
    end
    let(:stale_session) { { agent: stale_agent, channel_keys: Set.new } }

    before do
      allow(stale_agent).to receive(:channel_info=)
      rows = [
        { id: session_id, source: "channel" },
        { id: stale_id, source: "channel",
          channel_info: { platform: "weixin", chat_id: "chat_1", user_id: "user_1" } }
      ]
      allow(registry).to receive(:list).and_return(rows)
      allow(registry).to receive(:list).with(limit: nil).and_return(rows)
      allow(registry).to receive(:with_session).with(stale_id).and_yield(stale_session)
    end

    it "clears the stale channel_info that would otherwise reclaim the key on restart" do
      expect(stale_agent).to receive(:channel_info=).with(nil)

      unbind

      expect(sent).to eq(["Unbound."])
      expect(persisted).to include(stale_agent)
    end
  end
end
