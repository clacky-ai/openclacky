# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Assistant output goes through Utils::FileLinkNormalizer on the live path
# (agent.rb emit_assistant_message). Replay has to apply the same rewrite,
# otherwise bare absolute paths saved by the model come back after a refresh
# as dead links (C-5879).
RSpec.describe "replay_history file link normalization" do
  let(:created_at) { "2026-03-08T10:00:00+08:00" }

  let(:ui) do
    Class.new do
      attr_reader :assistant_messages

      def initialize
        @assistant_messages = []
      end

      def show_assistant_message(content, **_kwargs)
        @assistant_messages << content
      end

      def method_missing(_name, *_args, **_kwargs); end

      def respond_to_missing?(_name, _include_private = false)
        true
      end
    end.new
  end

  # SessionSerializer is included by 15 specs on bare anonymous classes, so it
  # cannot reach into Agent's private helpers. It must work through Utils.
  let(:host_class) do
    Class.new do
      include Clacky::Agent::SessionSerializer

      attr_accessor :history

      def initialize(history)
        @history = history
      end
    end
  end

  def with_tmp_file(name)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, "x")
      yield path
    end
  end

  it "rewrites a bare absolute path on replay the same way the live path does" do
    with_tmp_file("report.pdf") do |path|
      host = host_class.new(Clacky::MessageHistory.new([
        { role: "system", content: "sys" },
        { role: "user", content: "show me", created_at: created_at },
        { role: "assistant", content: "[report](#{path})", created_at: created_at }
      ]))

      host.replay_history(ui)

      expect(ui.assistant_messages).to include("[report](file://#{path})")
    end
  end

  it "rewrites a hosted-platform project ref on replay" do
    with_tmp_file("report.pdf") do |path|
      token = Base64.urlsafe_encode64("cch1:file://#{path}", padding: false)
      host = host_class.new(Clacky::MessageHistory.new([
        { role: "system", content: "sys" },
        { role: "user", content: "show me", created_at: created_at },
        { role: "assistant", content: "[report](/workspace/projects/#{token})", created_at: created_at }
      ]))

      host.replay_history(ui)

      expect(ui.assistant_messages).to include("[report](file://#{path})")
    end
  end

  it "leaves a site route untouched on replay" do
    host = host_class.new(Clacky::MessageHistory.new([
      { role: "system", content: "sys" },
      { role: "user", content: "docs?", created_at: created_at },
      { role: "assistant", content: "[docs](/docs/getting-started)", created_at: created_at }
    ]))

    host.replay_history(ui)

    expect(ui.assistant_messages).to include("[docs](/docs/getting-started)")
  end
end
