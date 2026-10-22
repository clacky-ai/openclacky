# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "clacky/server/channel"
require "clacky/server/session_registry"

RSpec.describe Clacky::Channel::ChannelManager, "archived channel sessions" do
  let(:temp_dir)        { Dir.mktmpdir("clacky_channel_archived_spec") }
  let(:session_manager) { Clacky::SessionManager.new(sessions_dir: temp_dir) }
  let(:info)            { { platform: "weixin", chat_id: "chat_1", user_id: "user_1" } }
  let(:event)           { { platform: :weixin, chat_id: "chat_1", user_id: "user_1" } }
  let(:key)             { "weixin:chat:chat_1" }
  let(:archived_id)     { "aaaaaaaa11111111" }

  let(:registry) do
    reg = nil
    restorer = lambda do |data|
      reg.create(session_id: data[:session_id])
      agent = double("agent", channel_info: data[:channel_info]).as_null_object
      reg.with_session(data[:session_id]) { |s| s[:agent] = agent }
    end
    reg = Clacky::Server::SessionRegistry.new(
      session_manager: session_manager, session_restorer: restorer, agent_config: Clacky::AgentConfig.new
    )
  end

  let(:manager) do
    described_class.new(
      session_registry: registry,
      session_builder: ->(**_kw) { raise "must not create a new session" },
      run_agent_task: ->(*) {},
      interrupt_session: ->(*) {},
      channel_config: double("channel_config"),
      binding_mode: :chat
    )
  end

  after { FileUtils.rm_rf(temp_dir) }

  def write_session(id:, updated_at:, archived_at: nil, channel_info: nil)
    data = { session_id: id, name: id, created_at: updated_at, updated_at: updated_at,
             source: "channel", channel_info: channel_info, messages: [] }
    data[:archived_at] = archived_at if archived_at
    File.write(File.join(temp_dir, session_manager.send(:generate_filename, id, updated_at)), JSON.generate(data))
  end

  before do
    write_session(id: archived_id, updated_at: "2026-01-01T00:00:00Z",
                  archived_at: "2026-01-02T00:00:00Z", channel_info: info)
  end

  it "routes to an archived session bound in memory" do
    registry.ensure(archived_id)
    registry.with_session(archived_id) { |s| s[:channel_keys] = Set.new([key]) }

    expect(manager.resolve_session(event)).to eq(archived_id)
  end

  it "routes to an archived session through its persisted channel_info" do
    expect(manager.resolve_session(event)).to eq(archived_id)
  end

  it "restores the binding of an archived session" do
    manager.restore_channel_bindings

    keys = nil
    registry.with_session(archived_id) { |s| keys = s[:channel_keys] }
    expect(keys).to include(key)
  end
end
