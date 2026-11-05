# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "clacky/server/http_server"
require "clacky/server/scheduler"
require "clacky/agent_config"

RSpec.describe Clacky::Server::HttpServer, "cron task titles" do
  FakeResponse = Struct.new(:status, :content_type, :body, :headers) do
    def initialize
      super
      self.headers = {}
    end

    def [](key)
      headers[key]
    end

    def []=(key, value)
      headers[key] = value
    end
  end

  let(:tmpdir) { Dir.mktmpdir("clacky_cron_title_spec") }
  let(:server) do
    described_class.new(
      host:           "127.0.0.1",
      port:           0,
      agent_config:   instance_double(Clacky::AgentConfig),
      client_factory: -> { double("client") },
      sessions_dir:   File.join(tmpdir, "sessions")
    )
  end
  let(:scheduler) do
    stub_const("Clacky::Server::Scheduler::SCHEDULES_FILE", File.join(tmpdir, "schedules.yml"))
    stub_const("Clacky::Server::Scheduler::TASKS_DIR", File.join(tmpdir, "tasks"))
    stub_const("Clacky::Server::Scheduler::RUNS_FILE", File.join(tmpdir, "runs.json"))
    Clacky::Server::Scheduler.new(
      session_registry: nil,
      session_builder:  ->(**) {},
      task_runner:      ->(*) {}
    )
  end

  before { server.instance_variable_set(:@scheduler, scheduler) }
  after { FileUtils.rm_rf(tmpdir) }

  def post(body)
    req = Struct.new(:body).new(JSON.generate(body))
    res = FakeResponse.new
    server.send(:api_create_cron_task, req, res)
    [res, JSON.parse(res.body)]
  end

  def patch(name, body)
    req = Struct.new(:body).new(JSON.generate(body))
    res = FakeResponse.new
    server.send(:api_update_cron_task, name, req, res)
    [res, JSON.parse(res.body)]
  end

  def plan(name)
    scheduler.list_cron_tasks.find { |p| p["name"] == name }
  end

  it "stores an ordinary task's display title next to its ASCII name" do
    res, = post(
      "name"    => "daily_report",
      "title"   => "每日报表",
      "content" => "Write the report",
      "cron"    => "0 9 * * *"
    )

    expect(res.status).to eq(201)
    expect(plan("daily_report")).to include("name" => "daily_report", "title" => "每日报表")
    expect(scheduler.schedules.first["title"]).to eq("每日报表")
  end

  it "leaves the title empty when it is omitted" do
    post("name" => "daily_report", "content" => "Write the report", "cron" => "0 9 * * *")

    expect(plan("daily_report")["title"]).to be_nil
  end

  it "updates and clears the title through PATCH" do
    post("name" => "daily_report", "title" => "每日报表", "content" => "Write the report", "cron" => "0 9 * * *")

    patch("daily_report", "title" => "工作日报")
    expect(plan("daily_report")["title"]).to eq("工作日报")

    patch("daily_report", "title" => "")
    expect(plan("daily_report")["title"]).to be_nil
  end

  it "does not reset the title when PATCH omits it" do
    post("name" => "daily_report", "title" => "每日报表", "content" => "Write the report", "cron" => "0 9 * * *")

    patch("daily_report", "content" => "Updated report")
    expect(plan("daily_report")).to include("title" => "每日报表", "content" => "Updated report")
  end

  it "labels a manually triggered run with the display title" do
    post("name" => "daily_report", "title" => "每日报表", "content" => "Write the report", "cron" => "0 9 * * *")

    captured = {}
    registry = double("registry", update: nil, session_summary: { id: "s1" })
    server.instance_variable_set(:@registry, registry)
    allow(server).to receive(:build_session) { |**kw| captured[:name] = kw[:name]; "s1" }
    allow(server).to receive(:broadcast_session_update)
    allow(Time).to receive(:now).and_return(Time.parse("2026-11-05T09:00:00"))

    res = FakeResponse.new
    server.send(:api_run_cron_task, "daily_report", res)

    expect(res.status).to eq(202)
    expect(captured[:name]).to eq("▶ 每日报表 09:00")
  end

  it "falls back to the plan name when a manually triggered run has no title" do
    post("name" => "daily_report", "content" => "Write the report", "cron" => "0 9 * * *")

    captured = {}
    registry = double("registry", update: nil, session_summary: { id: "s1" })
    server.instance_variable_set(:@registry, registry)
    allow(server).to receive(:build_session) { |**kw| captured[:name] = kw[:name]; "s1" }
    allow(server).to receive(:broadcast_session_update)
    allow(Time).to receive(:now).and_return(Time.parse("2026-11-05T09:00:00"))

    res = FakeResponse.new
    server.send(:api_run_cron_task, "daily_report", res)

    expect(res.status).to eq(202)
    expect(captured[:name]).to eq("▶ daily_report 09:00")
  end
end
