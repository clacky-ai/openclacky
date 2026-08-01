# frozen_string_literal: true

require "json"
require "time"

module Clacky
  module Tools
    class TodoManager < Base
      self.tool_name = "todo_manager"
      self.tool_description = <<~DESC.strip
        Plan and track multi-step tasks. Skip for trivial single-step requests.

        `task` and `id` accept a single value OR an array — always batch when you can
        (e.g. `complete id:[1,2,3]` in one call, not three).

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
            description: "add: task description(s). Accepts a string OR an array of strings for batch add.",
            oneOf: [
              { type: "string" },
              { type: "array", items: { type: "string" } }
            ]
          },
          id: {
            description: "complete/remove: task id(s). Accepts an integer OR an array of integers for batch ops.",
            oneOf: [
              { type: "integer" },
              { type: "array", items: { type: "integer" } }
            ]
          }
        },
        required: ["action"]
      }

      def execute(action:, task: nil, id: nil, todos_storage: nil, working_dir: nil, **_extra)
        # todos_storage is injected by Agent, stores todos in memory
        @todos = todos_storage || []

        # Normalize polymorphic inputs: callers may pass scalar or array for
        # `task` and `id`. We coerce both into arrays internally.
        tasks_input = normalize_to_array(task)
        ids_input   = normalize_to_array(id)

        case action
        when "add"
          add_todos(tasks_input)
        when "list"
          list_todos
        when "complete"
          if ids_input.size > 1
            complete_todos(ids_input)
          else
            complete_todo(ids_input.first)
          end
        when "remove"
          if ids_input.size > 1
            remove_todos(ids_input)
          else
            remove_todo(ids_input.first)
          end
        when "clear"
          clear_todos
        else
          { error: "Unknown action: #{action}" }
        end
      end

      # Coerce scalar/array/nil into an Array. Filters nil entries.
      private def normalize_to_array(value)
        return [] if value.nil?
        Array(value).reject(&:nil?)
      end

      def format_call(args)
        action = args[:action] || args['action']
        case action
        when 'add'
          task_arg = args[:task] || args['task']
          count = task_arg.is_a?(Array) ? task_arg.size : 1
          "TodoManager(add #{count} task#{count > 1 ? 's' : ''})"
        when 'complete'
          id_arg = args[:id] || args['id']
          if id_arg.is_a?(Array) && id_arg.size > 1
            "TodoManager(complete #{id_arg.size} tasks: #{id_arg.join(', ')})"
          else
            single = id_arg.is_a?(Array) ? id_arg.first : id_arg
            "TodoManager(complete ##{single})"
          end
        when 'list'
          "TodoManager(list)"
        when 'remove'
          id_arg = args[:id] || args['id']
          if id_arg.is_a?(Array) && id_arg.size > 1
            "TodoManager(remove #{id_arg.size} tasks: #{id_arg.join(', ')})"
          else
            single = id_arg.is_a?(Array) ? id_arg.first : id_arg
            "TodoManager(remove ##{single})"
          end
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

      def add_todos(tasks_input)
        # tasks_input is already a normalized array (possibly empty).
        # Flatten guards against nested arrays (e.g. [["a","b"]]) that some
        # models emit — without this the inner array would be stringified into
        # a single bogus task whose text looks like ["a","b"].
        tasks_to_add = Array(tasks_input)
                       .flatten
                       .map { |t| t.is_a?(String) ? t.strip : t.to_s.strip }
                       .reject(&:empty?)

        return { error: "At least one task description is required" } if tasks_to_add.empty?

        existing_todos = load_todos

        # Auto-clear old completed todos from previous task cycles before adding new ones
        completed_before = existing_todos.count { |t| t[:status] == "completed" }
        if completed_before > 0
          existing_todos.reject! { |t| t[:status] == "completed" }
        end

        next_id = existing_todos.empty? ? 1 : existing_todos.map { |t| t[:id] }.max + 1

        added_todos = []
        tasks_to_add.each_with_index do |task_desc, index|
          new_todo = {
            id: next_id + index,
            task: task_desc,
            status: "pending",
            created_at: Time.now.iso8601
          }
          existing_todos << new_todo
          added_todos << new_todo
        end

        save_todos(existing_todos)

        {
          message: added_todos.size == 1 ? "TODO added successfully" : "#{added_todos.size} TODOs added successfully",
          todos: added_todos,
          total: existing_todos.size,
          reminder: "⚠️ IMPORTANT: You have added TODO(s) but have NOT started working yet! You MUST now use other tools (write, edit, shell, etc.) to actually complete these tasks. DO NOT stop here!"
        }
      end

      def list_todos
        todos = load_todos

        if todos.empty?
          return {
            message: "No TODO items",
            todos: [],
            total: 0
          }
        end

        {
          message: "TODO list",
          todos: todos,
          total: todos.size,
          pending: todos.count { |t| t[:status] == "pending" },
          completed: todos.count { |t| t[:status] == "completed" }
        }
      end

      def complete_todo(id)
        return { error: "Task ID is required" } if id.nil?

        todos = load_todos
        todo = todos.find { |t| t[:id] == id }

        return { error: "Task not found: #{id}" } unless todo

        if todo[:status] == "completed"
          return { message: "Task already completed", todo: todo }
        end

        todo[:status] = "completed"
        todo[:completed_at] = Time.now.iso8601
        save_todos(todos)

        # Find the next pending task
        next_pending = todos.find { |t| t[:status] == "pending" }
        
        # Count statistics
        completed_count = todos.count { |t| t[:status] == "completed" }
        total_count = todos.size

        result = {
          message: "Task marked as completed",
          todo: todo,
          progress: "#{completed_count}/#{total_count}",
          reminder: "⚠️ REMINDER: Check the PROJECT-SPECIFIC RULES section in your system prompt before continuing to the next task"
        }

        if next_pending
          result[:next_task] = next_pending
          result[:next_task_info] = "Progress: #{completed_count}/#{total_count}. Next task: ##{next_pending[:id]} - #{next_pending[:task]}"
        else
          # All tasks completed — auto-clear so the agent doesn't need to call clear manually
          save_todos([])
          result[:all_completed] = true
          result[:completion_message] = "All tasks completed and cleared! (#{completed_count}/#{total_count})"
        end

        result
      end

      def remove_todo(id)
        return { error: "Task ID is required" } if id.nil?

        todos = load_todos
        todo = todos.find { |t| t[:id] == id }

        return { error: "Task not found: #{id}" } unless todo

        todos.reject! { |t| t[:id] == id }
        save_todos(todos)

        {
          message: "Task removed",
          todo: todo,
          remaining: todos.size
        }
      end

      def clear_todos
        todos = load_todos
        count = todos.size

        # Clear the in-memory storage
        save_todos([])

        {
          message: "All TODOs cleared",
          cleared_count: count
        }
      end

      def remove_todos(ids)
        return { error: "Task IDs array is required" } if ids.nil? || ids.empty?

        todos = load_todos
        removed_todos = []
        not_found_ids = []

        ids.each do |id|
          todo = todos.find { |t| t[:id] == id }
          if todo
            removed_todos << todo
          else
            not_found_ids << id
          end
        end

        # Remove all found todos
        todos.reject! { |t| ids.include?(t[:id]) }
        save_todos(todos)

        result = {
          message: "#{removed_todos.size} task(s) removed",
          removed: removed_todos,
          remaining: todos.size
        }

        # Add warning about not found IDs
        result[:not_found] = not_found_ids unless not_found_ids.empty?

        result
      end

      # Mark several tasks completed in one call.
      # Behavior mirrors `complete_todo` but aggregates over `ids`.
      # Tolerates already-completed and not-found ids (returned in result).
      def complete_todos(ids)
        return { error: "Task IDs array is required" } if ids.nil? || ids.empty?

        todos = load_todos
        now = Time.now.iso8601
        completed_now = []
        already_completed = []
        not_found = []

        ids.each do |id|
          todo = todos.find { |t| t[:id] == id }
          if todo.nil?
            not_found << id
          elsif todo[:status] == "completed"
            already_completed << todo
          else
            todo[:status] = "completed"
            todo[:completed_at] = now
            completed_now << todo
          end
        end

        save_todos(todos)

        completed_count = todos.count { |t| t[:status] == "completed" }
        total_count    = todos.size
        next_pending   = todos.find { |t| t[:status] == "pending" }

        result = {
          message: "#{completed_now.size} task(s) marked as completed",
          completed: completed_now,
          progress: "#{completed_count}/#{total_count}"
        }

        result[:already_completed] = already_completed unless already_completed.empty?
        result[:not_found]         = not_found          unless not_found.empty?

        if next_pending
          result[:next_task] = next_pending
          result[:next_task_info] =
            "Progress: #{completed_count}/#{total_count}. " \
            "Next task: ##{next_pending[:id]} - #{next_pending[:task]}"
        else
          # All tasks completed — auto-clear to match single-complete behavior
          save_todos([])
          result[:all_completed] = true
          result[:completion_message] =
            "All tasks completed and cleared! (#{completed_count}/#{total_count})"
        end

        result
      end
    end
  end
end
