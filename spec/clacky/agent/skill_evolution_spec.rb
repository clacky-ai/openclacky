# frozen_string_literal: true

RSpec.describe Clacky::Agent::SkillEvolution do
  # Minimal host class that mixes in the module and exposes the ivars the
  # hooks actually read.
  let(:agent_class) do
    Class.new do
      include Clacky::Agent::SkillEvolution

      attr_accessor :skill_execution_context, :is_subagent, :config
      attr_reader :reflect_called, :create_called

      def initialize
        @skill_execution_context = nil
        @is_subagent = false
        @config = nil
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

    context "when there is no work to do (gating predicates return false)" do
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

      it "skips dispatch entirely (no banner) by default" do
        agent_no_work.skill_execution_context = nil
        agent_no_work.run_skill_evolution_hooks
        expect(agent_no_work.reflect_called).to eq(0)
        expect(agent_no_work.create_called).to eq(0)
      end

      it "still dispatches when verbose is enabled (so the user sees the no-op)" do
        agent_no_work.config = double("config", verbose: true)
        agent_no_work.skill_execution_context = nil
        agent_no_work.run_skill_evolution_hooks
        # Reaches the dispatch — maybe_create_skill_from_task is called,
        # which in real code would early-return inside should_auto_create_skill?
        expect(agent_no_work.create_called).to eq(1)
      end
    end
  end
end
