# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Clacky::Agent::MemoryUpdater do
  # Create a minimal test class that includes the module
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::MemoryUpdater

      attr_accessor :iterations, :messages, :task_start_iterations

      def initialize
        @iterations = 0
        @task_start_iterations = 0
        @messages = []
      end

      # Stub config with memory update enabled
      def config
        double("config", memory_update_enabled: true)
      end
      alias_method :@config, :config

      def ui
        nil
      end

      # Stub load_memories_meta (normally provided by SkillManager)
      def load_memories_meta
        "(No long-term memories found.)"
      end

      def think; end
      def act(_); end
      def observe(_, _); end
    end
  end

  let(:agent) { agent_class.new }

  describe "#should_update_memory?" do
    context "when iterations are below threshold" do
      it "returns false" do
        agent.iterations = 3
        agent.task_start_iterations = 0
        expect(agent.should_update_memory?).to be false
      end
    end

    context "when iterations meet threshold" do
      it "returns true" do
        agent.iterations = 10
        agent.task_start_iterations = 0
        expect(agent.should_update_memory?).to be true
      end
    end

    context "when task iterations are below threshold even if total is high" do
      it "returns false" do
        agent.iterations = 100
        agent.task_start_iterations = 97  # only 3 task iterations
        expect(agent.should_update_memory?).to be false
      end
    end
  end

  describe "MEMORIES_DIR" do
    it "points to ~/.clacky/memories" do
      expect(Clacky::Agent::MemoryUpdater::MEMORIES_DIR).to eq(
        File.expand_path("~/.clacky/memories")
      )
    end
  end

  describe "#build_memory_update_prompt" do
    # All build_memory_update_prompt tests need a working skill_loader since
    # persist-memory is a built-in skill that must always be present.
    let(:fake_skill) do
      double("skill").tap do |s|
        allow(s).to receive(:process_content).and_return(
          "# Persist Memory Subagent\nSKILL_BODY_MARKER\n4000 characters\n~/.clacky/memories/\n"
        )
      end
    end
    let(:fake_loader) do
      double("skill_loader").tap do |l|
        allow(l).to receive(:find_by_name).with("persist-memory").and_return(fake_skill)
      end
    end

    before do
      agent.instance_variable_set(:@skill_loader, fake_loader)
      allow(agent).to receive(:build_template_context).and_return({})
    end

    it "includes whitelist decision rules and executor manual" do
      agent.iterations = 10
      agent.task_start_iterations = 0
      prompt = agent.send(:build_memory_update_prompt)

      # Decision layer (owned by MemoryUpdater itself)
      expect(prompt).to include("MEMORY UPDATE MODE")
      expect(prompt).to include("Whitelist")
      expect(prompt).to include("No memory updates needed.")

      # Executor manual layer (delegated to persist-memory skill)
      expect(prompt).to include("EXECUTOR MANUAL")
      expect(prompt).to include("~/.clacky/memories/")
      expect(prompt).to include("4000 characters")
    end

    it "embeds the persist-memory skill body via skill.process_content" do
      prompt = agent.send(:build_memory_update_prompt)
      expect(fake_skill).to have_received(:process_content)
        .with(template_context: {})
      expect(prompt).to include("SKILL_BODY_MARKER")
    end

    it "raises when persist-memory skill is missing (built-in must exist)" do
      allow(fake_loader).to receive(:find_by_name).with("persist-memory").and_return(nil)
      expect { agent.send(:build_memory_update_prompt) }
        .to raise_error(/persist-memory skill not found/)
    end
  end

  # Subagent-based memory update tests.
  #
  # Uses a richer agent class that includes stubs for all the Agent-level
  # collaborators the subagent flow touches: fork_subagent, UI progress
  # handles, sessionbar update, cost accounting, debug_logs, and Logger.
  describe "#run_memory_update_subagent" do
    let(:subagent_config) { double("subagent_config", permission_mode: :confirm_edits).tap { |c| allow(c).to receive(:permission_mode=) } }

    let(:subagent_history) { double("subagent_history", to_a: []) }

    let(:subagent_result) { { total_cost_usd: 0.0123, iterations: 2 } }

    let(:subagent) do
      sa = double("subagent", config: subagent_config, history: subagent_history)
      allow(sa).to receive(:instance_variable_get).with(:@config).and_return(subagent_config)
      allow(sa).to receive(:run).and_return(subagent_result)
      sa
    end

    let(:ui) do
      ui = double("ui")
      allow(ui).to receive(:update_sessionbar)
      allow(ui).to receive(:with_phase)
      allow(ui).to receive(:phase_start).and_return("pid-1")
      allow(ui).to receive(:phase_end)
      ui
    end

    let(:config) { double("config", memory_update_enabled: true) }

    let(:full_agent_class) do
      Class.new do
        include Clacky::Agent::CostTracker
        include Clacky::Agent::MemoryUpdater

        attr_accessor :iterations, :task_start_iterations, :total_cost, :cost_source, :debug_logs, :fork_spy

        def initialize(ui:, config:, fork_target:)
          @iterations = 10
          @task_start_iterations = 0
          @total_cost = 1.0
          @cost_mutex = Mutex.new
          @cost_source = :api
          @debug_logs = []
          @ui = ui
          @config = config
          @fork_target = fork_target
          @fork_spy = { called: false, args: nil }
        end

        def fork_subagent(**kwargs)
          @fork_spy[:called] = true
          @fork_spy[:args] = kwargs
          @fork_target
        end

        def load_memories_meta
          "(No long-term memories found.)"
        end
      end
    end

    let(:full_agent) do
      a = full_agent_class.new(ui: ui, config: config, fork_target: subagent)
      # Silence Logger
      allow(Clacky::Logger).to receive(:error)
      # Stub skill_loader + build_template_context so build_memory_update_prompt
      # can load the persist-memory skill body. (persist-memory is a built-in
      # skill — required, never optional.)
      fake_skill = double("persist_memory_skill")
      allow(fake_skill).to receive(:process_content).and_return("EXECUTOR MANUAL BODY")
      fake_loader = double("skill_loader")
      allow(fake_loader).to receive(:find_by_name).with("persist-memory").and_return(fake_skill)
      a.instance_variable_set(:@skill_loader, fake_loader)
      def a.build_template_context; {}; end
      a
    end

    it "does nothing when should_update_memory? is false" do
      full_agent.iterations = 2  # below threshold
      expect(full_agent).not_to receive(:fork_subagent)
      expect(ui).not_to receive(:start_progress)
      full_agent.run_memory_update_subagent
    end

    it "forks subagent with the memory prompt as system_prompt_suffix" do
      full_agent.run_memory_update_subagent

      expect(full_agent.fork_spy[:called]).to be true
      args = full_agent.fork_spy[:args]
      # We intentionally inherit model/tools for cache reuse — no model/forbidden_tools passed.
      expect(args.key?(:model)).to be false
      expect(args.key?(:forbidden_tools)).to be false
      expect(args[:system_prompt_suffix]).to include("MEMORY UPDATE MODE")
    end

    it "runs the subagent with 'Please proceed.' as the task message" do
      expect(subagent).to receive(:run).with("Please proceed.").and_return(subagent_result)
      full_agent.run_memory_update_subagent
    end

    it "forces the subagent's permission_mode to :auto_approve" do
      expect(subagent_config).to receive(:permission_mode=).with(:auto_approve)
      full_agent.run_memory_update_subagent
    end

    it "closes the phase on the normal path" do
      expect(ui).to receive(:phase_end)
      full_agent.run_memory_update_subagent
    end

    it "closes the phase even when the subagent raises" do
      allow(subagent).to receive(:run).and_raise(StandardError, "boom")
      expect(ui).to receive(:phase_end)
      expect { full_agent.run_memory_update_subagent }.not_to raise_error
    end

    it "propagates Clacky::AgentInterrupted and still closes the phase" do
      allow(subagent).to receive(:run).and_raise(Clacky::AgentInterrupted)
      expect(ui).to receive(:phase_end)
      expect { full_agent.run_memory_update_subagent }.to raise_error(Clacky::AgentInterrupted)
    end

    it "swallows non-interrupt errors and logs to debug_logs" do
      allow(subagent).to receive(:run).and_raise(RuntimeError, "something went wrong")
      expect { full_agent.run_memory_update_subagent }.not_to raise_error
      expect(full_agent.debug_logs).not_to be_empty
      last = full_agent.debug_logs.last
      expect(last[:event]).to eq("memory_update_error")
      expect(last[:error_class]).to eq("RuntimeError")
    end

    it "merges subagent cost into @total_cost and updates sessionbar" do
      expect(ui).to receive(:update_sessionbar).with(cost: 1.0 + 0.0123, cost_source: :api)
      full_agent.run_memory_update_subagent
      expect(full_agent.total_cost).to be_within(1e-9).of(1.0123)
    end

    it "reports no summary when subagent wrote nothing" do
      allow(subagent_history).to receive(:to_a).and_return([
        { role: "user", content: "hi" },
        { role: "assistant", content: "No memory updates needed." }
      ])
      expect(ui).to receive(:phase_end).with(anything, summary: nil)
      expect(full_agent.run_memory_update_subagent).to be_nil
    end

    it "reports a summary when subagent called the write tool (OpenAI-style)" do
      allow(subagent_history).to receive(:to_a).and_return([
        {
          role: "assistant",
          tool_calls: [{ function: { name: "write" } }]
        }
      ])
      expect(ui).to receive(:phase_end).with(anything, summary: /steps · \$/)
      expect(full_agent.run_memory_update_subagent).to match(/steps · \$/)
    end

    it "reports a summary when subagent called the edit tool (Anthropic-style tool_use block)" do
      allow(subagent_history).to receive(:to_a).and_return([
        {
          role: "assistant",
          content: [{ type: "tool_use", name: "edit", input: {} }]
        }
      ])
      expect(ui).to receive(:phase_end).with(anything, summary: /steps · \$/)
      expect(full_agent.run_memory_update_subagent).to match(/steps · \$/)
    end
  end
end
