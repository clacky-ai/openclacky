# frozen_string_literal: true
require "spec_helper"
require "open3"
require "clacky/utils/resource_group"

RSpec.describe Clacky::Utils::ResourceGroup do
  around do |example|
    Dir.mktmpdir("resource group ") do |dir|
      @dir = dir
      ClimateControl.modify(CLACKY_TASK_CGROUP: nil) { example.run }
    end
  end

  def group
    File.write(File.join(@dir, "memory.events.local"), "oom_kill 0\n")
    described_class.new(@dir)
  end

  it "does not change ordinary desktop execution" do
    expect(described_class.create("terminal")).to be_nil
  end

  it "fails instead of bypassing protection for an invalid configured group" do
    ClimateControl.modify(CLACKY_TASK_CGROUP: @dir) do
      expect { described_class.create("terminal") }.to raise_error(Errno::ENOENT)
    end
  end

  it "reports new OOM events once even if the command itself exits successfully" do
    g = group
    File.write(File.join(@dir, "memory.events.local"), "oom_kill 2\n")
    expect(g.consume_oom_error).to include("memory limit")
    expect(g.consume_oom_error).to be_nil
    File.write(File.join(@dir, "memory.events.local"), "oom_kill 3\n")
    expect(g.consume_oom_error).to include("memory limit")
  end

  it "joins before exec and preserves argv without shell interpolation" do
    g = group
    value = 'spaces; $(false) "quoted"'
    output, status = Open3.capture2(*g.wrap(["/usr/bin/printf", "%s", value]))
    expect(status).to be_success
    expect(output).to eq(value)
    expect(File.read(File.join(@dir, "cgroup.procs")).to_i).to be_positive
  end

  it "does not run the command when joining the group fails" do
    g = group
    Dir.mkdir(File.join(@dir, "cgroup.procs"))
    output, _error, status = Open3.capture3(*g.wrap(["/bin/echo", "unprotected"]))
    expect(status.exitstatus).to eq(125)
    expect(output).to eq("")
  end
end
