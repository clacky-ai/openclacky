# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Agent::ToolExecutor, "tool progress message" do
  let(:host) { Class.new { include Clacky::Agent::ToolExecutor }.new }

  around do |example|
    original_lang = Thread.current[:lang]
    example.run
  ensure
    Thread.current[:lang] = original_lang
  end

  def progress_message(tool_name)
    host.send(:build_tool_progress_message, tool_name)
  end

  it "speaks the locale of the current thread" do
    Thread.current[:lang] = "zh"

    expect(progress_message("terminal")).to eq("正在执行命令...")
    expect(progress_message("web_search")).to eq("正在联网搜索...")
  end

  it "serves English when the thread locale is English" do
    Thread.current[:lang] = "en"

    expect(progress_message("terminal")).to eq("Running command...")
    expect(progress_message("web_search")).to eq("Searching web...")
  end

  it "names the tool when no dedicated phrase exists" do
    Thread.current[:lang] = "zh"

    expect(progress_message("brand_new_tool")).to eq("正在执行 brand_new_tool...")
  end
end
