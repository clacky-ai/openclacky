# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe "Secretary recurring work" do
  include HttpServerSpecHelpers
  let(:dir) { Dir.mktmpdir }
  let(:config) do
    Clacky::AgentConfig.new(memory_update_enabled: false, skill_evolution: { enabled: false }, models: [
      { "model" => "test-model", "api_key" => "test-key", "base_url" => "https://example.invalid", "type" => "default" }
    ])
  end
  before do
    stub_const("Clacky::Server::Scheduler::SCHEDULES_FILE", File.join(dir, "schedules.yml"))
    stub_const("Clacky::Server::Scheduler::TASKS_DIR", File.join(dir, "tasks"))
    stub_const("Clacky::Server::Scheduler::RUNS_FILE", File.join(dir, "runs.json"))
    allow(Clacky::Server::BackupManager).to receive(:config).and_return({ "enabled" => false })
    allow(Time).to receive(:now).and_return(Time.parse("2026-11-04T00:00:00"))
  end
  after { FileUtils.rm_rf(dir) }

  def setup_server
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(dir)
      registry = server.instance_variable_get(:@registry)
      sid = server.send(:build_session, name: "Secretary", profile: "secretary")
      owner = registry.get(sid)[:agent]
      yield server, registry, owner, server.instance_variable_get(:@scheduler)
    end
  end

  def request(server, method, path, body = nil)
    res = fake_res
    server.send(:dispatch, fake_req(method: method, path: path, body: body), res)
    res
  end

  def create(server, owner)
    res = request(server, "POST", "/api/cron-tasks", {
      name: "morning_report", title: "Morning report", owner_session_id: owner.session_id,
      content: "Summarize work progress in English; identify blocked items.", cron: "0 9 * * *"
    })
    expect(res.status).to eq(201), res.body
    server.work_service.schedules(owner.session_id).first
  end

  it "creates a real worker through cron and delivers its report through the existing result path" do
    setup_server do |server, registry, owner, scheduler|
      expect(owner.tool_registry.tool_names).to include("invoke_skill", "terminal")
      plan = create(server, owner)
      listed = request(server, "GET", "/api/cron-tasks")
      expect(parsed_body(listed)["cron_tasks"].first["target"]["owner_session_id"]).to eq(owner.session_id)
      expect(server.work_service.protected_session_ids).to include(owner.session_id)
      scheduler.send(:tick, Time.parse("2026-11-04T09:05:00"))
      card = server.work_service.list(owner.session_id).first
      expect(card).to include("status" => "queued", "schedule_name" => plan["name"], "scheduled_at" => Time.parse("2026-11-04T09:00:00").utc.iso8601)
      expect(card["instruction"]).to include("Current work summary", "Summarize work progress")
      worker = registry.get(card["session_id"])[:agent]
      allow(worker).to receive(:think) do
        calls = [{ id: "report", name: "yield_work", arguments: JSON.generate(reason: "completed", summary: "Today's report is ready.") }]
        worker.history.append(role: "assistant", content: nil, tool_calls: calls)
        { content: nil, tool_calls: calls }
      end
      allow(owner).to receive(:think) do
        owner.history.append(role: "assistant", content: "Here is your morning report.")
        { content: "Here is your morning report.", tool_calls: [] }
      end
      allow(owner).to receive(:run_skill_evolution_hooks)
      allow(owner).to receive(:run_memory_update_subagent)
      server.work_service.tick
      expect(registry.get(card["session_id"])[:thread].join(5)).not_to be_nil
      server.work_service.tick
      expect(registry.get(owner.session_id)[:thread].join(5)).not_to be_nil
      finished = server.work_service.list(owner.session_id).first
      expect(finished["status"]).to eq("completed")
      expect(finished["outbox"].first["state"]).to eq("delivered")
      expect(owner.history.to_a).to include(hash_including(content: "Here is your morning report."))
      scheduler.send(:tick, Time.parse("2026-11-05T09:05:00"))
      cards = server.work_service.list(owner.session_id)
      expect(cards.size).to eq(2)
      expect(cards.map { |c| c["session_id"] }.uniq.size).to eq(2)
    end
  end

  it "keeps a legacy ordinary plan ordinary when edited from a secretary conversation" do
    setup_server do |server, registry, owner, scheduler|
      scheduler.write_task("legacy_report", "Original ordinary instructions")
      File.write(Clacky::Server::Scheduler::SCHEDULES_FILE, YAML.dump([
        { "name" => "legacy_report", "task" => "legacy_report", "cron" => "0 9 * * *", "enabled" => true }
      ]))
      res = request(server, "PATCH", "/api/cron-tasks/legacy_report", {
        cron: "0 18 * * *", owner_session_id: owner.session_id
      })
      expect(res.status).to eq(200), res.body
      saved = scheduler.schedules.first
      expect(saved["target"]).to be_nil
      expect(scheduler.read_task("legacy_report")).to eq("Original ordinary instructions")
      built = []
      builder = scheduler.instance_variable_get(:@session_builder)
      scheduler.instance_variable_set(:@session_builder, lambda do |**args|
        sid = builder.call(**args)
        built << sid
        agent = registry.get(sid)[:agent]
        expect(agent.agent_profile.name).to eq("general")
        allow(agent).to receive(:think) do
          agent.history.append(role: "assistant", content: "Ordinary report ready.")
          { content: "Ordinary report ready.", tool_calls: [] }
        end
        allow(agent).to receive(:run_skill_evolution_hooks)
        allow(agent).to receive(:run_memory_update_subagent)
        sid
      end)
      scheduler.send(:tick, Time.parse("2026-11-04T18:05:00"))
      expect(built.size).to eq(1)
      expect(registry.get(built.first)[:thread].join(5)).not_to be_nil
      expect(scheduler.list_runs(task: "legacy_report").first).to include("status" => "success", "session_id" => built.first)
      stored = server.instance_variable_get(:@session_manager).load(built.first)
      expect(stored.to_json).to include("Original ordinary instructions", "Ordinary report ready.")
      expect(server.work_service.list(owner.session_id)).to be_empty
      expect(owner.history.to_a).not_to include(hash_including(content: "Ordinary report ready."))
      scheduler.send(:tick, Time.parse("2026-11-04T18:06:00"))
      expect(built.size).to eq(1)
    end
  end

  it "returns a busy response for a later manual secretary run without creating a fallback session" do
    setup_server do |server, registry, owner, scheduler|
      plan = create(server, owner)
      first = request(server, "POST", "/api/cron-tasks/#{plan['name']}/run")
      expect(first.status).to eq(202)
      allow(Time).to receive(:now).and_return(Time.parse("2026-11-04T00:01:00"))
      expect(server).not_to receive(:build_session)
      second = request(server, "POST", "/api/cron-tasks/#{plan['name']}/run")
      expect(second.status).to eq(409)
      expect(server.work_service.list(owner.session_id).size).to eq(1)
      expect(scheduler.schedules.first["target"]["owner_session_id"]).to eq(owner.session_id)
    end
  end

  it "deduplicates a durable card if saving the schedule cursor fails" do
    setup_server do |server, registry, owner, scheduler|
      create(server, owner)
      allow(scheduler).to receive(:save_schedules).and_raise(IOError, "disk unavailable")
      scheduler.send(:tick, Time.parse("2026-11-04T09:05:00"))
      expect(server.work_service.list(owner.session_id).size).to eq(1)
      allow(scheduler).to receive(:save_schedules).and_call_original
      scheduler.send(:tick, Time.parse("2026-11-04T09:06:00"))
      expect(server.work_service.list(owner.session_id).size).to eq(1)
      expect(scheduler.schedules.first["next_run_at"]).to eq(Time.parse("2026-11-05T09:00:00").utc.iso8601)
    end
  end

  it "waits for unfinished work and catches up only the latest report when it is resolved" do
    setup_server do |server, registry, owner, scheduler|
      create(server, owner)
      scheduler.send(:tick, Time.parse("2026-11-04T09:05:00"))
      first = server.work_service.list(owner.session_id).first
      scheduler.send(:tick, Time.parse("2026-11-07T09:05:00"))
      expect(server.work_service.list(owner.session_id).size).to eq(1)
      server.work_service.manage(owner.session_id, action: "cancel", work_id: first["id"])
      scheduler.send(:tick, Time.parse("2026-11-07T09:06:00"))
      expect(server.work_service.list(owner.session_id).map { |c| c["scheduled_at"] }).to contain_exactly(Time.parse("2026-11-04T09:00:00").utc.iso8601, Time.parse("2026-11-07T09:00:00").utc.iso8601)
    end
  end

  it "uses existing PATCH/DELETE endpoints and preserves the owner without cancelling created work" do
    setup_server do |server, registry, owner, scheduler|
      plan = create(server, owner)
      other_id = server.send(:build_session, name: "Other", profile: "secretary")
      expect(server.work_service.schedules(other_id)).to eq([])
      scheduler.send(:tick, Time.parse("2026-11-04T09:05:00"))
      res = request(server, "PATCH", "/api/cron-tasks/#{plan['name']}", {
        enabled: false, content: "Updated report scope", owner_session_id: other_id
      })
      expect(res.status).to eq(200)
      scheduler.send(:tick, Time.parse("2026-11-05T09:05:00"))
      expect(server.work_service.list(owner.session_id).size).to eq(1)
      stored = server.work_service.schedules(owner.session_id).first
      expect(stored).to include("enabled" => false, "content" => "Updated report scope")
      expect(stored["target"]).to eq(plan["target"])
      res = request(server, "DELETE", "/api/cron-tasks/#{plan['name']}")
      expect(res.status).to eq(200)
      expect(server.work_service.schedules(owner.session_id)).to eq([])
      expect(server.work_service.list(owner.session_id).first["status"]).to eq("queued")
    end
  end

  it "validates secretary ownership and keeps ordinary cron creation compatible" do
    setup_server do |server, registry, owner, scheduler|
      body = { name: "test", content: "Report", cron: "0 9 * * *" }
      general_id = server.send(:build_session, name: "General", profile: "general")
      ["missing", "", general_id].each do |sid|
        res = request(server, "POST", "/api/cron-tasks", body.merge(owner_session_id: sid))
        expect(res.status).to eq(422), res.body
      end
      expect(scheduler.list_tasks).to eq([])
      res = request(server, "POST", "/api/cron-tasks", body)
      expect(res.status).to eq(201)
      expect(scheduler.schedules.first["target"]).to be_nil
    end
  end

  it "rejects duplicate creates so they cannot erase or reassign a secretary target" do
    setup_server do |server, registry, owner, scheduler|
      plan = create(server, owner)
      other_id = server.send(:build_session, name: "Other", profile: "secretary")
      body = { name: plan["name"], content: "Replace", cron: "0 20 * * *" }
      [body, body.merge(owner_session_id: other_id)].each do |payload|
        res = request(server, "POST", "/api/cron-tasks", payload)
        expect(res.status).to eq(422)
      end
      expect(server.work_service.schedules(owner.session_id).first).to eq(plan)
    end
  end

  it "routes the existing run-now API to secretary work instead of an ordinary agent" do
    setup_server do |server, registry, owner, scheduler|
      plan = create(server, owner)
      res = fake_res
      server.send(:api_run_cron_task, plan["name"], res)
      expect(res.status).to eq(202)
      card = server.work_service.list(owner.session_id).first
      expect(registry.get(card["session_id"])[:agent].agent_profile.name).to eq("secretary-worker")
      server.send(:api_run_cron_task, plan["name"], res)
      # Identical timestamp is an idempotent retry, not a duplicate work item.
      expect(server.work_service.list(owner.session_id).size).to eq(1)
      expect(scheduler.schedules.first["next_run_at"]).to eq(Time.parse("2026-11-04T09:00:00").utc.iso8601)
    end
  end
end
