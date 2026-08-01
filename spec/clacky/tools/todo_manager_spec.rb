# frozen_string_literal: true

RSpec.describe Clacky::Tools::TodoManager do
  let(:tool) { described_class.new }

  describe "#execute" do
    describe "add action" do
      it "adds a new todo from a string task" do
        storage = []
        result = tool.execute(action: "add", task: "Write tests", todos_storage: storage)

        expect(result[:message]).to eq("TODO added successfully")
        expect(result[:todos].size).to eq(1)
        expect(result[:todos][0][:id]).to eq(1)
        expect(result[:todos][0][:task]).to eq("Write tests")
        expect(result[:todos][0][:status]).to eq("pending")
        expect(storage.size).to eq(1)
      end

      it "adds multiple todos at once when task is an array" do
        storage = []
        result = tool.execute(
          action: "add",
          task: ["Task 1", "Task 2", "Task 3"],
          todos_storage: storage
        )

        expect(result[:message]).to eq("3 TODOs added successfully")
        expect(result[:todos].size).to eq(3)
        expect(result[:todos][0][:id]).to eq(1)
        expect(result[:todos][1][:id]).to eq(2)
        expect(result[:todos][2][:id]).to eq(3)
        expect(storage.size).to eq(3)
      end

      it "increments todo IDs correctly when adding multiple batches" do
        storage = []
        tool.execute(action: "add", task: "First task", todos_storage: storage)
        result = tool.execute(
          action: "add",
          task: ["Second task", "Third task"],
          todos_storage: storage
        )

        expect(result[:todos][0][:id]).to eq(2)
        expect(result[:todos][1][:id]).to eq(3)
        expect(storage.size).to eq(3)
      end

      it "returns error when task is empty string" do
        storage = []
        result = tool.execute(action: "add", task: "", todos_storage: storage)

        expect(result[:error]).to eq("At least one task description is required")
      end

      it "returns error when task is nil" do
        storage = []
        result = tool.execute(action: "add", todos_storage: storage)

        expect(result[:error]).to eq("At least one task description is required")
      end

      it "returns error when task array is empty" do
        storage = []
        result = tool.execute(action: "add", task: [], todos_storage: storage)

        expect(result[:error]).to eq("At least one task description is required")
      end

      it "filters out empty entries in a task array" do
        storage = []
        result = tool.execute(
          action: "add",
          task: ["Task 1", "", "  ", "Task 2"],
          todos_storage: storage
        )

        expect(result[:todos].size).to eq(2)
        expect(result[:todos][0][:task]).to eq("Task 1")
        expect(result[:todos][1][:task]).to eq("Task 2")
      end

      it "flattens a nested task array into individual todos" do
        # Regression: some models emit task as a nested array
        # (e.g. [["a","b"]]); without flattening the inner array was
        # stringified into one bogus task whose text looks like ["a","b"].
        storage = []
        result = tool.execute(
          action: "add",
          task: [["Task A", "Task B", "Task C"]],
          todos_storage: storage
        )

        expect(result[:todos].size).to eq(3)
        expect(result[:todos].map { |t| t[:task] }).to eq(["Task A", "Task B", "Task C"])
        expect(storage.size).to eq(3)
      end

      it "tolerates unknown extra keyword args (e.g. legacy clients)" do
        storage = []
        # **_extra should swallow these without raising
        result = tool.execute(
          action: "add",
          task: "x",
          tasks: ["ignored"],
          ids: [99],
          todos_storage: storage
        )

        expect(result[:todos].size).to eq(1)
        expect(result[:todos][0][:task]).to eq("x")
      end
    end

    describe "list action" do
      it "returns empty list when no todos" do
        storage = []
        result = tool.execute(action: "list", todos_storage: storage)

        expect(result[:message]).to eq("No TODO items")
        expect(result[:todos]).to eq([])
        expect(result[:total]).to eq(0)
      end

      it "lists all todos" do
        storage = []
        tool.execute(action: "add", task: "Task 1", todos_storage: storage)
        tool.execute(action: "add", task: "Task 2", todos_storage: storage)

        result = tool.execute(action: "list", todos_storage: storage)

        expect(result[:message]).to eq("TODO list")
        expect(result[:todos].size).to eq(2)
        expect(result[:total]).to eq(2)
        expect(result[:pending]).to eq(2)
        expect(result[:completed]).to eq(0)
      end

      it "shows pending and completed counts" do
        storage = []
        tool.execute(action: "add", task: "Task 1", todos_storage: storage)
        tool.execute(action: "add", task: "Task 2", todos_storage: storage)
        tool.execute(action: "complete", id: 1, todos_storage: storage)

        result = tool.execute(action: "list", todos_storage: storage)

        expect(result[:pending]).to eq(1)
        expect(result[:completed]).to eq(1)
      end
    end

    describe "complete action" do
      it "marks a single todo as completed (integer id)" do
        storage = []
        tool.execute(action: "add", task: "Task to complete", todos_storage: storage)
        result = tool.execute(action: "complete", id: 1, todos_storage: storage)

        expect(result[:message]).to eq("Task marked as completed")
        expect(result[:todo][:status]).to eq("completed")
        expect(result[:todo][:completed_at]).not_to be_nil
      end

      it "marks a single todo as completed when id is a single-element array" do
        storage = []
        tool.execute(action: "add", task: ["Task A", "Task B"], todos_storage: storage)
        result = tool.execute(action: "complete", id: [1], todos_storage: storage)

        expect(result[:message]).to eq("Task marked as completed")
        expect(result[:todo][:id]).to eq(1)
      end

      it "batch completes several todos when id is an array" do
        storage = []
        tool.execute(action: "add", task: ["T1", "T2", "T3"], todos_storage: storage)
        result = tool.execute(action: "complete", id: [1, 2], todos_storage: storage)

        expect(result[:message]).to eq("2 task(s) marked as completed")
        expect(result[:completed].size).to eq(2)
        expect(result[:completed].map { |t| t[:id] }).to eq([1, 2])
        expect(result[:progress]).to eq("2/3")
        expect(result[:next_task][:id]).to eq(3)
      end

      it "batch complete reports already-completed and not-found ids separately" do
        storage = []
        tool.execute(action: "add", task: ["T1", "T2"], todos_storage: storage)
        tool.execute(action: "complete", id: 1, todos_storage: storage)
        result = tool.execute(action: "complete", id: [1, 2, 999], todos_storage: storage)

        expect(result[:completed].map { |t| t[:id] }).to eq([2])
        expect(result[:already_completed].map { |t| t[:id] }).to eq([1])
        expect(result[:not_found]).to eq([999])
      end

      it "batch complete auto-clears when all todos are completed" do
        storage = []
        tool.execute(action: "add", task: ["T1", "T2", "T3"], todos_storage: storage)
        result = tool.execute(action: "complete", id: [1, 2, 3], todos_storage: storage)

        expect(result[:all_completed]).to be true
        expect(result[:completion_message]).to eq("All tasks completed and cleared! (3/3)")
        expect(storage).to be_empty
      end

      it "returns message if already completed (single)" do
        storage = []
        tool.execute(action: "add", task: "Task", todos_storage: storage)
        tool.execute(action: "add", task: "Task 2", todos_storage: storage)
        tool.execute(action: "complete", id: 1, todos_storage: storage)
        result = tool.execute(action: "complete", id: 1, todos_storage: storage)

        expect(result[:message]).to eq("Task already completed")
      end

      it "returns error when task not found (single)" do
        storage = []
        result = tool.execute(action: "complete", id: 999, todos_storage: storage)

        expect(result[:error]).to eq("Task not found: 999")
      end

      it "returns error when id is nil" do
        storage = []
        result = tool.execute(action: "complete", todos_storage: storage)

        expect(result[:error]).to eq("Task ID is required")
      end

      it "returns error when id is an empty array" do
        storage = []
        result = tool.execute(action: "complete", id: [], todos_storage: storage)

        expect(result[:error]).to eq("Task ID is required")
      end

      it "auto-clears all todos when last pending task is completed" do
        storage = []
        tool.execute(action: "add", task: ["Task 1", "Task 2"], todos_storage: storage)
        tool.execute(action: "complete", id: 1, todos_storage: storage)
        result = tool.execute(action: "complete", id: 2, todos_storage: storage)

        expect(result[:all_completed]).to be true
        expect(result[:completion_message]).to eq("All tasks completed and cleared! (2/2)")
        expect(storage).to be_empty
      end

      it "auto-clears old completed todos when adding new ones" do
        storage = []
        tool.execute(action: "add", task: ["Old Task 1", "Old Task 2"], todos_storage: storage)
        tool.execute(action: "complete", id: 1, todos_storage: storage)
        # Task 2 still pending, Task 1 completed. Add new task cycle.
        result = tool.execute(action: "add", task: "New Task", todos_storage: storage)

        # Old completed (#1) should be gone, only pending (#2) and new (#3) remain
        expect(storage.size).to eq(2)
        expect(storage.map { |t| t[:id] }).to eq([2, 3])
        expect(storage.all? { |t| t[:status] == "pending" }).to be true
      end
    end

    describe "remove action" do
      it "removes a todo (integer id)" do
        storage = []
        tool.execute(action: "add", task: "Task to remove", todos_storage: storage)
        result = tool.execute(action: "remove", id: 1, todos_storage: storage)

        expect(result[:message]).to eq("Task removed")
        expect(result[:remaining]).to eq(0)
      end

      it "removes a todo when id is a single-element array" do
        storage = []
        tool.execute(action: "add", task: ["a", "b"], todos_storage: storage)
        result = tool.execute(action: "remove", id: [1], todos_storage: storage)

        expect(result[:message]).to eq("Task removed")
        expect(result[:remaining]).to eq(1)
      end

      it "returns error when task not found" do
        storage = []
        result = tool.execute(action: "remove", id: 999, todos_storage: storage)

        expect(result[:error]).to eq("Task not found: 999")
      end

      it "returns error when id is nil" do
        storage = []
        result = tool.execute(action: "remove", todos_storage: storage)

        expect(result[:error]).to eq("Task ID is required")
      end

      it "batch removes multiple todos when id is an array" do
        storage = []
        tool.execute(action: "add", task: ["Task 1", "Task 2", "Task 3", "Task 4"], todos_storage: storage)
        result = tool.execute(action: "remove", id: [1, 3], todos_storage: storage)

        expect(result[:message]).to eq("2 task(s) removed")
        expect(result[:removed].size).to eq(2)
        expect(result[:removed][0][:id]).to eq(1)
        expect(result[:removed][1][:id]).to eq(3)
        expect(result[:remaining]).to eq(2)
        expect(storage.size).to eq(2)
        expect(storage.map { |t| t[:id] }).to eq([2, 4])
      end

      it "handles batch remove with some non-existent IDs" do
        storage = []
        tool.execute(action: "add", task: ["Task 1", "Task 2"], todos_storage: storage)
        result = tool.execute(action: "remove", id: [1, 999, 2, 888], todos_storage: storage)

        expect(result[:message]).to eq("2 task(s) removed")
        expect(result[:removed].size).to eq(2)
        expect(result[:not_found]).to eq([999, 888])
        expect(result[:remaining]).to eq(0)
      end

      it "returns error when id is an empty array" do
        storage = []
        result = tool.execute(action: "remove", id: [], todos_storage: storage)

        expect(result[:error]).to eq("Task ID is required")
      end
    end

    describe "clear action" do
      it "clears all todos" do
        storage = []
        tool.execute(action: "add", task: "Task 1", todos_storage: storage)
        tool.execute(action: "add", task: "Task 2", todos_storage: storage)

        result = tool.execute(action: "clear", todos_storage: storage)

        expect(result[:message]).to eq("All TODOs cleared")
        expect(result[:cleared_count]).to eq(2)
        expect(storage).to be_empty
      end

      it "clears empty list" do
        storage = []
        result = tool.execute(action: "clear", todos_storage: storage)

        expect(result[:message]).to eq("All TODOs cleared")
        expect(result[:cleared_count]).to eq(0)
      end
    end

    describe "unknown action" do
      it "returns error for unknown action" do
        storage = []
        result = tool.execute(action: "invalid_action", todos_storage: storage)

        expect(result[:error]).to eq("Unknown action: invalid_action")
      end
    end
  end

  describe "#format_call" do
    it "formats add with string task" do
      expect(tool.format_call(action: "add", task: "x")).to eq("TodoManager(add 1 task)")
    end

    it "formats add with array task" do
      expect(tool.format_call(action: "add", task: ["a", "b"])).to eq("TodoManager(add 2 tasks)")
    end

    it "formats complete with integer id" do
      expect(tool.format_call(action: "complete", id: 5)).to eq("TodoManager(complete #5)")
    end

    it "formats complete with array id (batch)" do
      expect(tool.format_call(action: "complete", id: [1, 2, 3]))
        .to eq("TodoManager(complete 3 tasks: 1, 2, 3)")
    end

    it "formats complete with single-element array id" do
      expect(tool.format_call(action: "complete", id: [7])).to eq("TodoManager(complete #7)")
    end

    it "formats remove with array id" do
      expect(tool.format_call(action: "remove", id: [4, 5]))
        .to eq("TodoManager(remove 2 tasks: 4, 5)")
    end

    it "formats clear" do
      expect(tool.format_call(action: "clear")).to eq("TodoManager(clear all)")
    end
  end

  describe "#to_function_definition" do
    it "returns OpenAI function calling format" do
      definition = tool.to_function_definition

      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("todo_manager")
      expect(definition[:function][:parameters][:type]).to eq("object")
    end

    it "includes all action types in enum" do
      definition = tool.to_function_definition
      actions = definition[:function][:parameters][:properties][:action][:enum]

      expect(actions).to include("add", "list", "complete", "remove", "clear")
    end

    it "exposes polymorphic task parameter with oneOf string|array" do
      definition = tool.to_function_definition
      task_prop = definition[:function][:parameters][:properties][:task]

      expect(task_prop).to have_key(:oneOf)
      types = task_prop[:oneOf].map { |s| s[:type] }
      expect(types).to contain_exactly("string", "array")
    end

    it "exposes polymorphic id parameter with oneOf integer|array" do
      definition = tool.to_function_definition
      id_prop = definition[:function][:parameters][:properties][:id]

      expect(id_prop).to have_key(:oneOf)
      types = id_prop[:oneOf].map { |s| s[:type] }
      expect(types).to contain_exactly("integer", "array")
    end

    it "no longer exposes legacy `tasks` or `ids` fields" do
      definition = tool.to_function_definition
      props = definition[:function][:parameters][:properties]

      expect(props).not_to have_key(:tasks)
      expect(props).not_to have_key(:ids)
    end
  end
end
