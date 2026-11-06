# frozen_string_literal: true
require "spec_helper"
require "clacky/work/service"

RSpec.describe Clacky::Work::Service do
  around do |example|
    previous = Thread.current[:lang]
    Thread.current[:lang] = "en"
    example.run
  ensure
    Thread.current[:lang] = previous
  end

  let(:dir) { Dir.mktmpdir }
  let(:store) { Clacky::Work::Store.new(File.join(dir, "work.json")) }
  let(:registry) { double("registry") }
  let(:owner) { double("owner", session_id: "owner", ui: nil, agent_profile: double(name: "secretary", work_agent: "secretary-worker"), working_dir: dir, history: double(to_a: [{ role: "user", content: "最好周四，别订太贵的地方" }])) }
  let(:worker) { double("worker", session_id: "worker", ui: nil, agent_profile: double(name: "secretary-worker", work_agent: "")) }
  let(:runner) { double("runner") }
  let(:interrupt) { double("interrupt", call: nil) }
  let(:persist) { double("persist", call: nil) }
  let(:published) { [] }
  let(:service) do
    described_class.new(store: store, registry: registry, build_session: ->(**) { "worker" },
                        submit_task: runner, interrupt: interrupt, persist: persist,
                        publish: ->(sid, type) { published << [sid, type] })
  end
  let(:card) { service.delegate(owner, title: "约饭", task: "询问时间", constraints: "不预订") }
  after { Thread.current[:clacky_work] = nil; FileUtils.rm_rf(dir) }

  before do
    allow(owner.agent_profile).to receive(:based_on?) { |id| id == "secretary" }
    allow(worker.agent_profile).to receive(:based_on?) { |id| id == "secretary-worker" }
  end

  def running
    c = card
    store.transaction { |d| d["cards"][c["id"]]["status"] = "running" }
    Thread.current[:clacky_work] = { id: c["id"], revision: c["revision"] }
    c
  end

  def current
    service.list("owner").first
  end

  def idle_registry
    allow(registry).to receive(:ensure).and_return(true)
    allow(registry).to receive(:get).with("worker").and_return({ agent: worker, status: :idle })
    allow(registry).to receive(:get).with("owner").and_return({ agent: owner, status: :idle })
    allow(registry).to receive(:running_full?).and_return(false)
    allow(registry).to receive(:max_running_agents).and_return(3)
    allow(registry).to receive(:count_by_status).with(:running).and_return(0)
  end

  it "retains the delegation locale for background messages after the request ends" do
    Thread.current[:lang] = "zh"
    c = card
    expect(c["locale"]).to eq("zh")
    expect(c["progress"]).to eq("等待执行")
    Thread.current[:lang] = "en"
    expect(service.send(:notification_label, c, { "kind" => "completed" })).to eq("工作已完成：约饭")
    expect(service.send(:notification_label, c.merge("locale" => "en"), { "kind" => "needs_input" })).to eq("Your decision needed: 约饭")
    expect(service.send(:notification_label, c.merge("locale" => nil), { "kind" => "completed" })).to eq("Work completed: 约饭")
  end

  it "captures original user messages and queues without executing inline" do
    expect(runner).not_to receive(:call)
    expect(card).to include("status" => "queued", "revision" => 1)
    expect(card["source_messages"].first["content"]).to eq("最好周四，别订太贵的地方")
    expect(service.protected_session_ids).to contain_exactly("owner", "worker")
  end

  it "does not capture work reports as user authorization when delegating again" do
    allow(owner.history).to receive(:to_a).and_return([
      { role: "user", content: "Actual user request", message_id: "user-1" },
      { role: "user", content: "Worker report", display_text: "Work completed", message_id: "report-1" }
    ])
    expect(card["source_messages"].map { |m| m["content"] }).to eq(["Actual user request"])
  end

  it "isolates management by owner" do
    expect { service.manage("other", action: "cancel", work_id: card["id"]) }.to raise_error(/not found/)
    expect(service.list("other")).to eq([])
  end

  it "rejects edits based on stale revisions without changing the card" do
    expect { service.manage("owner", action: "update", work_id: card["id"], instruction: "周五", expected_revision: 0) }.to raise_error(/changed/)
    expect(current["revision"]).to eq(1)
  end

  it "fences old tool calls and old yields when requirements change" do
    c = running
    service.manage("owner", action: "update", work_id: c["id"], instruction: "周四不行了")
    expect { service.guard!(worker) }.to raise_error(/updated/)
    expect { service.yield_work(worker, reason: "completed", summary: "周四约好了") }.to raise_error(/updated/)
    expect(current).to include("revision" => 2, "status" => "queued")
  end

  it "fences cancelled work regardless of the worker profile name" do
    allow(worker.agent_profile).to receive(:name).and_return("third-party-worker")
    idle_registry
    c = running
    expect { service.guard!(worker) }.not_to raise_error
    service.manage("owner", action: "cancel", work_id: c["id"])
    expect { service.guard!(worker) }.to raise_error(Clacky::AgentInterrupted)
  end

  it "commits completion and outbox in the same document" do
    running
    result = service.yield_work(worker, reason: "completed", summary: "已整理方案，来源：example.com")
    expect(result[:work_yielded]).to be(true)
    expect(current["status"]).to eq("completed")
    expect(current["outbox"].first).to include("kind" => "completed", "state" => "pending")
    expect { service.guard!(worker) }.to raise_error(/yielded/)
  end

  %w[reply update].each do |action|
    it "continues completed work through #{action} without creating another session" do
      c = running
      service.yield_work(worker, reason: "completed", summary: "First draft")
      result = service.manage("owner", action: action, work_id: c["id"], instruction: "Make it shorter")
      expect(result).to include("id" => c["id"], "session_id" => "worker", "status" => "queued", "revision" => 2)
      expect(result["outbox"].first["state"]).to eq("superseded")
      expect { service.guard!(worker) }.to raise_error(Clacky::AgentInterrupted)
    end
  end

  %w[completed needs_input waiting_event paused failed].each do |status|
    it "keeps #{status} intact after a normal direct reply without notifying the owner" do
      c = card
      store.transaction do |data|
        live = data["cards"][c["id"]]
        live["status"] = status
        live["progress"] = "Existing outcome"
        live["display_summary"] = "Existing summary"
        live["waiting"] = { "reply_to" => "mail-1", "channel" => "mail", "conversation_id" => "inbox" } if status == "waiting_event"
      end
      before = current
      hooks = {}
      allow(worker).to receive(:work_service=)
      allow(worker).to receive(:add_hook) { |event, &callback| hooks[event] = callback }
      service.attach(worker)
      hooks[:on_start].call("Why this option?", worker)
      expect(service.turn_context(worker)).to be_nil
      hooks[:on_complete].call({ status: :success }, worker)
      expect(Thread.current[:clacky_work]).to be_nil
      expect(current.slice("status", "progress", "display_summary", "waiting")).to eq(before.slice("status", "progress", "display_summary", "waiting"))
      expect(current["outbox"]).to be_empty
      expect(current["pending_inputs"]).to be_empty
    end
  end

  it "still reports failure when background execution omits its outcome" do
    card
    idle_registry
    allow(runner).to receive(:call) do |_sid, _prompt, **_options, &block|
      block.call(-> { { status: :success } }, worker)
      :thread
    end
    service.tick
    expect(current["status"]).to eq("failed")
    expect(current["outbox"].last["kind"]).to eq("failed")
  end

  it "rejects direct messages to cancelled work without executing" do
    card
    idle_registry
    service.manage("owner", action: "cancel", work_id: card["id"])
    hooks = {}
    allow(worker).to receive(:work_service=)
    allow(worker).to receive(:add_hook) { |event, &callback| hooks[event] = callback }
    service.attach(worker)
    expect(hooks[:on_start].call("Continue", worker)).to include(action: :deny)
    expect(Thread.current[:clacky_work]).to be_nil
    expect(current["status"]).to eq("cancelled")
  end

  it "reports only this event, without replaying old instructions or prescribing actions" do
    c = card.merge("updates" => [{ "source" => "user", "text" => "Shorter please" }])
    prompt = service.send(:report_prompt, c, { "kind" => "needs_input", "text" => "Which date?", "at" => "2026-11-05T11:12:01Z", "revision" => 3 })
    expect(prompt).to include("约饭", "Which date?", "2026-11-05T11:12:01Z", "revision at event: 3")
    expect(prompt).not_to include("询问时间", "Shorter please", "Next step", "Latest feedback")
    expect(prompt).not_to include("work-event:")
  end

  it "reports a user stop without replaying an earlier continue instruction" do
    c = card.merge("updates" => [{ "source" => "user", "text" => "继续", "at" => "2026-11-05T11:09:29Z" }])
    event = { "kind" => "paused", "at" => "2026-11-05T11:12:01Z", "revision" => 3, "text" => "用户已暂停，补充要求后可继续" }
    prompt = service.send(:report_prompt, c, event)
    expect(prompt).to include("manually stopped", "paused", "2026-11-05T11:12:01Z")
    expect(prompt).not_to include("继续", "Latest feedback", "Next step", "Resume", "Original request", "Worker feedback")
  end

  it "accepts legacy yield reasons and normalizes stored cards and pending reports" do
    c = running
    result = service.yield_work(worker, reason: "needs_user", summary: "Question")
    expect(result).to include(status: "needs_input", end_turn: true, awaiting_feedback: true)
    store.transaction do |data|
      data["cards"][c["id"]]["status"] = "waiting_user"
      data["cards"][c["id"]]["outbox"].first["kind"] = "needs_user"
    end
    expect(current["status"]).to eq("needs_input")
    expect(current["outbox"].first["kind"]).to eq("needs_input")
    store.transaction do |data|
      data["cards"][c["id"]]["status"] = "running"
    end
    Thread.current[:clacky_work] = { id: c["id"], revision: c["revision"] }
    result = service.yield_work(worker, reason: "waiting_reply", summary: "Waiting")
    expect(result).to include(status: "waiting_event", awaiting_feedback: false)
    store.transaction { |data| data["cards"][c["id"]]["status"] = "waiting_reply" }
    expect(current["status"]).to eq("waiting_event")
  end

  it "resumes failed work without new instructions and retains its worker session" do
    c = card
    store.transaction { |d| d["cards"][c["id"]]["status"] = "failed" }
    expect { service.manage("other", action: "resume", work_id: c["id"]) }.to raise_error(/not found/)
    expect { service.manage("owner", action: "resume", work_id: c["id"], expected_revision: 0) }.to raise_error(/changed/)
    resumed = service.manage("owner", action: "resume", work_id: c["id"], expected_revision: 1)
    expect(resumed).to include("status" => "queued", "session_id" => c["session_id"], "revision" => 2)
    store.transaction { |d| d["cards"][c["id"]]["status"] = "cancelled" }
    expect { service.manage("owner", action: "resume", work_id: c["id"]) }.to raise_error(/finished/)
  end

  it "rejects invalid deadlines without changing state" do
    running
    expect { service.yield_work(worker, reason: "waiting_event", summary: "等回复", check_at: "tomorrow") }.to raise_error(ArgumentError)
    expect(current["status"]).to eq("running")
  end

  it "keeps display summaries separate from reports and clears them on owner updates" do
    running
    service.yield_work(worker, reason: "needs_input", summary: "Detailed evidence and internal references", display_summary: "Raise the budget?")
    expect(current["display_summary"]).to eq("Raise the budget?")
    expect(current["outbox"].last["text"]).to eq("Detailed evidence and internal references")
    service.manage("owner", action: "reply", work_id: card["id"], instruction: "Yes")
    expect(current).not_to have_key("display_summary")
  end

  it "records waiting without notifying the secretary" do
    running
    service.yield_work(worker, reason: "waiting_event", summary: "等回复")
    expect(current).to include("status" => "waiting_event", "outbox" => [])
  end

  it "resumes an exact threaded reply once and treats it as external evidence" do
    running
    service.yield_work(worker, reason: "waiting_event", summary: "等回复", channel: "feishu", conversation_id: "chat", reply_to: "sent")
    event = { chat_id: "chat", message_id: "reply", reply_to: "sent", user_id: "zhang", text: "周五可以" }
    expect(service.receive_event("feishu", event)).to be(true)
    expect(service.receive_event("feishu", event)).to be(true)
    expect(current["status"]).to eq("queued")
    expect(current["pending_inputs"].size).to eq(1)
    expect(current["pending_inputs"].first["kind"]).to eq("external_reply")
  end

  it "handles replies that arrive before the worker registers its wait" do
    running
    expect(service.receive_event("feishu", { chat_id: "chat", message_id: "reply", reply_to: "sent", text: "可以" })).to be(false)
    service.yield_work(worker, reason: "waiting_event", summary: "等回复", channel: "feishu", conversation_id: "chat", reply_to: "sent")
    expect(current["status"]).to eq("queued")
  end

  it "does not consume unthreaded or wrong-chat messages" do
    running
    service.yield_work(worker, reason: "waiting_event", summary: "等回复", channel: "feishu", conversation_id: "chat", reply_to: "sent")
    expect(service.receive_event("feishu", { chat_id: "chat", message_id: "1", text: "可以" })).to be(false)
    expect(service.receive_event("feishu", { chat_id: "other", message_id: "2", reply_to: "sent", text: "可以" })).to be(false)
    expect(current["status"]).to eq("waiting_event")
  end

  it "cancels waiting and ignores late replies" do
    c = running
    service.yield_work(worker, reason: "waiting_event", summary: "等回复", channel: "feishu", conversation_id: "chat", reply_to: "sent")
    allow(registry).to receive(:get).with("worker").and_return({ status: :idle })
    service.manage("owner", action: "cancel", work_id: c["id"])
    expect(service.receive_event("feishu", { chat_id: "chat", message_id: "2", reply_to: "sent", text: "可以" })).to be(false)
    expect(current["status"]).to eq("cancelled")
    expect { service.manage("owner", action: "reply", work_id: c["id"], instruction: "继续") }.to raise_error(/finished/)
  end

  it "preserves waits across restart but reports interrupted execution for review" do
    running
    service.recover
    expect(current["status"]).to eq("failed")
    expect(current["outbox"].first["kind"]).to eq("failed")
    service.recover
    expect(current["outbox"].size).to eq(1)
  end

  it "queues an overdue checkpoint without automatically sending anything" do
    c = running
    service.yield_work(worker, reason: "waiting_event", summary: "等回复", check_at: (Time.now + 60).iso8601)
    store.transaction { |d| d["cards"][c["id"]]["waiting"]["check_at"] = (Time.now - 1).iso8601 }
    allow(registry).to receive(:ensure).and_return(false)
    service.tick
    expect(current["status"]).to eq("queued")
    expect(current["pending_inputs"].first["kind"]).to eq("deadline")
  end

  it "runs work independently and returns completed results through the secretary" do
    card
    idle_registry
    allow(runner).to receive(:call) do |sid, prompt, **options, &block|
      actor = sid == "owner" ? owner : worker
      execute = -> { actor.run(prompt, display_text: options[:display_message],
                              reference_contexts: options[:reference_contexts]) }
      block.call(execute, actor)
      :thread
    end
    allow(worker).to receive(:run) do
      service.yield_work(worker, reason: "completed", summary: "研究结果")
      { status: :success }
    end
    allow(owner).to receive(:run).and_return({ status: :success })
    service.tick
    expect(current["status"]).to eq("completed")
    service.tick
    expect(owner).to have_received(:run).with(a_string_including("研究结果"), hash_including(reference_contexts: [hash_including(type: "session", session_id: current["id"])]))
    expect(persist).to have_received(:call).with(owner)
    expect(current["outbox"].first["state"]).to eq("delivered")
  end

  it "does not redeliver an acknowledged report" do
    running
    service.yield_work(worker, reason: "needs_input", summary: "Which date?")
    event = current["outbox"].first
    service.send(:ack, current["id"], event["id"])
    idle_registry
    expect(runner).not_to receive(:call)
    service.tick
    expect(current["outbox"].first["state"]).to eq("delivered")
  end

  it "does not start a second execution while the prior worker thread is settling" do
    card
    idle_registry
    allow(registry).to receive(:get).with("worker").and_return({ status: :idle, thread: double(alive?: true) })
    expect(runner).not_to receive(:call)
    service.tick
    expect(current["status"]).to eq("queued")
  end

  it "leaves a foreground capacity slot" do
    card
    idle_registry
    allow(registry).to receive(:count_by_status).with(:running).and_return(2)
    expect(runner).not_to receive(:call)
    service.tick
  end

  it "invalidates only the owning extension state after durable changes" do
    running
    service.yield_work(worker, reason: "waiting_event", summary: "等回复")
    service.tick
    service.tick
    expect(published).to eq([["owner", "ext.work.changed"]])
    allow(registry).to receive(:get).with("worker").and_return({ status: :idle })
    service.manage("owner", action: "pause", work_id: card["id"])
    service.tick
    expect(published.size).to eq(2)
    expect(current["status"]).to eq("paused")
  end

  it "fails closed on corrupt storage" do
    File.write(File.join(dir, "work.json"), "broken")
    expect { service.list("owner") }.to raise_error(JSON::ParserError)
    expect(File.read(File.join(dir, "work.json"))).to eq("broken")
  end
end
