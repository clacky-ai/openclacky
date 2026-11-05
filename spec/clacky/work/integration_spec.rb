# frozen_string_literal: true
require "spec_helper"
require "clacky/server/http_server"
require_relative "../../support/http_server_spec_helpers"

RSpec.describe "Secretary server integration" do
  include HttpServerSpecHelpers
  around do |example|
    previous = Thread.current[:lang]
    Thread.current[:lang] = "en"
    example.run
  ensure
    Thread.current[:lang] = previous
  end

  let(:config) do
    Clacky::AgentConfig.new(memory_update_enabled: false, skill_evolution: { enabled: false }, models: [
      { "model" => "test-model", "api_key" => "test-key", "base_url" => "https://example.invalid", "type" => "default" }
    ])
  end

  def wait_thread(registry, sid)
    thread = registry.get(sid)[:thread]
    expect(thread).not_to be_nil
    joined = thread.join(5)
    expect(joined).not_to be_nil, "#{thread.backtrace&.join("\n")}\n#{registry.get(sid)[:agent].history.to_a.last(4).inspect}"
  end

  it "delegates through the actual extension tool, ends on yield, and delivers a persisted result" do
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(Dir.pwd)
      registry = server.instance_variable_get(:@registry)
      live_events = []
      finished_events = []
      allow(server).to receive(:broadcast_all) { |event| finished_events << event }
      allow(server).to receive(:broadcast) { |sid, event| live_events << [sid, event] }
      owner_id = server.send(:build_session, name: "Secretary", profile: "secretary")
      owner = registry.get(owner_id)[:agent]
      owner.history.append(role: "user", content: "帮我整理旅行建议", message_id: "original")
      card = owner.tool_registry.get("delegate_work").execute(title: "旅行建议", task: "整理建议")
      expect(card["id"]).to eq(card["session_id"])
      worker = registry.get(card["session_id"])[:agent]
      expect(worker.tool_registry.tool_names).to include("yield_work", "web_search")
      expect(worker.tool_registry.tool_names).to include("terminal", "write", "invoke_skill", "ask_user")
      expect(worker.tool_registry.tool_names).not_to include("delegate_work")
      output = File.join(server.work_service.instance_variable_get(:@store).instance_variable_get(:@path) + ".output.md")
      allow(worker).to receive(:think) do
        calls = [
          { id: "write1", name: "write", arguments: JSON.generate(path: output, content: "Travel report") },
          { id: "yield1", name: "yield_work", arguments: JSON.generate(reason: "completed", summary: "建议先确定日期，再比较交通。", display_summary: "旅行建议已整理完成") },
          { id: "after-yield", name: "web_search", arguments: JSON.generate(query: "must not execute") }
        ]
        worker.history.append(role: "assistant", content: nil, tool_calls: calls)
        { content: nil, tool_calls: calls }
      end
      expect(worker.tool_registry.get("web_search")).not_to receive(:execute)
      server.work_service.tick
      wait_thread(registry, card["session_id"])
      expect(File.read(output)).to eq("Travel report")
      expect(server.work_service.list(owner_id).first["status"]).to eq("completed")
      expect(server.work_service.list(owner_id).first["display_summary"]).to eq("旅行建议已整理完成")
      yield_tool = worker.tool_registry.get("yield_work")
      expect(yield_tool.ui_result(error: "rejected")).to be_nil
      expect(yield_tool.format_call(reason: "completed", display_summary: "旅行建议已整理完成")).to eq("旅行建议已整理完成")
      expected_ui = { type: "markdown", content: "建议先确定日期，再比较交通。" }
      expect(live_events).to include([card["session_id"], hash_including(type: "tool_result", ui: expected_ui)])
      worker_events = []
      worker.replay_history(Clacky::Server::HistoryCollector.new(card["session_id"], worker_events))
      expect(worker_events).to include(hash_including(type: "tool_result", ui: expected_ui))
      expect(worker).to have_received(:think).once
      allow(owner).to receive(:think) do
        owner.history.append(role: "assistant", content: "工作完成，以下是建议。", task_id: owner.instance_variable_get(:@current_task_id))
        { content: "工作完成，以下是建议。", tool_calls: [] }
      end
      allow(owner).to receive(:run_memory_update_subagent)
      allow(owner).to receive(:run_skill_evolution_hooks)
      server.work_service.tick
      wait_thread(registry, owner_id)
      expect(server.work_service.list(owner_id).first["outbox"].first["state"]).to eq("delivered")
      saved = server.instance_variable_get(:@session_manager).load(owner_id)
      expect(finished_events).to include(hash_including(type: "task_finished", session_id: owner_id, awaiting_feedback: false))
      expect(finished_events.find { |event| event[:type] == "task_finished" && event[:session_id] == owner_id }[:notify_user]).not_to be(false)
      expect(saved.to_json).not_to include("work-event:")
      event_message = owner.history.to_a.find { |m| m[:display_text] == "Work completed: 旅行建议" }
      reference = { type: "session", session_id: card["id"], name: card["title"] }
      expect(event_message).to include(display_text: "Work completed: 旅行建议", display_references: [reference])
      expect(live_events).to include([owner_id, hash_including(type: "history_user_message", references: [reference])])
      expect(event_message[:content]).to include("建议先确定日期", "Original request: 整理建议", "Next step:")
      expect(event_message[:content]).not_to include("work-event:")
      expect(owner.history.to_api.to_json).not_to include("work-event:")
      expect(owner.history.to_a).to include(hash_including(system_injected: true, content: a_string_including("Referenced conversation")))
      expect(event_message[:system_injected]).not_to be(true)
      expect(live_events).to include([owner_id, hash_including(type: "history_user_message", content: "Work completed: 旅行建议")])
      expect(live_events).to include([owner_id, hash_including(type: "assistant_message", content: "工作完成，以下是建议。")])
      expect(live_events).to include([card["session_id"], hash_including(type: "history_user_message", content: "Starting: 旅行建议")])
      replay = Clacky::Server::HistoryCollector.new(owner_id, [])
      owner.replay_history(replay)
      rendered = replay.instance_variable_get(:@events).select { |e| e[:type] == "history_user_message" }
      expect(rendered.map { |e| e[:content] }).to eq(["帮我整理旅行建议", "Work completed: 旅行建议"])
      expect(rendered.last[:references]).to eq([reference])
      expect(saved[:messages]).to include(hash_including(display_references: [reference]))
      expect(replay.instance_variable_get(:@events)).to include(hash_including(type: "assistant_message", content: "工作完成，以下是建议。"))
      expect(rendered.to_json).not_to include("work-event:", "这是工作结果", "返回 completed")

    end
  end

  it "accepts direct feedback and queued follow-ups in the same completed worker with references" do
    with_server(agent_config: config) do |server|
      registry = server.instance_variable_get(:@registry)
      owner_id = server.send(:build_session, name: "Owner", profile: "secretary")
      owner = registry.get(owner_id)[:agent]
      card = server.work_service.delegate(owner, title: "Report", task: "Prepare report")
      worker = registry.get(card["session_id"])[:agent]
      turn = 0
      allow(worker).to receive(:think) do
        turn += 1
        if turn == 2
          # WebSocket input arrives on a request thread, not the worker's epoch.
          Thread.new do
            server.handle_user_message(card["session_id"], "Explain the conclusion", [], references: [{ "type" => "quote", "text" => "Conclusion" }])
          end.value
        end
        calls = [{ id: "finish-#{turn}", name: "yield_work", arguments: JSON.generate(reason: "completed", summary: "Result #{turn}") }]
        worker.history.append(role: "assistant", content: nil, tool_calls: calls)
        { content: nil, tool_calls: calls }
      end
      server.work_service.tick
      wait_thread(registry, card["session_id"])
      ref = { "type" => "quote", "text" => "First draft", "label" => "Review" }
      attachment_path = File.join(server.work_service.instance_variable_get(:@store).instance_variable_get(:@path) + ".notes.txt")
      File.write(attachment_path, "Keep the conclusion")
      files = [{ name: "notes.txt", path: attachment_path, type: "file" }]
      server.handle_user_message(card["session_id"], "Make it shorter", files, references: [ref])
      wait_thread(registry, card["session_id"])
      current = server.work_service.list(owner_id).first
      expect(current).to include("id" => card["id"], "status" => "completed", "revision" => 3)
      expect(current["updates"].map { |u| u["text"] }).to eq(["Make it shorter", "Explain the conclusion"])
      expect(worker.history.to_a).to include(hash_including(content: "Make it shorter", display_references: [ref]))
      expect(worker.history.to_a).to include(hash_including(content: "Explain the conclusion"))
      expect(worker.history.to_a).not_to include(hash_including(system_injected: true, content: a_string_including("speaking directly")))
      expect(worker.history.to_a).to include(hash_including(system_injected: true, content: a_string_including("First draft")))
      feedback = worker.history.to_a.find { |m| m[:content] == "Make it shorter" }
      expect(feedback[:display_files]).to include(hash_including(name: "notes.txt", path: attachment_path))
      expect(turn).to eq(3)
      expect(current["outbox"].map { |e| e["state"] }).to eq(%w[superseded superseded pending])
    end
  end

  %w[queue steer].each do |mode|
    it "keeps running worker input visible on reconnect and honors #{mode}" do
      config.input_behavior = mode
      with_server(agent_config: config) do |server|
        registry = server.instance_variable_get(:@registry)
        owner_id = server.send(:build_session, name: "Owner", profile: "secretary")
        card = server.work_service.delegate(registry.get(owner_id)[:agent], title: "Report", task: "Prepare report")
        worker = registry.get(card["session_id"])[:agent]
        entered, release = Queue.new, Queue.new
        turn = 0
        allow(worker).to receive(:run_memory_update_subagent)
        allow(worker).to receive(:run_skill_evolution_hooks)
        allow(worker).to receive(:think) do
          turn += 1
          if turn == 1
            entered << true
            release.pop
            calls = [{ id: "read", name: "read", arguments: JSON.generate(path: __FILE__) }]
          elsif turn == 2
            expect(worker.history.to_a.any? { |m| m[:content] == "Explain the choice" }).to eq(mode == "steer")
            calls = [{ id: "yield", name: "yield_work", arguments: JSON.generate(reason: "completed", summary: "Report ready") }]
          else
            expect(worker.history.to_a).to include(hash_including(content: "Explain the choice"))
            worker.history.append(role: "assistant", content: "Here is the explanation.", task_id: worker.instance_variable_get(:@current_task_id))
            next({ content: "Here is the explanation.", tool_calls: [] })
          end
          worker.history.append(role: "assistant", content: nil, tool_calls: calls)
          { content: nil, tool_calls: calls }
        end
        begin
          server.work_service.tick
          Timeout.timeout(5) { entered.pop }
          server.handle_user_message(card["session_id"], "Explain the choice", [], references: [{ "type" => "quote", "text" => "The choice" }])
          expect(worker.pending_inputs.map { |entry| entry[:content] }).to eq(["Explain the choice"])
          expect(server.work_service.list(owner_id).first["pending_inputs"]).to be_empty
          reconnect_events = []
          conn = double("reconnected browser").as_null_object
          allow(conn).to receive(:closed?).and_return(false)
          allow(conn).to receive(:send_json) { |event| reconnect_events << event; true }
          server.on_ws_message(conn, JSON.generate(type: "subscribe", session_id: card["session_id"]))
          expect(reconnect_events).to include(hash_including(type: "input_queue", entries: [hash_including(content: "Explain the choice")]))
          expect(worker.to_session_data[:pending_inputs]).to include(hash_including(content: "Explain the choice"))
          release << true
          wait_thread(registry, card["session_id"])
          expect(worker.pending_inputs).to be_empty
          expect(worker.history.to_a.count { |m| m[:content] == "Explain the choice" }).to eq(1)
          expect(worker.total_tasks).to eq(mode == "queue" ? 2 : 1)
          expect(server.work_service.list(owner_id).first["status"]).to eq("completed")
          saved = server.instance_variable_get(:@session_manager).load(card["session_id"])
          expect(saved[:messages]).to include(hash_including(content: "Explain the choice"))
        ensure
          release << true
          registry.get(card["session_id"])[:thread]&.join(5)
        end
      end
    end
  end

  it "renders an ordinary direct answer without requiring yield or sending a new owner report" do
    with_server(agent_config: config) do |server|
      registry = server.instance_variable_get(:@registry)
      events = []
      allow(server).to receive(:broadcast) { |sid, event| events << [sid, event] }
      owner_id = server.send(:build_session, name: "Owner", profile: "secretary")
      owner = registry.get(owner_id)[:agent]
      card = server.work_service.delegate(owner, title: "Report", task: "Prepare report")
      worker = registry.get(card["session_id"])[:agent]
      store = server.work_service.instance_variable_get(:@store)
      store.transaction do |data|
        data["cards"][card["id"]].merge!("status" => "completed", "progress" => "Delivered", "display_summary" => "Report ready")
      end
      allow(worker).to receive(:run_memory_update_subagent)
      allow(worker).to receive(:run_skill_evolution_hooks)
      allow(worker).to receive(:think) do
        worker.history.append(role: "assistant", content: "I chose it because it fits your budget.", task_id: worker.instance_variable_get(:@current_task_id))
        { content: "I chose it because it fits your budget.", tool_calls: [] }
      end
      server.handle_user_message(card["session_id"], "Why this option?")
      wait_thread(registry, card["session_id"])
      current = server.work_service.list(owner_id).first
      expect(current).to include("status" => "completed", "progress" => "Delivered", "display_summary" => "Report ready")
      expect(current["outbox"]).to be_empty
      expect(current["pending_inputs"]).to be_empty
      expect(registry.get(card["session_id"])[:status]).to eq(:idle)
      expect(events).to include([card["session_id"], hash_including(type: "assistant_message", content: "I chose it because it fits your budget.")])
    end
  end

  { "completed" => :idle, "waiting_event" => :idle, "needs_input" => :awaiting_feedback }.each do |reason, status|
    it "ends #{reason} as #{status} without notifying from the worker session" do
      with_server(agent_config: config) do |server|
        registry = server.instance_variable_get(:@registry)
        events = []
        allow(server).to receive(:broadcast_all) { |event| events << event }
        sid = server.send(:build_session, name: "Owner", profile: "secretary")
        owner = registry.get(sid)[:agent]
        card = server.work_service.delegate(owner, title: "Work", task: "Work")
        worker = registry.get(card["session_id"])[:agent]
        allow(worker).to receive(:think) do
          calls = [{ id: "yield", name: "yield_work", arguments: JSON.generate(reason: reason, summary: "Outcome") }]
          worker.history.append(role: "assistant", content: nil, tool_calls: calls)
          { content: nil, tool_calls: calls }
        end
        server.work_service.tick
        wait_thread(registry, card["session_id"])
        expect(registry.get(card["session_id"])[:status]).to eq(status)
        expect(events).to include(hash_including(type: "task_finished", session_id: card["session_id"],
                                                awaiting_feedback: status == :awaiting_feedback, notify_user: false))
        if status == :awaiting_feedback
          reason = "completed"
          server.handle_user_message(card["session_id"], "Use the agreed option")
          wait_thread(registry, card["session_id"])
          expect(registry.get(card["session_id"])[:status]).to eq(:idle)
          expect(server.work_service.list(sid).first["status"]).to eq("completed")
        end
      end
    end
  end

  it "keeps the owner available and suppresses the handoff completion alert" do
    with_server(agent_config: config) do |server|
      registry = server.instance_variable_get(:@registry)
      events = []
      allow(server).to receive(:broadcast_all) { |event| events << event }
      sid = server.send(:build_session, name: "Owner", profile: "secretary")
      owner = registry.get(sid)[:agent]
      turn = 0
      allow(owner).to receive(:think) do
        turn += 1
        calls = turn == 1 ? [{ id: "delegate", name: "delegate_work", arguments: JSON.generate(title: "Report", task: "Write a report") }] : []
        owner.history.append(role: "assistant", content: "Delegated", tool_calls: calls)
        { content: "Delegated", tool_calls: calls }
      end
      allow(owner).to receive(:run_skill_evolution_hooks)
      allow(owner).to receive(:run_memory_update_subagent)
      server.send(:run_session_task, sid, "Prepare a report")
      wait_thread(registry, sid)
      expect(registry.get(sid)[:status]).to eq(:idle)
      expect(server.work_service.list(sid).first["status"]).to eq("queued")
      expect(events).to include(hash_including(type: "task_finished", session_id: sid, notify_user: false))
    end
  end

  it "pauses a user-interrupted worker and resumes the same session through manage_work" do
    with_server(agent_config: config) do |server|
      registry = server.instance_variable_get(:@registry)
      owner_id = server.send(:build_session, name: "Owner", profile: "secretary")
      owner = registry.get(owner_id)[:agent]
      card = server.work_service.delegate(owner, title: "Continue report", task: "Prepare report")
      worker_id = card["session_id"]
      worker = registry.get(worker_id)[:agent]
      started = Queue.new
      blocker = Queue.new
      allow(worker).to receive(:think) do
        worker.history.append(role: "assistant", content: "Saved partial research")
        started << true
        blocker.pop
      end
      server.work_service.tick
      Timeout.timeout(5) { started.pop }
      server.send(:interrupt_session, worker_id)
      wait_thread(registry, worker_id)
      paused = server.work_service.list(owner_id).first
      expect(paused["status"]).to eq("paused")
      expect(paused["outbox"].last["kind"]).to eq("paused")
      expect(server).not_to receive(:build_session)
      tool = owner.tool_registry.get("manage_work")
      resumed = tool.execute(action: "resume", work_id: card["id"], expected_revision: paused["revision"])
      expect(resumed).to include("id" => card["id"], "session_id" => worker_id, "status" => "queued", :notify_user => false)
      expect(tool.execute(action: "resume", work_id: card["id"])["revision"]).to eq(resumed["revision"])
      allow(worker).to receive(:think) do
        expect(worker.history.to_a).to include(hash_including(content: "Saved partial research"))
        calls = [{ id: "finish-resumed", name: "yield_work", arguments: JSON.generate(reason: "completed", summary: "Report completed") }]
        worker.history.append(role: "assistant", content: nil, tool_calls: calls)
        { content: nil, tool_calls: calls }
      end
      server.work_service.tick
      wait_thread(registry, worker_id)
      expect(server.work_service.list(owner_id).size).to eq(1)
      expect(server.work_service.list(owner_id).first).to include("session_id" => worker_id, "status" => "completed")
    end
  end

  it "shows a friendly delegation receipt live and when replaying persisted cards" do
    with_server(agent_config: config) do |server|
      sid = server.send(:build_session, name: "Secretary", profile: "secretary")
      owner = server.instance_variable_get(:@registry).get(sid)[:agent]
      tool = owner.tool_registry.get("delegate_work")
      card = tool.execute(title: "Check travel prices", task: "Private detailed instructions")
      expect(tool.format_call(title: card["title"])).to eq("Delegate: Check travel prices")
      expect(tool.format_result(card)).to include("waiting to start")
      expected = tool.ui_result(card)
      expect(expected[:content]).not_to include("Private detailed instructions", card["id"])
      expect(tool.ui_result(error: "denied")).to be_nil
      expect(tool.ui_result(card.merge("locale" => "zh"))[:content]).to include("等待执行")
      owner.history.append(role: "assistant", content: nil, tool_calls: [
        { id: "delegate", name: "delegate_work", arguments: JSON.generate(title: card["title"], task: "Private detailed instructions") }
      ])
      owner.history.append(role: "tool", tool_call_id: "delegate", content: JSON.generate(card))
      events = []
      owner.replay_history(Clacky::Server::HistoryCollector.new(sid, events))
      expect(events).to include(hash_including(type: "tool_result", ui: expected))
    end
  end

  it "uses the same friendly input for live display and replay through the generic session entry point" do
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(Dir.pwd)
      registry = server.instance_variable_get(:@registry)
      sid = server.send(:build_session, name: "Background", profile: "general")
      agent = registry.get(sid)[:agent]
      allow(agent.ui).to receive(:show_user_message)
      allow(agent).to receive(:think) do
        agent.history.append(role: "assistant", content: "已收到更新。")
        { content: "已收到更新。", tool_calls: [] }
      end
      allow(agent).to receive(:run_skill_evolution_hooks)
      server.send(:run_session_task, sid, "internal-event", display_message: "后台更新", reference_contexts: ["private-context"])
      wait_thread(registry, sid)
      expect(agent.ui).to have_received(:show_user_message).with("后台更新", source: :web)
      expect(agent.history.to_a).to include(hash_including(content: "internal-event", display_text: "后台更新"))
      events = []
      agent.replay_history(Clacky::Server::HistoryCollector.new(sid, events))
      expect(events).to include(hash_including(type: "history_user_message", content: "后台更新"))
      expect(events).to include(hash_including(type: "assistant_message", content: "已收到更新。"))
      expect(events.to_json).not_to include("private-context", "internal-event")
    end
  end

  it "replays and continues a legacy ordinary session without rewriting its references" do
    with_server(agent_config: config) do |server|
      sid = server.send(:build_session, name: "Legacy chat", profile: "general")
      agent = server.instance_variable_get(:@registry).get(sid)[:agent]
      refs = [
        { type: "session", session_id: "past-chat", name: "Past chat" },
        { type: "quote", label: "Earlier answer", text: "Original quote" },
        { type: "file", path: "/tmp/context.md", name: "context.md" }
      ]
      agent.history.append(role: "user", content: "original input", display_text: "Visible input",
                           display_references: refs, task_id: 1)
      agent.history.append(role: "user", content: "old hidden reference context", system_injected: true, task_id: 1)
      agent.history.append(role: "assistant", content: "Old answer", task_id: 1)
      saved = JSON.parse(JSON.generate(agent.to_session_data), symbolize_names: true)
      restored = Clacky::Agent.from_session(double("client"), config.deep_copy, saved, ui: nil, profile: "general")
      events = []
      restored.replay_history(Clacky::Server::HistoryCollector.new(sid, events))
      expect(events).to include(hash_including(type: "history_user_message", content: "Visible input", references: refs))
      expect(events.to_json).not_to include("old hidden reference context")
      expect(restored.history.to_api.to_json).to include("old hidden reference context")
      allow(restored).to receive(:think).and_return(content: "New answer", tool_calls: [])
      allow(restored).to receive(:run_skill_evolution_hooks)
      allow(restored).to receive(:run_memory_update_subagent)
      restored.run("Continue", reference_contexts: [{ type: "quote", text: "New quote", context: "[Quoted excerpt from this conversation]\nNew quote" }])
      expect(restored.history.to_a).to include(hash_including(content: "original input", display_references: refs))
      expect(restored.history.to_a).to include(hash_including(content: "[Quoted excerpt from this conversation]\nNew quote", system_injected: true))
    end
  end

  it "rolls back a failed work-report turn without removing the preceding user conversation" do
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(Dir.pwd)
      sid = server.send(:build_session, name: "Rollback", profile: "general")
      agent = server.instance_variable_get(:@registry).get(sid)[:agent]
      allow(agent).to receive(:run_skill_evolution_hooks)
      allow(agent).to receive(:think).and_return({ content: "已记录", tool_calls: [] })
      agent.run("保留之前的用户消息")
      allow(agent).to receive(:think).and_raise(Clacky::BadRequestError.new("bad request"))
      expect { agent.run("internal-event", reference_contexts: [{ type: "quote", text: "hidden detail", context: "[Quoted excerpt from this conversation]\nhidden detail" }]) }.to raise_error(Clacky::BadRequestError)
      snapshot = agent.to_session_data(status: :error, error_message: "bad request")
      # Restoring must retain the work-report turn as an error boundary as well.
      restored = Clacky::Agent.from_session(agent.instance_variable_get(:@client), config.deep_copy, snapshot, ui: nil, profile: "general")
      allow(restored).to receive(:run_skill_evolution_hooks)
      allow(restored).to receive(:think).and_return({ content: "继续", tool_calls: [] })
      restored.run("继续处理")
      texts = restored.history.to_a.map { |m| m[:content] }
      expect(texts).to include("保留之前的用户消息", "继续处理")
      expect(texts).not_to include("internal-event", "hidden detail")
    end
  end

  it "keeps the panel API read-only and changes work through the secretary tool" do
    Clacky::ExtensionLoader.load_all(force: true)
    Clacky::ApiExtensionLoader.load_all(reload: true)
    with_server(agent_config: config) do |server|
      allow(server).to receive(:default_working_dir).and_return(Dir.pwd)
      id = server.send(:build_session, name: "Secretary", profile: "secretary")
      owner = server.instance_variable_get(:@registry).get(id)[:agent]
      card = server.work_service.delegate(owner, title: "约饭", task: "准备邀请")
      updated = owner.tool_registry.get("manage_work").execute(action: "reply", work_id: card["id"], instruction: "改为周五", expected_revision: 1)
      expect(updated["revision"]).to eq(2)
      res = fake_res
      req = fake_req(method: "GET", path: "/api/ext/secretary/work")
      allow(req).to receive(:query).and_return({ "session_id" => id })
      Clacky::Server::ApiExtensionDispatcher.handle(req, res, http_server: server)
      expect(res.status).to eq(200), res.body
      expect(parsed_body(res).dig("work", 0, "revision")).to eq(2)
      req = fake_req(method: "POST", path: "/api/ext/secretary/work/#{card['id']}",
                     body: { session_id: id, action: "cancel" })
      Clacky::Server::ApiExtensionDispatcher.handle(req, res, http_server: server)
      expect(res.status).to eq(404)
    end
  end
end
