# frozen_string_literal: true

require "clacky/tools/todo_manager"

RSpec.describe Clacky::Tools::TodoManager do
  let(:manager) { described_class.new }
  let(:todos_storage) { [] }

  describe "#execute" do
    context "add action" do
      it "adds a new todo from a string task" do
        result = manager.execute(action: "add", task: "Write unit tests", todos_storage: todos_storage)
        expect(todos_storage.first[:task]).to eq("Write unit tests")
        expect(todos_storage.first[:id]).to eq(1)
        expect(todos_storage.first[:status]).to eq("pending")
      end

      it "increments todo IDs correctly" do
        manager.execute(action: "add", task: "First task", todos_storage: todos_storage)
        manager.execute(action: "add", task: "Second task", todos_storage: todos_storage)
        ids = todos_storage.map { |t| t[:id] }
        expect(ids).to eq([1, 2])
      end

      it "returns error when task is empty string" do
        result = manager.execute(action: "add", task: "", todos_storage: todos_storage)
        expect(result[:error]).to include("required")
      end

      it "returns error when task is nil" do
        result = manager.execute(action: "add", todos_storage: todos_storage)
        expect(result[:error]).to include("required")
      end

      it "auto-clears old completed todos when adding new ones" do
        manager.execute(action: "add", task: "Old task", todos_storage: todos_storage)
        manager.execute(action: "complete", id: 1, todos_storage: todos_storage)
        manager.execute(action: "add", task: "New task", todos_storage: todos_storage)
        expect(todos_storage.length).to eq(1)
        expect(todos_storage.first[:task]).to eq("New task")
      end
    end

    context "list action" do
      it "returns empty list when no todos" do
        result = manager.execute(action: "list", todos_storage: todos_storage)
        expect(result[:todos]).to be_empty
      end

      it "lists all todos" do
        manager.execute(action: "add", task: "Task 1", todos_storage: todos_storage)
        manager.execute(action: "add", task: "Task 2", todos_storage: todos_storage)
        result = manager.execute(action: "list", todos_storage: todos_storage)
        expect(result[:todos].length).to eq(2)
        expect(result[:todos].map { |t| t[:task] }).to eq(["Task 1", "Task 2"])
      end

      it "shows pending and completed counts" do
        manager.execute(action: "add", task: "Task 1", todos_storage: todos_storage)
        manager.execute(action: "add", task: "Task 2", todos_storage: todos_storage)
        manager.execute(action: "complete", id: 1, todos_storage: todos_storage)
        result = manager.execute(action: "list", todos_storage: todos_storage)
        expect(result[:pending_count]).to eq(1)
        expect(result[:completed_count]).to eq(1)
      end
    end

    context "complete action" do
      it "marks a single todo as completed" do
        manager.execute(action: "add", task: "Write unit tests", todos_storage: todos_storage)
        result = manager.execute(action: "complete", id: 1, todos_storage: todos_storage)
        expect(result[:todo][:status]).to eq("completed")
      end

      it "auto-clears all todos when last pending task is completed" do
        manager.execute(action: "add", task: "Only task", todos_storage: todos_storage)
        result = manager.execute(action: "complete", id: 1, todos_storage: todos_storage)
        expect(todos_storage).to be_empty
        expect(result[:all_completed]).to be true
      end

      it "returns message if already completed" do
        manager.execute(action: "add", task: "Task 1", todos_storage: todos_storage)
        manager.execute(action: "add", task: "Task 2", todos_storage: todos_storage)
        manager.execute(action: "complete", id: 1, todos_storage: todos_storage)
        result = manager.execute(action: "complete", id: 1, todos_storage: todos_storage)
        expect(result[:message]).to include("already")
      end

      it "returns error when task not found" do
        result = manager.execute(action: "complete", id: 999, todos_storage: todos_storage)
        expect(result[:error]).to include("not found")
      end

      it "returns error when id is nil" do
        result = manager.execute(action: "complete", todos_storage: todos_storage)
        expect(result[:error]).to include("required")
      end

      it "auto-clears old completed todos when adding new ones" do
        manager.execute(action: "add", task: "Task 1", todos_storage: todos_storage)
        manager.execute(action: "complete", id: 1, todos_storage: todos_storage)
        manager.execute(action: "add", task: "Task 2", todos_storage: todos_storage)
        expect(todos_storage.length).to eq(1)
        expect(todos_storage.first[:task]).to eq("Task 2")
      end
    end

    context "remove action" do
      it "removes a todo" do
        manager.execute(action: "add", task: "Remove me", todos_storage: todos_storage)
        manager.execute(action: "remove", id: 1, todos_storage: todos_storage)
        expect(todos_storage).to be_empty
      end

      it "returns error when task not found" do
        result = manager.execute(action: "remove", id: 999, todos_storage: todos_storage)
        expect(result[:error]).to include("not found")
      end

      it "returns error when id is nil" do
        result = manager.execute(action: "remove", todos_storage: todos_storage)
        expect(result[:error]).to include("required")
      end
    end

    context "clear action" do
      it "clears all todos" do
        manager.execute(action: "add", task: "Task 1", todos_storage: todos_storage)
        manager.execute(action: "add", task: "Task 2", todos_storage: todos_storage)
        result = manager.execute(action: "clear", todos_storage: todos_storage)
        expect(todos_storage).to be_empty
        expect(result[:cleared]).to eq(2)
      end

      it "clears empty list" do
        result = manager.execute(action: "clear", todos_storage: todos_storage)
        expect(todos_storage).to be_empty
        expect(result[:cleared]).to eq(0)
      end
    end

    context "unknown action" do
      it "returns error for unknown action" do
        result = manager.execute(action: "unknown_action", todos_storage: todos_storage)
        expect(result[:error]).to include("Unknown action")
      end
    end
  end

  describe "#format_call" do
    it "formats add with string task" do
      call = manager.format_call({ action: "add", task: "Write tests" })
      expect(call).to eq("TodoManager(add: Write tests)")
    end

    it "formats complete with integer id" do
      call = manager.format_call({ action: "complete", id: 5 })
      expect(call).to eq("TodoManager(complete #5)")
    end

    it "formats remove with integer id" do
      call = manager.format_call({ action: "remove", id: 3 })
      expect(call).to eq("TodoManager(remove #3)")
    end

    it "formats list" do
      call = manager.format_call({ action: "list" })
      expect(call).to eq("TodoManager(list)")
    end

    it "formats clear" do
      call = manager.format_call({ action: "clear" })
      expect(call).to eq("TodoManager(clear all)")
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      func_def = manager.to_function_definition
      expect(func_def[:type]).to eq("function")
      expect(func_def[:function][:name]).to eq("todo_manager")
      expect(func_def[:function][:parameters][:type]).to eq("object")
    end

    it "includes all action types in enum" do
      func_def = manager.to_function_definition
      actions = func_def[:function][:parameters][:properties][:action][:enum]
      expect(actions).to include("add", "list", "complete", "remove", "clear")
    end

    it "exposes task as string type" do
      func_def = manager.to_function_definition
      task_type = func_def[:function][:parameters][:properties][:task][:type]
      expect(task_type).to eq("string")
    end

    it "exposes id as integer type" do
      func_def = manager.to_function_definition
      id_type = func_def[:function][:parameters][:properties][:id][:type]
      expect(id_type).to eq("integer")
    end

    it "no longer exposes legacy `tasks` or `ids` fields" do
      func_def = manager.to_function_definition
      props = func_def[:function][:parameters][:properties]
      expect(props).not_to have_key(:tasks)
      expect(props).not_to have_key(:ids)
    end
  end
end
