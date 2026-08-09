# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"

RSpec.describe Clacky::HookManager, "agent argument" do
  let(:agent) { double("Agent") }
  let(:manager) { described_class.new(agent: agent) }
  let(:call) { { id: "call_1", name: "write", arguments: { "path" => "a.txt" } } }

  it "passes the owning agent as the trailing argument" do
    seen = nil
    manager.add(:before_tool_use) { |_call, hook_agent| seen = hook_agent }

    manager.trigger(:before_tool_use, call)

    expect(seen).to be(agent)
  end

  it "appends the agent after every positional arg the event already carries" do
    seen = nil
    manager.add(:after_tool_use) { |_call, _result, hook_agent| seen = hook_agent }

    manager.trigger(:after_tool_use, call, { ok: true })

    expect(seen).to be(agent)
  end

  it "leaves hooks that declare fewer params untouched" do
    seen = nil
    manager.add(:after_tool_use) { |c, result| seen = [c, result] }

    expect { manager.trigger(:after_tool_use, call, { ok: true }) }.not_to raise_error
    expect(seen).to eq([call, { ok: true }])
  end

  it "yields nil when no agent owns the chain" do
    seen = :unset
    orphan = described_class.new
    orphan.add(:on_iteration) { |_n, hook_agent| seen = hook_agent }

    orphan.trigger(:on_iteration, 3)

    expect(seen).to be_nil
  end

  it "lets an ext hook emit a custom event through the agent it receives" do
    emitted = []
    allow(agent).to receive(:emit_event) { |type, **data| emitted << [type, data] }

    manager.add(:after_tool_use) do |c, _result, hook_agent|
      hook_agent&.emit_event("ext.demo.tool_done", tool: c[:name], persist: true)
      { action: :allow }
    end
    manager.trigger(:after_tool_use, call, { ok: true })

    expect(emitted).to eq([["ext.demo.tool_done", { tool: "write", persist: true }]])
  end

  it "keeps the agent out of the JSON payload handed to shell hooks" do
    tmp = Dir.mktmpdir
    captured = File.join(tmp, "payload.json")
    script = File.join(tmp, "hook.sh")
    File.write(script, "#!/usr/bin/env bash\ncat > #{captured}\n")
    FileUtils.chmod("+x", script)
    yml = File.join(tmp, "hooks.yml")
    File.write(yml, { "hooks" => { "after_tool_use" => [{ "name" => "cap", "command" => script }] } }.to_yaml)

    Clacky::ShellHookLoader.load_into(manager, path: yml)
    manager.trigger(:after_tool_use, call, { ok: true })

    payload = JSON.parse(File.read(captured))
    expect(payload["tool"]["name"]).to eq("write")
    expect(payload.to_s).not_to include("Agent")
  ensure
    FileUtils.rm_rf(tmp)
  end
end
