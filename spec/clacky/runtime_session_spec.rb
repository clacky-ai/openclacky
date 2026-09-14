# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::RuntimeSession do
  FakeProfile = Struct.new(:name)

  class RuntimeSessionSpecUI
    attr_reader :assistant_messages, :assistant_deltas, :assistant_finishes,
      :tool_calls, :tool_results, :keyed_tool_calls, :keyed_tool_results,
      :queues, :events, :progress, :todo_updates, :token_usages,
      :user_messages, :warnings

    def initialize
      @assistant_messages = []
      @assistant_deltas = []
      @assistant_finishes = []
      @tool_calls = []
      @tool_results = []
      @keyed_tool_calls = []
      @keyed_tool_results = []
      @queues = []
      @events = []
      @progress = []
      @todo_updates = []
      @token_usages = []
      @user_messages = []
      @warnings = []
    end

    def show_assistant_message(content, files:, interim: false, created_at: nil)
      @assistant_messages << { content: content, files: files, interim: interim, created_at: created_at }
    end

    def show_assistant_delta(message_id, content)
      @assistant_deltas << { message_id: message_id, content: content }
    end

    def finish_assistant_stream(message_id, content, files:, created_at: nil,
                                message_ids: nil)
      @assistant_finishes << {
        message_id: message_id,
        message_ids: message_ids,
        content: content,
        files: files,
        created_at: created_at
      }
    end

    def show_tool_call(name, args)
      @tool_calls << [name, args]
    end

    def show_tool_result(result)
      @tool_results << result
    end

    def show_keyed_tool_call(name, args, tool_call_id:)
      @keyed_tool_calls << [tool_call_id, name, args]
    end

    def show_keyed_tool_result(result, tool_call_id:, status: nil, exit_code: nil)
      @keyed_tool_results << [tool_call_id, result, status, exit_code]
    end

    def show_input_queue(entries)
      @queues << entries
    end

    def show_user_message(content, **options)
      @user_messages << { content: content }.merge(options)
    end

    def emit(type, **data)
      @events << [type, data]
    end

    def show_progress(content, progress_type: nil)
      @progress << [progress_type, content]
    end

    def show_warning(content)
      @warnings << content
    end

    def update_todos(entries)
      @todo_updates << entries
    end

    def show_token_usage(token_data)
      @token_usages << token_data
    end
  end

  class RuntimeSessionSpecRuntime
    attr_reader :context, :persisted_state, :inputs, :cancel_reasons,
      :selected_models

    def initialize(context:, persisted_state: nil)
      @context = context
      @persisted_state = persisted_state
      @inputs = []
      @cancel_reasons = []
      @selected_models = []
      @selectable_models = nil
      @current_model = "gpt-5.3-codex"
      @closed = false
    end

    def capabilities
      capabilities = { cancel: true, image_input: true }
      capabilities[:model_selection] = true if @selectable_models
      capabilities
    end

    def enable_model_selection(*models)
      @selectable_models = models
    end

    def model_options
      Array(@selectable_models)
    end

    def set_model(model)
      @selected_models << model
      @current_model = model
      true
    end

    def run(input, generation:)
      @inputs << [input, generation]
      @context[:event_sink].call(
        generation,
        type: :assistant_delta,
        message_id: "assistant-1",
        content: "Hello "
      )
      @context[:event_sink].call(
        generation,
        type: :tool_call,
        tool_call_id: "tool-1",
        name: "terminal",
        input: { "command" => "pwd" }
      )
      @context[:event_sink].call(
        generation,
        type: :tool_result,
        tool_call_id: "tool-1",
        result: "/workspace"
      )
      @context[:event_sink].call(
        generation,
        type: :assistant_delta,
        message_id: "assistant-2",
        content: "world"
      )
      { stop_reason: "end_turn" }
    end

    def cancel(reason:)
      @cancel_reasons << reason
      true
    end

    def dump_state
      {
        "session_id" => "acp-session-1",
        "model" => @current_model,
        "reasoning_effort" => "high"
      }
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  let(:ui) { RuntimeSessionSpecUI.new }
  let(:config) do
    Clacky::AgentConfig.new(models: [
      {
        "id" => "runtime-card-1",
        "provider_id" => "codex",
        "runtime_id" => "codex",
        "display_model" => "Codex default",
        "type" => "default"
      }
    ], permission_mode: :confirm_all)
  end
  let(:built_runtimes) { [] }
  let(:runtime_factory) do
    lambda do |context:, persisted_state: nil|
      runtime = RuntimeSessionSpecRuntime.new(
        context: context,
        persisted_state: persisted_state
      )
      built_runtimes << runtime
      runtime
    end
  end

  def build_session(**overrides)
    described_class.new(
      runtime_id: "codex",
      runtime_factory: runtime_factory,
      config: config,
      working_dir: "/workspace",
      ui: ui,
      profile: FakeProfile.new("general"),
      session_id: "session-1",
      source: :manual,
      **overrides
    )
  end

  it "builds the provider runtime with a host context" do
    session = build_session
    runtime = built_runtimes.fetch(0)

    expect(runtime.context).to include(
      session_id: "session-1",
      working_dir: "/workspace",
      permission_mode: "confirm_all",
      default_model: "Codex default",
      ui: ui
    )
    expect(runtime.context[:event_sink]).to respond_to(:call)
    expect(runtime.persisted_state).to be_nil
    expect(session.runtime?).to be(true)
    expect(session.capability?(:cancel)).to be(true)
    expect(session.capability?(:time_machine)).to be(false)
  ensure
    session&.close
  end

  it "runs one turn, mirrors history, and finalizes streamed assistant text" do
    session = build_session

    Thread.current[:task_epoch] = 7
    result = session.run(
      "Say hello",
      files: [{ "name" => "photo.png", "data_url" => "data:image/png;base64,AA==" }],
      reference_contexts: ["Reference context"],
      created_at: 123.5,
      references_display: [{ "type" => "session", "session_id" => "other" }]
    )

    runtime_input, generation = built_runtimes.fetch(0).inputs.fetch(0)
    expect(generation).to eq(7)
    expect(runtime_input.content).to eq("Say hello")
    expect(runtime_input.files.first["name"]).to eq("photo.png")
    expect(runtime_input.reference_contexts).to eq(["Reference context"])
    expect(result).to include(stop_reason: "end_turn", awaiting_user_feedback: false)
    expect(session.history.to_a.map { |message| message[:role] })
      .to eq(%w[user assistant assistant tool assistant])
    expect(session.history.to_a[1][:content]).to eq("Hello ")
    expect(session.history.to_a.last[:content]).to eq("world")
    expect(ui.assistant_deltas).to eq([
      { message_id: "assistant-1", content: "Hello " },
      { message_id: "assistant-2", content: "world" }
    ])
    expect(ui.assistant_finishes).to include(
      hash_including(
        message_id: "assistant-1",
        message_ids: ["assistant-1"],
        content: "Hello ",
        files: []
      ),
      hash_including(
        message_id: "assistant-2",
        message_ids: ["assistant-2"],
        content: "world",
        files: []
      )
    )
    expect(ui.assistant_messages).to be_empty
    expect(ui.keyed_tool_calls).to eq([
      ["tool-1", "terminal", { "command" => "pwd" }]
    ])
    expect(ui.keyed_tool_results).to eq([["tool-1", "/workspace", nil, nil]])
    tool_call = session.history.to_a[2][:tool_calls].first
    expect(tool_call).to include(id: "tool-1", type: "function")
    expect(tool_call.dig(:function, :name)).to eq("terminal")
    expect(JSON.parse(tool_call.dig(:function, :arguments)))
      .to eq("command" => "pwd")
    expect(session.history.to_a[3]).to include(
      role: "tool", tool_call_id: "tool-1", content: "/workspace"
    )
    expect(session.total_tasks).to eq(1)
  ensure
    Thread.current[:task_epoch] = nil
    session&.close
  end

  it "drops provider events from a stale generation" do
    session = build_session
    session.begin_generation(4)

    accepted = session.accept_runtime_event(
      3,
      type: :assistant_delta,
      message_id: "late",
      content: "must not appear"
    )

    expect(accepted).to be(false)
    expect(session.history).to be_empty
    expect(ui.assistant_messages).to be_empty
  ensure
    session&.close
  end

  it "forwards runtime warnings only for the active generation" do
    session = build_session
    session.begin_generation(4)

    expect(session.accept_runtime_event(
      4,
      type: :warning,
      code: "resume_failed",
      content: "The saved runtime context could not be resumed."
    )).to be(true)
    expect(session.accept_runtime_event(
      3,
      type: :warning,
      code: "resume_failed",
      content: "This stale warning must not appear."
    )).to be(false)

    expect(ui.warnings).to eq([
      "The saved runtime context could not be resumed."
    ])
  ensure
    session&.close
  end

  it "persists and forwards failed tool-result metadata" do
    session = build_session
    session.begin_generation(44)
    runtime = built_runtimes.fetch(0)
    runtime.context[:event_sink].call(
      44,
      type: :tool_call,
      tool_call_id: "failed-tool",
      name: "terminal",
      input: { "command" => "false" }
    )
    runtime.context[:event_sink].call(
      44,
      type: :tool_result,
      tool_call_id: "failed-tool",
      result: "command failed",
      status: "failed",
      exit_code: 1
    )

    expect(ui.keyed_tool_results.last).to eq([
      "failed-tool", "command failed", "failed", 1
    ])
    expect(session.history.to_a.last).to include(
      role: "tool",
      content: "command failed",
      runtime_tool_status: "failed",
      runtime_exit_code: 1
    )
  ensure
    session&.close
  end

  it "rejects provider events that arrive after a successful turn returns" do
    session = build_session
    session.run("hello")
    runtime = built_runtimes.fetch(0)

    accepted = runtime.context[:event_sink].call(
      1,
      type: :assistant_delta,
      message_id: "late",
      content: "must not appear"
    )

    expect(accepted).to be(false)
    expect(session.history.to_a.map { |message| message[:content] })
      .not_to include("must not appear")
  end

  it "rejects provider events that arrive after a failed turn returns" do
    session = build_session
    runtime = built_runtimes.fetch(0)
    allow(runtime).to receive(:run).and_raise("provider failed")

    expect { session.run("hello") }.to raise_error("provider failed")
    accepted = runtime.context[:event_sink].call(
      1,
      type: :assistant_delta,
      message_id: "late",
      content: "must not appear"
    )

    expect(accepted).to be(false)
  end

  it "persists assistant text streamed before a runtime failure" do
    session = build_session
    runtime = built_runtimes.fetch(0)
    allow(runtime).to receive(:run) do |_input, generation:|
      runtime.context[:event_sink].call(
        generation,
        type: :assistant_delta,
        message_id: "partial-answer",
        content: "Visible before failure"
      )
      raise "provider failed"
    end

    expect { session.run("hello") }.to raise_error("provider failed")

    expect(ui.assistant_deltas).to eq([
      { message_id: "partial-answer", content: "Visible before failure" }
    ])
    expect(ui.assistant_finishes).to include(
      hash_including(
        message_id: "partial-answer",
        content: "Visible before failure"
      )
    )
    expect(session.history.to_a.map { |message| message[:role] })
      .to eq(%w[user assistant])
    expect(session.history.to_a.last[:content]).to eq("Visible before failure")
  ensure
    session&.close
  end

  it "rechecks the generation after decoding an event before mutating state" do
    session = build_session
    session.begin_generation(4)
    event = {
      type: :assistant_delta,
      message_id: "late",
      content: "must not appear"
    }
    switched = false
    event.define_singleton_method(:[]) do |key|
      value = super(key)
      unless switched || key != :type
        switched = true
        session.begin_generation(5)
      end
      value
    end

    accepted = session.accept_runtime_event(4, event)

    expect(accepted).to be(false)
    expect(ui.assistant_deltas).to be_empty
  ensure
    session&.close
  end

  it "accepts provider titles only while the session name is autogenerated" do
    session = build_session
    session.rename("First prompt", automatic: true)
    session.begin_generation(4)

    expect(session.accept_runtime_event(
      4, type: :session_info, title: "Codex title"
    )).to be(true)
    expect(session.name).to eq("Codex title")
    expect(ui.events.last).to eq([
      "session_renamed", { session_id: "session-1", name: "Codex title" }
    ])

    session.rename("My explicit title")
    session.accept_runtime_event(4, type: :session_info, title: "Late provider title")

    expect(session.name).to eq("My explicit title")
    expect(ui.events.length).to eq(1)

    session.rename("Session 99")
    session.accept_runtime_event(4, type: :session_info, title: "Another provider title")

    expect(session.name).to eq("Session 99")
    expect(ui.events.length).to eq(1)
  ensure
    session&.close
  end

  it "renders markdown plan updates without replacing structured todos" do
    session = build_session
    session.begin_generation(4)
    session.accept_runtime_event(
      4,
      type: :plan,
      content: "1. Inspect\n2. Test",
      plan_id: "plan-1"
    )

    expect(ui.progress).to eq([["plan", "1. Inspect\n2. Test"]])
    expect(ui.todo_updates).to be_empty
    expect(session.todos).to be_empty
  ensure
    session&.close
  end


  it "accepts structured ACP cost without leaking the runtime event type to the UI" do
    session = build_session
    session.begin_generation(4)

    expect do
      session.accept_runtime_event(
        4,
        type: :usage,
        used: 10,
        size: 100,
        cost: { "amount" => 0.25, "currency" => "USD" }
      )
    end.not_to raise_error

    expect(session.total_cost).to eq(0.25)
    expect(ui.token_usages).to eq([
      {
        used: 10,
        size: 100,
        cost: 0.25,
        cost_currency: "USD",
        cost_source: "provider"
      }
    ])
  ensure
    session&.close
  end

  it "ignores unknown provider events instead of forwarding their payload to the UI" do
    session = build_session
    session.begin_generation(4)

    expect(session.accept_runtime_event(
      4,
      type: :unknown,
      session_update: "future_update",
      secret_payload: "must not reach the browser"
    )).to be(true)

    expect(ui.events).to be_empty
  ensure
    session&.close
  end

  it "owns editable FIFO pending input independently of the provider" do
    session = build_session
    first_id = session.enqueue_input("first", files: [])
    second_id = session.enqueue_input("second", display_text: "Second")

    expect(session.edit_pending_input(second_id, "updated")).to be(true)
    expect(session.remove_pending_input("missing")).to be_nil
    expect(session.take_pending_input).to include(id: first_id, content: "first")
    expect(session.remove_pending_input(second_id)).to include(content: "updated")
    expect(session.pending_inputs).to be_empty
    expect(ui.queues).not_to be_empty
  ensure
    session&.close
  end

  it "serializes runtime identity and resume state without API credentials" do
    session = build_session
    session.rename("Codex work")
    session.pinned = true
    session.project_id = "project-1"

    data = session.to_session_data(status: :success, updated_at: Time.at(200))

    expect(data).to include(
      session_id: "session-1",
      name: "Codex work",
      pinned: true,
      working_dir: "/workspace",
      source: "manual",
      project_id: "project-1"
    )
    expect(data[:runtime]).to eq(
      id: "codex",
      version: 1,
      state: {
        "session_id" => "acp-session-1",
        "model" => "gpt-5.3-codex",
        "reasoning_effort" => "high"
      }
    )
    expect(data[:config]).to include(
      permission_mode: "confirm_all",
      model_id: "runtime-card-1",
      provider_id: "codex"
    )
    serialized = JSON.generate(data)
    expect(serialized).not_to include("api_key", "access_token", "refresh_token")
  ensure
    session&.close
  end

  it "restores the local transcript and passes only provider state to the runtime" do
    data = {
      session_id: "restored-session",
      name: "Restored",
      pinned: true,
      working_dir: "/restored",
      created_at: "2026-09-10T00:00:00Z",
      source: "manual",
      project_id: "project-2",
      pending_inputs: [{ id: "queued-1", content: "later", options: {} }],
      stats: { total_tasks: 3, total_cost_usd: 0.0, cost_source: "provider" },
      messages: [{ role: "user", content: "Earlier", created_at: 1.0 }],
      runtime: {
        id: "codex",
        version: 1,
        state: { session_id: "external-session", model: "gpt-5.3-codex" }
      }
    }

    session = described_class.from_session(
      runtime_factory: runtime_factory,
      config: config,
      session_data: data,
      ui: ui,
      profile: FakeProfile.new("general")
    )

    expect(session.session_id).to eq("restored-session")
    expect(session.name).to eq("Restored")
    expect(session.history.to_a.first[:content]).to eq("Earlier")
    expect(session.pending_inputs.first[:content]).to eq("later")
    expect(session.total_tasks).to eq(3)
    expect(built_runtimes.fetch(0).persisted_state).to eq(
      session_id: "external-session",
      model: "gpt-5.3-codex"
    )
  ensure
    session&.close
  end

  it "delegates cooperative cancellation and rejects agent-only operations" do
    session = build_session

    expect(session.cancel(reason: :replacement)).to be(true)
    expect(built_runtimes.fetch(0).cancel_reasons).to eq([:replacement])
    expect(session.parse_skill_command("/onboard")).to eq(found: false)
    expect { session.change_working_dir("/elsewhere") }.to raise_error(
      Clacky::RuntimeSession::UnsupportedCapability,
      /working directory/
    )
    expect { session.fork_runtime_state }.to raise_error(
      Clacky::RuntimeSession::UnsupportedCapability,
      /fork/
    )
    expect { session.set_session_sub_model("gpt-5.6-sol") }.to raise_error(
      Clacky::RuntimeSession::UnsupportedCapability,
      /model selection/
    )
  ensure
    session&.close
  end

  it "maps runtime-native model selection onto the existing session model picker" do
    session = build_session
    runtime = built_runtimes.fetch(0)
    runtime.enable_model_selection("gpt-5.3-codex", "gpt-5.6-sol")

    expect(session.current_model_info).to include(
      model: "gpt-5.3-codex",
      sub_model: "gpt-5.3-codex",
      sub_model_options: ["gpt-5.3-codex", "gpt-5.6-sol"]
    )

    expect(session.set_session_sub_model("gpt-5.6-sol")).to be(true)
    expect(runtime.selected_models).to eq(["gpt-5.6-sol"])
    expect(session.current_model_info).to include(
      model: "gpt-5.6-sol",
      sub_model: "gpt-5.6-sol"
    )
  ensure
    session&.close
  end

  it "replays its normalized local transcript without consulting the provider" do
    session = build_session
    session.history.append(
      role: "user",
      content: "Question",
      created_at: 1.0,
      display_references: [{ "kind" => "session", "id" => "session-2" }]
    )
    session.history.append(
      role: "assistant",
      content: nil,
      tool_calls: [{
        id: "tool-replay",
        type: "function",
        function: { name: "terminal", arguments: '{"command":"pwd"}' }
      }]
    )
    session.history.append(
      role: "tool", tool_call_id: "tool-replay", content: "/workspace"
    )
    session.history.append(role: "assistant", content: "Answer", created_at: 2.0)
    replay_ui = RuntimeSessionSpecUI.new

    result = session.replay_history(replay_ui, limit: 20)

    expect(result).to eq(has_more: false)
    expect(replay_ui.user_messages).to include(
      content: "Question",
      created_at: 1.0,
      files: [],
      references: [{ "kind" => "session", "id" => "session-2" }],
      source: :history
    )
    expect(replay_ui.assistant_messages.last[:content]).to eq("Answer")
    expect(replay_ui.keyed_tool_calls).to eq([
      ["tool-replay", "terminal", { "command" => "pwd" }]
    ])
    expect(replay_ui.keyed_tool_results).to eq([
      ["tool-replay", "/workspace", nil, nil]
    ])
  ensure
    session&.close
  end
end
