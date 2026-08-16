# frozen_string_literal: true

RSpec.describe Clacky::Agent::SkillEvolution do
  # Minimal host class that mixes in the module and exposes the ivars the
  # hooks actually read.
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::SkillEvolution

      attr_accessor :skill_execution_context, :is_subagent, :config, :ui
      attr_reader :reflect_called, :create_called

      def initialize
        @skill_execution_context = nil
        @is_subagent = false
        @config = nil
        @ui = nil
        @reflect_called = 0
        @create_called = 0
      end

      # Stubs for the two hook implementations that normally live in
      # SkillReflector and SkillCreator. We only care about which one runs.
      def maybe_reflect_on_skill
        @reflect_called += 1
      end

      def maybe_create_skill_from_task
        @create_called += 1
      end

      # Stubs for the gating predicates normally provided by SkillReflector /
      # SkillAutoCreator. Default to true so the dispatch tests can assert
      # which branch was reached.
      def should_reflect_on_skill?
        true
      end

      def should_auto_create_skill?
        true
      end
    end
  end

  let(:agent) { agent_class.new }

  let(:phase_recorder) do
    Class.new do
      attr_reader :started, :ended

      def initialize
        @started = []
        @ended = []
      end

      def with_phase; end

      def phase_start(kind:, label:, **)
        @started << { kind: kind, label: label }
        "pid-#{@started.size}"
      end

      def phase_end(pid, summary: nil)
        @ended << { pid: pid, summary: summary }
      end
    end
  end

  describe "#run_skill_evolution_hooks" do
    context "when skill evolution is disabled" do
      it "does nothing" do
        agent.config = double("config", skill_evolution: { enabled: false })
        agent.run_skill_evolution_hooks
        expect(agent.reflect_called).to eq(0)
        expect(agent.create_called).to eq(0)
      end
    end

    context "when running inside a subagent" do
      it "does nothing" do
        agent.is_subagent = true
        agent.run_skill_evolution_hooks
        expect(agent.reflect_called).to eq(0)
        expect(agent.create_called).to eq(0)
      end
    end

    context "when a skill just executed (@skill_execution_context is present)" do
      it "runs reflect only and does NOT run create" do
        agent.skill_execution_context = { skill_name: "pptx", slash_command: true }
        agent.run_skill_evolution_hooks
        expect(agent.reflect_called).to eq(1)
        expect(agent.create_called).to eq(0)
      end
    end

    context "when no skill executed (@skill_execution_context is nil)" do
      it "runs create only and does NOT run reflect" do
        agent.skill_execution_context = nil
        agent.run_skill_evolution_hooks
        expect(agent.reflect_called).to eq(0)
        expect(agent.create_called).to eq(1)
      end
    end

    context "when preconditions are unmet (gating predicates return false)" do
      let(:agent_no_work) do
        Class.new(agent_class) do
          def should_reflect_on_skill?
            false
          end

          def should_auto_create_skill?
            false
          end
        end.new
      end

      it "does not dispatch to either hook" do
        agent_no_work.skill_execution_context = nil
        agent_no_work.run_skill_evolution_hooks
        expect(agent_no_work.reflect_called).to eq(0)
        expect(agent_no_work.create_called).to eq(0)
      end

      it "stays completely silent — no phase is opened at all" do
        ui = phase_recorder.new
        agent_no_work.ui = ui
        agent_no_work.skill_execution_context = nil
        agent_no_work.run_skill_evolution_hooks

        expect(ui.started).to be_empty
        expect(ui.ended).to be_empty
      end
    end

    context "when the evolution runs" do
      it "opens a phase and reports the hook's own summary" do
        ui = phase_recorder.new
        agent.ui = ui
        agent.run_skill_evolution_hooks

        expect(agent.create_called).to eq(1)
        expect(ui.started.size).to eq(1)
        expect(ui.started.first[:kind]).to eq("skill_evolution")
      end

      it "localizes the phase label" do
        expected = {
          "en" => "Reflecting on this task",
          "zh" => "正在复盘本次任务",
        }

        expected.each do |lang, want|
          Thread.current[:lang] = lang
          ui = phase_recorder.new
          agent.ui = ui
          agent.run_skill_evolution_hooks

          expect(ui.started.first[:label]).to eq(want)
        ensure
          Thread.current[:lang] = nil
        end
      end
    end

    context "when there is work to do" do
      it "reports the hook's own summary" do
        ui = phase_recorder.new
        working = Class.new(agent_class) do
          def maybe_create_skill_from_task
            super
            "created bar skill"
          end
        end.new
        working.ui = ui
        working.run_skill_evolution_hooks

        expect(working.create_called).to eq(1)
        expect(ui.ended.first[:summary]).to eq("created bar skill")
      end
    end
  end
end
