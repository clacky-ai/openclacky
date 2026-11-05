# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::ChannelManager, "channel session naming" do
  let(:existing_names) { [] }
  let(:created_names)  { [] }

  let(:registry) do
    rows = existing_names.map { |name| { id: "existing-#{name}", name: name } }
    double("registry").tap do |r|
      allow(r).to receive(:list).with(archived: nil).and_return(rows)
      allow(r).to receive(:with_session) { |_sid, &blk| blk.call({}) }
    end
  end

  let(:channel_config) do
    double("channel_config",
           status_messages_enabled?: false,
           process_messages_enabled?: false,
           progress_cards_enabled?: false)
  end

  let(:manager) do
    names = created_names
    described_class.new(
      session_registry:  registry,
      session_builder:   ->(name:, source:) { names << name; "sess-#{names.length}" },
      run_agent_task:    ->(*) {},
      interrupt_session: ->(*) {},
      channel_config:    channel_config
    )
  end

  let(:adapter) { double("adapter", platform_id: :weixin, instance_id: "default") }
  let(:event) do
    { platform: :weixin, channel_instance_id: "default", chat_id: "chat-1", user_id: "user-1", text: "hi", files: [] }
  end

  def create_session
    manager.send(:auto_create_session, adapter, event)
  end

  it "starts numbering at 1 when no channel session exists" do
    create_session

    expect(created_names).to eq(["weixin-1"])
  end

  it "resumes numbering from existing sessions after a restart" do
    existing_names.replace(%w[weixin-1 weixin-2])

    create_session

    expect(created_names).to eq(["weixin-3"])
  end

  it "ignores other platforms and non-numeric suffixes" do
    existing_names.replace(["feishu-4", "weixin-backup", "weixin-1"])

    create_session

    expect(created_names).to eq(["weixin-2"])
  end

  it "keeps incrementing within a single process" do
    create_session
    create_session

    expect(created_names).to eq(["weixin-1", "weixin-2"])
  end
end
