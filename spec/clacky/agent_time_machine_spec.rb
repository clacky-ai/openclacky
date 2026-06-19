# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "Clacky::Agent TimeMachine" do
  let(:client) do
    instance_double(Clacky::Client).tap do |c|
      c.instance_variable_set(:@api_key, "test-api-key")
    end
  end

  let(:config) do
    Clacky::AgentConfig.new(
      model: "gpt-3.5-turbo",
      permission_mode: :auto_approve
    )
  end

  let(:working_dir) { Dir.mktmpdir("clacky_time_machine_test") }
  let(:agent) { Clacky::Agent.new(client, config, working_dir: working_dir, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual) }

  # Helper to get the BEFORE snapshot directory for a task
  def snapshot_dir(task_id)
    File.join(Dir.home, ".clacky", "snapshots", agent.session_id, "task-#{task_id}", "before")
  end

  # Helper to create a file with content
  def create_file(path, content)
    full_path = File.join(working_dir, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end

  # Helper to read file content
  def read_file(path)
    full_path = File.join(working_dir, path)
    File.exist?(full_path) ? File.read(full_path) : nil
  end

  after do
    FileUtils.rm_rf(working_dir)
  end

  describe "initialization" do
    it "initializes time machine state" do
      expect(agent.instance_variable_get(:@task_parents)).to eq({})
      expect(agent.instance_variable_get(:@current_task_id)).to eq(0)
      expect(agent.instance_variable_get(:@active_task_id)).to eq(0)
    end
  end

  describe "#start_new_task" do
    it "creates first task with no parent" do
      agent.start_new_task
      expect(agent.instance_variable_get(:@current_task_id)).to eq(1)
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
      expect(agent.instance_variable_get(:@task_parents)[1]).to eq(0)  # First task has parent 0
    end

    it "creates child task with correct parent" do
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2
      
      task_parents = agent.instance_variable_get(:@task_parents)
      expect(task_parents[2]).to eq(1)
      expect(agent.instance_variable_get(:@current_task_id)).to eq(2)
      expect(agent.instance_variable_get(:@active_task_id)).to eq(2)
    end

    it "creates branching task correctly" do
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2
      agent.switch_to_task(1)  # Go back to task 1
      agent.start_new_task  # Task 3 (branch from task 1)
      
      task_parents = agent.instance_variable_get(:@task_parents)
      expect(task_parents[3]).to eq(1)  # Task 3's parent is task 1
      expect(agent.instance_variable_get(:@current_task_id)).to eq(3)
    end
  end

  describe "#record_file_before_change" do
    it "captures the BEFORE content the first time a task touches a file" do
      create_file("test.txt", "initial content")

      agent.start_new_task
      agent.record_file_before_change(File.join(working_dir, "test.txt"))
      File.write(File.join(working_dir, "test.txt"), "modified content")

      snapshot_path = File.join(snapshot_dir(1), "test.txt")
      expect(File.read(snapshot_path)).to eq("initial content")
    end

    it "keeps the earliest capture when called twice in one task" do
      create_file("test.txt", "v0")

      agent.start_new_task
      agent.record_file_before_change(File.join(working_dir, "test.txt"))
      File.write(File.join(working_dir, "test.txt"), "v1")
      agent.record_file_before_change(File.join(working_dir, "test.txt"))

      expect(File.read(File.join(snapshot_dir(1), "test.txt"))).to eq("v0")
    end

    it "writes an absent marker when the file does not yet exist" do
      agent.start_new_task
      agent.record_file_before_change(File.join(working_dir, "new.txt"))

      marker = File.join(snapshot_dir(1), "new.txt.#{Clacky::Agent::TimeMachine::ABSENT_MARKER}")
      expect(File.exist?(marker)).to be true
    end

    it "handles nested directory paths" do
      create_file("dir/subdir/nested.txt", "nested content")

      agent.start_new_task
      agent.record_file_before_change(File.join(working_dir, "dir/subdir/nested.txt"))

      snapshot_path = File.join(snapshot_dir(1), "dir", "subdir", "nested.txt")
      expect(File.read(snapshot_path)).to eq("nested content")
    end
  end

  # Helper: simulate a task writing a file (record BEFORE, then write).
  def task_write(path, content)
    agent.record_file_before_change(File.join(working_dir, path))
    full = File.join(working_dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  describe "#restore_to_task_state" do
    before do
      # Initial state: file.txt = v0
      create_file("file.txt", "v0")

      agent.start_new_task   # Task 1: v0 -> v1
      task_write("file.txt", "v1")

      agent.start_new_task   # Task 2: v1 -> v2
      task_write("file.txt", "v2")

      agent.start_new_task   # Task 3: v2 -> v3
      task_write("file.txt", "v3")
    end

    it "restores to the state at the end of the target task" do
      expect(read_file("file.txt")).to eq("v3")

      agent.restore_to_task_state(1) # end of task 1 == v1
      expect(read_file("file.txt")).to eq("v1")
    end

    it "restores to the original state (end of task 0)" do
      agent.restore_to_task_state(0)
      expect(read_file("file.txt")).to eq("v0")
    end

    it "restores forward and backward consistently" do
      agent.restore_to_task_state(1)
      expect(read_file("file.txt")).to eq("v1")

      agent.restore_to_task_state(2)
      expect(read_file("file.txt")).to eq("v2")
    end

    it "deletes files created after the target task" do
      agent.start_new_task   # Task 4: create brand new file
      task_write("created.txt", "brand new")
      expect(read_file("created.txt")).to eq("brand new")

      agent.restore_to_task_state(3) # before task 4
      expect(read_file("created.txt")).to be_nil
    end

    it "restores files deleted after the target task" do
      agent.start_new_task   # Task 4: delete file.txt
      agent.record_file_before_change(File.join(working_dir, "file.txt"))
      File.delete(File.join(working_dir, "file.txt"))
      expect(read_file("file.txt")).to be_nil

      agent.restore_to_task_state(3) # before task 4, file existed as v3
      expect(read_file("file.txt")).to eq("v3")
    end
  end

  describe "#undo_last_task" do
    before do
      create_file("file.txt", "v0")
      agent.start_new_task  # Task 1
      task_write("file.txt", "v1")

      agent.start_new_task  # Task 2
      task_write("file.txt", "v2")
    end

    it "undoes to parent task" do
      result = agent.undo_last_task

      expect(result[:success]).to be true
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
      expect(read_file("file.txt")).to eq("v1")
    end

    it "undoes the first task back to the original state" do
      agent.undo_last_task           # -> task 1 (v1)
      result = agent.undo_last_task  # -> task 0 (v0)

      expect(result[:success]).to be true
      expect(agent.instance_variable_get(:@active_task_id)).to eq(0)
      expect(read_file("file.txt")).to eq("v0")
    end

    it "cannot undo from root task" do
      agent.instance_variable_set(:@active_task_id, 0)
      result = agent.undo_last_task

      expect(result[:success]).to be false
      expect(result[:message]).to include("Already at root task")
    end
  end

  describe "#switch_to_task" do
    before do
      create_file("file.txt", "v0")

      agent.start_new_task  # Task 1
      task_write("file.txt", "v1")

      agent.start_new_task  # Task 2
      task_write("file.txt", "v2")

      agent.start_new_task  # Task 3
      task_write("file.txt", "v3")
    end

    it "switches to target task" do
      result = agent.switch_to_task(1)
      
      expect(result[:success]).to be true
      expect(agent.instance_variable_get(:@active_task_id)).to eq(1)
      expect(read_file("file.txt")).to eq("v1")
    end

    it "can switch forward (redo)" do
      agent.switch_to_task(1)
      result = agent.switch_to_task(3)
      
      expect(result[:success]).to be true
      expect(agent.instance_variable_get(:@active_task_id)).to eq(3)
      expect(read_file("file.txt")).to eq("v3")
    end

    it "rejects invalid task ID" do
      result = agent.switch_to_task(99)
      
      expect(result[:success]).to be false
      expect(result[:message]).to include("Invalid task ID")
    end

    it "rejects switching to future task ID" do
      result = agent.switch_to_task(10)
      
      expect(result[:success]).to be false
      expect(result[:message]).to include("Invalid task ID")
    end
  end

  describe "#get_child_tasks" do
    before do
      agent.start_new_task  # Task 1
      agent.start_new_task  # Task 2 (child of 1)
      agent.switch_to_task(1)
      agent.start_new_task  # Task 3 (another child of 1, creates branch)
    end

    it "returns children of a task" do
      children = agent.get_child_tasks(1)
      expect(children).to contain_exactly(2, 3)
    end

    it "returns empty array for leaf task" do
      children = agent.get_child_tasks(2)
      expect(children).to be_empty
    end
  end

  describe "#get_task_history" do
    before do
      # Mock messages to provide summaries
      agent.instance_variable_set(:@messages, [
        { role: "user", content: "First task", task_id: 1 },
        { role: "user", content: "Second task", task_id: 2 },
        { role: "user", content: "Third task", task_id: 3 }
      ])
      
      agent.instance_variable_set(:@current_task_id, 3)
      agent.instance_variable_set(:@active_task_id, 3)
      agent.instance_variable_set(:@task_parents, { 2 => 1, 3 => 2 })
    end

    it "returns task history with metadata" do
      history = agent.get_task_history(limit: 10)
      
      expect(history.length).to eq(3)
      expect(history[0][:task_id]).to eq(1)
      expect(history[2][:task_id]).to eq(3)
      expect(history[2][:status]).to eq(:current)
    end

    it "marks undone (off-chain) tasks correctly after undo" do
      agent.switch_to_task(1)
      history = agent.get_task_history(limit: 10)
      
      task_1 = history.find { |t| t[:task_id] == 1 }
      task_2 = history.find { |t| t[:task_id] == 2 }
      
      expect(task_1[:status]).to eq(:current)
      expect(task_2[:status]).to eq(:undone)
    end

    it "detects branches" do
      # Create a branch
      agent.start_new_task  # Task 4 (child of 3)
      agent.switch_to_task(2)
      agent.start_new_task  # Task 5 (creates branch at task 2)
      
      history = agent.get_task_history(limit: 10)
      task_2 = history.find { |t| t[:task_id] == 2 }
      
      expect(task_2[:has_branches]).to be true
    end

    it "respects limit parameter" do
      10.times { agent.start_new_task }
      history = agent.get_task_history(limit: 5)
      
      expect(history.length).to eq(5)
    end
  end

  describe "#active_messages" do
    before do
      agent.instance_variable_set(:@history, Clacky::MessageHistory.new([
        { role: "user", content: "Task 1", task_id: 1 },
        { role: "assistant", content: "Response 1", task_id: 1 },
        { role: "user", content: "Task 2", task_id: 2 },
        { role: "assistant", content: "Response 2", task_id: 2 },
        { role: "user", content: "Task 3", task_id: 3 },
        { role: "assistant", content: "Response 3", task_id: 3 }
      ]))
      
      agent.instance_variable_set(:@current_task_id, 3)
      agent.instance_variable_set(:@active_task_id, 3)
      agent.instance_variable_set(:@task_parents, { 1 => 0, 2 => 1, 3 => 2 })
    end

    it "returns all messages when at current task" do
      messages = agent.active_messages
      expect(messages.length).to eq(6)
    end

    it "filters messages after undo" do
      agent.instance_variable_set(:@active_task_id, 1)
      messages = agent.active_messages
      
      expect(messages.length).to eq(2)
      # active_messages returns API-ready format (internal fields stripped),
      # so verify content instead of task_id
      expect(messages.last[:content]).to eq("Response 1")
    end

    it "includes system messages without task_id" do
      agent.history.append({ role: "system", content: "You are an AI" })
      # Move the system message to the front by rebuilding history
      all = agent.history.to_a
      system_msg = all.pop
      agent.instance_variable_set(:@history, Clacky::MessageHistory.new([system_msg] + all))
      agent.instance_variable_set(:@active_task_id, 1)
      
      messages = agent.active_messages
      expect(messages.first[:role]).to eq("system")
      expect(messages.length).to eq(3)  # system + 2 messages from task 1
    end

    it "excludes undone sibling-branch turns after a new message forks off the undone point" do
      # User undid to task 1, then sent a new message forking task 4 off task 1.
      # Tasks 2 and 3 are now an abandoned sibling branch and must NOT be sent.
      agent.history.append({ role: "user", content: "Task 4", task_id: 4 })
      agent.history.append({ role: "assistant", content: "Response 4", task_id: 4 })
      agent.instance_variable_set(:@task_parents, { 1 => 0, 2 => 1, 3 => 2, 4 => 1 })
      agent.instance_variable_set(:@current_task_id, 4)
      agent.instance_variable_set(:@active_task_id, 4)

      contents = agent.active_messages.map { |m| m[:content] }
      expect(contents).to eq(["Task 1", "Response 1", "Task 4", "Response 4"])
    end
  end

  describe "integration with session serialization" do
    it "saves time machine state to session" do
      agent.start_new_task
      agent.start_new_task
      
      session_data = agent.to_session_data(status: :success)
      
      expect(session_data[:time_machine]).to be_a(Hash)
      expect(session_data[:time_machine][:task_parents]).to be_a(Hash)
      expect(session_data[:time_machine][:current_task_id]).to eq(2)
      expect(session_data[:time_machine][:active_task_id]).to eq(2)
    end

    it "restores time machine state from session" do
      agent.start_new_task
      agent.start_new_task
      session_data = agent.to_session_data(status: :success)
      
      # Create new agent and restore
      new_agent = Clacky::Agent.new(client, config, working_dir: working_dir, ui: nil, profile: "coding", session_id: Clacky::SessionManager.generate_id, source: :manual)
      new_agent.restore_session(session_data)
      
      expect(new_agent.instance_variable_get(:@current_task_id)).to eq(2)
      expect(new_agent.instance_variable_get(:@active_task_id)).to eq(2)
      expect(new_agent.instance_variable_get(:@task_parents)).to eq(agent.instance_variable_get(:@task_parents))
    end
  end

  describe "file tracking" do
    it "exposes the BEFORE-change recording mechanism" do
      expect(agent).to respond_to(:record_file_before_change)
    end
  end

  describe "branching scenarios" do
    it "handles linear history" do
      agent.start_new_task  # 1
      agent.start_new_task  # 2
      agent.start_new_task  # 3
      
      expect(agent.get_child_tasks(1)).to eq([2])
      expect(agent.get_child_tasks(2)).to eq([3])
      expect(agent.get_child_tasks(3)).to be_empty
    end

    it "handles simple branch" do
      agent.start_new_task  # 1
      agent.start_new_task  # 2
      agent.switch_to_task(1)
      agent.start_new_task  # 3
      
      expect(agent.get_child_tasks(1)).to contain_exactly(2, 3)
    end

    it "handles complex branching tree" do
      agent.start_new_task  # 1
      agent.start_new_task  # 2
      agent.start_new_task  # 3
      agent.switch_to_task(2)
      agent.start_new_task  # 4
      agent.switch_to_task(1)
      agent.start_new_task  # 5
      
      expect(agent.get_child_tasks(1)).to contain_exactly(2, 5)
      expect(agent.get_child_tasks(2)).to contain_exactly(3, 4)
    end
  end
end
