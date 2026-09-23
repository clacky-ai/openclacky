# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe "channel adapter progress capabilities" do
  it "keeps ordinary message editing separate from task-progress updates" do
    telegram = Clacky::Channel::Adapters::Telegram::Adapter.allocate
    discord = Clacky::Channel::Adapters::Discord::Adapter.allocate

    expect(telegram.supports_message_updates?).to be true
    expect(telegram.supports_progress_updates?).to be false
    expect(discord.supports_message_updates?).to be true
    expect(discord.supports_progress_updates?).to be false
  end

  it "opts Feishu into the task-progress lifecycle" do
    feishu = Clacky::Channel::Adapters::Feishu::Adapter.allocate

    expect(feishu.supports_progress_updates?).to be true
  end
end
