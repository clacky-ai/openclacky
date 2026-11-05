# frozen_string_literal: true
require "spec_helper"
require "clacky/server/scheduler"

RSpec.describe "Scheduler resume behavior" do
  let(:dir) { Dir.mktmpdir }
  let(:delivered) { [] }
  let(:handler) { ->(plan, prompt, due) { delivered << [plan, prompt, due]; true } }
  def scheduler
    Clacky::Server::Scheduler.new(session_registry: nil, session_builder: ->(**) {}, task_runner: ->(*) {}, scheduled_dispatcher: handler)
  end
  before do
    stub_const("Clacky::Server::Scheduler::SCHEDULES_FILE", File.join(dir, "schedules.yml"))
    stub_const("Clacky::Server::Scheduler::TASKS_DIR", File.join(dir, "tasks"))
    stub_const("Clacky::Server::Scheduler::RUNS_FILE", File.join(dir, "runs.json"))
    allow(Clacky::Server::BackupManager).to receive(:config).and_return({ "enabled" => false })
    allow(Time).to receive(:now).and_return(Time.parse("2026-11-04T00:00:00"))
  end
  after { FileUtils.rm_rf(dir) }

  def create(s)
    s.create_cron_task(name: "morning", content: "Report", cron: "0 9 * * *", target: { "type" => "test" })
  end

  it "catches up only the latest occurrence after process recreation and does not repeat it" do
    create(scheduler)
    restored = scheduler
    restored.send(:tick, Time.parse("2026-11-07T10:00:00"))
    expect(delivered.size).to eq(1)
    expect(delivered.first.last).to eq(Time.parse("2026-11-07T09:00:00"))
    scheduler.send(:tick, Time.parse("2026-11-07T10:01:00"))
    expect(delivered.size).to eq(1)
    expect(scheduler.schedules.first["next_run_at"]).to eq(Time.parse("2026-11-08T09:00:00").utc.iso8601)
  end

  it "initializes legacy plans at the current minute and persists deduplication across restart" do
    s = scheduler
    s.write_task("legacy", "Old task")
    File.write(Clacky::Server::Scheduler::SCHEDULES_FILE, YAML.dump([
      { "name" => "legacy", "task" => "legacy", "cron" => "* * * * *", "enabled" => true }
    ]))
    allow(s).to receive(:fire_task).and_return(true)
    s.send(:tick, Time.parse("2026-11-04T09:00:20"))
    expect(s).to have_received(:fire_task).once
    restored = scheduler
    expect(restored).not_to receive(:fire_task)
    restored.send(:tick, Time.parse("2026-11-04T09:00:50"))
    expect(restored.schedules.first["next_run_at"]).to eq(Time.parse("2026-11-04T09:01:00").utc.iso8601)
  end

  it "retains the due occurrence until a busy destination accepts it" do
    s = scheduler
    create(s)
    allow(handler).to receive(:call).and_return(nil, true)
    s.send(:tick, Time.parse("2026-11-04T10:00:00"))
    expect(s.schedules.first["next_run_at"]).to eq(Time.parse("2026-11-04T09:00:00").utc.iso8601)
    s.send(:tick, Time.parse("2026-11-04T10:01:00"))
    expect(s.schedules.first["next_run_at"]).to eq(Time.parse("2026-11-05T09:00:00").utc.iso8601)
  end

  it "resets the deadline on re-enable and does not backfill disabled periods" do
    s = scheduler
    create(s)
    s.update_cron_task("morning", enabled: false)
    s.send(:tick, Time.parse("2026-11-07T10:00:00"))
    expect(delivered).to be_empty
    allow(Time).to receive(:now).and_return(Time.parse("2026-11-07T10:00:00"))
    s.update_cron_task("morning", enabled: true)
    s.send(:tick, Time.now)
    expect(delivered).to be_empty
    expect(s.schedules.first["next_run_at"]).to eq(Time.parse("2026-11-08T09:00:00").utc.iso8601)
  end

  it "changes time without losing the target" do
    s = scheduler
    create(s)
    s.update_cron_task("morning", cron: "0 20 * * *")
    expect(s.schedules.first).to include("next_run_at" => Time.parse("2026-11-04T20:00:00").utc.iso8601, "target" => { "type" => "test" })
  end

  it "persists a display title separately from the ASCII plan name" do
    s = scheduler
    s.create_cron_task(name: "morning", content: "Report", cron: "0 9 * * *", title: "早间汇报")

    plan = s.list_cron_tasks.find { |p| p["name"] == "morning" }
    expect(plan["title"]).to eq("早间汇报")
    expect(s.schedules.first["title"]).to eq("早间汇报")
    expect(s.task_file_path("morning")).to end_with("morning.md")
  end

  it "exposes no title when the plan has none" do
    s = scheduler
    create(s)
    expect(s.list_cron_tasks.first["title"]).to be_nil
  end

  it "updates and clears a title without touching the name" do
    s = scheduler
    create(s)
    s.update_cron_task("morning", title: "上午汇报")
    expect(s.list_cron_tasks.first["title"]).to eq("上午汇报")

    s.update_cron_task("morning", title: "")
    expect(s.list_cron_tasks.first["title"]).to be_nil
    expect(s.list_tasks).to eq(["morning"])
  end

  it "keeps a secretary plan's target title in sync" do
    s = scheduler
    s.create_cron_task(name: "morning", content: "Report", cron: "0 9 * * *",
                       target: { "type" => "secretary_work", "title" => "早间汇报" })
    s.update_cron_task("morning", title: "每日早报")

    expect(s.schedules.first["target"]["title"]).to eq("每日早报")
  end

  it "accepts a legacy secretary target title as the display label" do
    s = scheduler
    s.write_task("legacy", "Report")
    File.write(Clacky::Server::Scheduler::SCHEDULES_FILE, YAML.dump([
      { "name" => "legacy", "task" => "legacy", "cron" => "0 9 * * *", "enabled" => true,
        "target" => { "type" => "secretary_work", "title" => "旧计划" } }
    ]))

    expect(s.list_cron_tasks.first["title"]).to eq("旧计划")
  end

  it "rejects invalid times before changing files" do
    s = scheduler
    create(s)
    expect { s.update_cron_task("morning", content: "bad", cron: "0 99 * * *") }.to raise_error(ArgumentError)
    expect(s.read_task("morning")).to eq("Report")
    expect(s.list_tasks).to eq(["morning"])
  end

end
