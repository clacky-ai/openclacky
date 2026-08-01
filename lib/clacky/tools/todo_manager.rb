# frozen_string_literal: true

require "time"

module Clacky
  module Tools
    class TodoManager < Base
      self.tool_name = "todo_manager"
      self.tool_description = <<~DESC.strip
        Plan and track multi-step tasks. Skip for trivial single-step requests.

        `task` accepts a single string, `id` accepts a single integer.
        For batch operations, call the tool multiple times.

        Only `complete` a todo once it's truly done end-to-end, not per sub-step.
      DESC
      self.tool_category = "task_management"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ["add", "list", "complete", "remove", "clear"],
            description: "add | list | complete | remove | clear"
          },
          task: {
            type: "string",
            description: "add: task description (single string)"
          },
          id: {
            type: "integer",
            description: "complete/remove: task id (single integer)"
          }
        },
        required: ["action"]
      }

      def execute(action:, task: nil, id: nil, todos_storage: nil, working_dir: nil, **_extra)
        # todos_storage is injected by Agent, stores todos in memory
        @todos = todos_storage || []

        case action
        when "add"
          add_todo(task)
        when "list"
          list_todos
        when "complete"
          complete_todo(id)
        when "remove"
          remove_todo(id)
        when "clear"
          clear_todos
        else
          { error: "Unknown action: #{action}" }
        end
      end

      def format_call(args)
        action = args[:action] || args['action']
        case action
        when 'add'
          task_arg = args[:task] || args['task']
          "TodoManager(add: #{task_arg || '(no task)'})"
        when 'complete'
          id_arg = args[:id] || args['id']
          "TodoManager(complete ##{id_arg})"
        when 'list'
          "TodoManager(list)"
        when 'remove'
          id_arg = args[:id] || args['id']
          "TodoManager(remove ##{id_arg})"
        when 'clear'
          "TodoManager(clear all)"
        else
          "TodoManager(#{action})"
        end
      end

      def format_result(result)
        return result[:error] if result[:error]

        if result[:message]
          result[:message]
        else
          "Done"
        end
      end


      def load_todos
        @todos
      end

      def save_todos(todos)
        # Modify the array in-place so Agent's @todos is updated
        # Important: Don't use @todos.clear first because todos might be @todos itself!
        @todos.replace(todos)
      end


      def add_todo(task_input)
        return { error: "Task description is required" } if task_input.nil? || task_input.to_s.strip.empty?

        task_desc = task_input.to_s.strip
        existing_todos = load_todos

        # Auto-clear old completed todos from previous task cycles before adding new ones
        completed_before = existing_todos.count { |t| t[:status] == "completed" }
        if completed_before > 0
          existing_todos.reject! { |t| t[:status] == "completed" }
        end

        next_id = existing_todos.empty? ? 1 : existing_todos.map { |t| t[:id] }.max + 1

        new_todo = {
          id: next_id,
          task: task_desc,
          status: "pending",
          created_at: Time.now.iso8601
        }
        existing_todos << new_todo

        save_todos(existing_todos)

        {
          message: "TODO added successfully",
          todos: [new_todo],
          total: existing_todos.size,
          reminder: "⚠️ IMPORTANT: You have added TODO(s) but have NOT started working yet! You MUST now use other tools (write, edit, shell, etc.) to actually complete these tasks. DO NOT stop here!"
        }
      end

      def list_todos
        todos = load_todos
        if todos.empty?
          { message: "No TODOs found", todos: [] }
        else
          pending = todos.select { |t| t[:status] == "pending" }
          completed = todos.select { |t| t[:status] == "completed" }
          {
            message: "#{todos.size} TODOs (#{pending.size} pending, #{completed.size} completed)",
            todos: todos,
            pending_count: pending.size,
            completed_count: completed.size
          }
        end
      end

      def complete_todo(id_input)
        return { error: "Task ID is required" } if id_input.nil?
        return { error: "Task ID must be a positive integer" } unless id_input.to_s.match?(/\A\d+\z/)

        id = id_input.to_i
        todos = load_todos
        todo = todos.find { |t| t[:id] == id }

        if todo.nil?
          { error: "Task ##{id} not found" }
        elsif todo[:status] == "completed"
          { message: "Task ##{id} is already completed", todo: todo }
        else
          todo[:status] = "completed"
          todo[:completed_at] = Time.now.iso8601
          save_todos(todos)

          pending = todos.select { |t| t[:status] == "pending" }
          completed = todos.select { |t| t[:status] == "completed" }

          result = {
            message: "Task ##{id} marked as completed",
            todo: todo,
            progress: "#{completed.size}/#{todos.size}"
          }

          if pending.empty?
            # All tasks completed — auto-clear
            save_todos([])
            result[:all_completed] = true
            result[:completion_message] = "All tasks completed and cleared! (#{completed.size}/#{todos.size})"
          else
            result[:next_task] = pending.first
            result[:next_task_info] = "Progress: #{completed.size}/#{todos.size}. Next task: ##{pending.first[:id]} - #{pending.first[:task]}"
          end

          result
        end
      end

      def remove_todo(id_input)
        return { error: "Task ID is required" } if id_input.nil?
        return { error: "Task ID must be a positive integer" } unless id_input.to_s.match?(/\A\d+\z/)

        id = id_input.to_i
        todos = load_todos
        todo = todos.find { |t| t[:id] == id }

        if todo.nil?
          { error: "Task ##{id} not found" }
        else
          todos.delete(todo)
          save_todos(todos)
          { message: "Task ##{id} removed", todo: todo, remaining: todos.size }
        end
      end

      def clear_todos
        todos = load_todos
        count = todos.size
        save_todos([])
        { message: "Cleared all #{count} TODOs", cleared: count }
      end
    end
  end
end
