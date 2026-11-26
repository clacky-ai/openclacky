# frozen_string_literal: true

require "securerandom"

require_relative "../../../server/web_ui_controller"

module Clacky
  module Extensions
    module SideChat
      # In-memory pool of read-only conversation branches backing the side chat panel.
      #
      # A side chat is a `fork_subagent` of the session it belongs to: it inherits
      # the whole conversation (including tool traffic), so it can answer questions
      # about what the main window already shows. It never writes into the main
      # conversation, never reaches the session registry and never touches disk —
      # closing the panel (or the process) throws the branch away.
      #
      # This file is loaded once via `require_relative` from handler.rb: the
      # extension loader re-`load`s handler.rb when its mtime changes, and live
      # branches and their threads must survive that reload.
      #
      # Wire format (JSON frames over the main WebSocket):
      #   server → client  ext.side_chat.attached  { chat_id, model, running, cost }
      #                    ext.side_chat.user      { chat_id, text, files, references }
      #                    ext.side_chat.event     { chat_id, event: { type: ..., ... } }
      #                    ext.side_chat.turn      { chat_id, state, cost, iterations, duration }
      #                    ext.side_chat.busy      { chat_id }   # a turn is in flight
      #                    ext.side_chat.gone      { chat_id }
      #   client → server  attach | send | interrupt | detach | close
      class Runtime
        MAX_CHATS = 6
        IDLE_TTL = 60 * 60 # an unattached branch is reaped after this
        MAX_TEXT_CHARS = 16_000
        MAX_REFERENCE_CHARS = 8_000
        MAX_REFERENCES = 12

        # Writing, running commands and asking the user a question all assume the
        # branch owns the task; a read-only branch must not. `todo_manager` and
        # `invoke_skill` mutate shared state (task list, skill evolution).
        FORBIDDEN_TOOLS = %w[
          write edit trash_manager terminal ask_user todo_manager invoke_skill
          browser manage_work delegate_work yield_work
        ].freeze

        # Forwarded to the panel. Everything else a UI controller emits describes
        # chrome the panel does not have (sessionbar, input_queue, complete, …).
        PANEL_EVENTS = %w[
          assistant_message_delta assistant_message_stream_end assistant_message
          tool_call tool_args tool_result tool_error
          progress
          info warning error
        ].freeze

        BRIEF = <<~TEXT.strip
          [SIDE CHAT — READ-ONLY BRANCH]

          You are answering in a side panel attached to the conversation above. The user opened it because something in the main thread needs clarifying and they did not want to scroll down and interrupt the task.

          - Answer their question about the conversation above. Keep it short: the panel is narrow.
          - This branch is read-only. You may read files, search and browse, but you cannot change anything, and nothing you say here reaches the project or the main conversation.
          - Do not continue or advance the main task. If a change is needed, describe it and tell the user to ask for it in the main chat.
        TEXT

        class CapacityError < StandardError; end

        # UI controller for one branch: forwards the interesting events to the
        # panel and bills every model call into the parent session.
        class PanelUI < Clacky::Server::WebUIController
          def initialize(chat_id, broadcaster, billing:)
            super(chat_id, broadcaster)
            @billing = billing
          end

          def show_token_usage(token_data)
            @billing.call(token_data)
            super
          end
        end

        class Chat
          attr_reader :id, :parent_id, :model

          def initialize(parent:, agent:, model:)
            @id = SecureRandom.hex(6)
            @parent = parent
            @agent = agent
            @model = model
            @parent_id = parent.session_id
            @mutex = Mutex.new
            @conn = nil
            @thread = nil
            @running = false
            @closed = false
            @cost = 0.0
            @iterations = 0
            @last_seen = Runtime.now

            @agent.instance_variable_set(:@ui, PanelUI.new(@id, ->(_sid, event) { deliver(event) }, billing: method(:record_spend)))
          end

          def running?
            @mutex.synchronize { @running }
          end

          def cost
            @mutex.synchronize { @cost }
          end

          def attach(conn)
            @mutex.synchronize do
              @conn = conn
              @last_seen = Runtime.now
            end
            conn.send_json(
              type: "ext.side_chat.attached",
              chat_id: @id,
              model: @model,
              running: running?,
              cost: cost.round(6)
            )
          end

          def detach(conn)
            @mutex.synchronize do
              next unless @conn.equal?(conn)
              @conn = nil
              @last_seen = Runtime.now
            end
          end

          def attached?
            @mutex.synchronize { !@conn.nil? }
          end

          def idle_for
            Runtime.now - @mutex.synchronize { @last_seen }
          end

          # @return [Symbol] :started, :busy or :empty
          def ask(text:, files: [], references: [])
            prompt = text.to_s.strip[0, MAX_TEXT_CHARS].to_s
            files = [] unless files.is_a?(Array)
            return :empty if prompt.empty? && files.empty?

            status = @mutex.synchronize do
              if @closed
                :closed
              elsif @running
                :busy
              else
                @running = true
                :ok
              end
            end
            return status unless status == :ok

            refs = normalize_references(references)
            # The turn start is authoritative: the panel paints "running" from
            # this frame instead of guessing at send time, because an `attached`
            # snapshot answered before the send can land after it.
            broadcast(type: "busy")
            broadcast(type: "user", text: prompt, files: files, references: refs)

            @thread = Clacky::ThreadRegistry.spawn(name: "side-chat-#{@id}", daemon: true) do
              run_turn(prompt, files, refs)
            end
            :started
          end

          def interrupt
            thread = @mutex.synchronize { @thread }
            return false unless thread && thread.alive?

            # Same mechanism the server uses for Ctrl+C: `Agent#run` rescues this,
            # marks the run interrupted and re-raises, so our turn thread finishes
            # normally and can report the state to the panel.
            thread.raise(Clacky::AgentInterrupted, "Interrupted by user")
            true
          end

          def shutdown
            @mutex.synchronize { @closed = true }
            interrupt
            @conn = nil
          end

          private def run_turn(prompt, files, refs)
            started = Runtime.now
            result = nil
            state = "done"

            begin
              result = @agent.run(prompt, files: files, reference_contexts: refs)
            rescue Clacky::AgentInterrupted
              state = "interrupted"
            rescue StandardError => e
              state = "error"
              broadcast(type: "event", event: { type: "error", session_id: @id, message: e.message })
            ensure
              # A second interrupt (the user hitting stop again) would otherwise
              # land between the rescue and this call, ending the thread with
              # @running still true — a panel stuck on "stop" for the rest of the
              # branch's life. Deferring delivery for these few statements closes
              # that window; anything still pending arrives after the state is
              # published.
              Thread.handle_interrupt(Clacky::AgentInterrupted => :never) do
                finish_turn(state, result, Runtime.now - started)
              end
            end
          end

          private def finish_turn(state, result, duration)
            iterations = result.is_a?(Hash) ? result[:iterations].to_i : 0
            total = @mutex.synchronize do
              @running = false
              @thread = nil
              @iterations += iterations
              @last_seen = Runtime.now
              @cost
            end
            broadcast(
              type: "turn",
              state: state,
              cost: total.round(6),
              iterations: @iterations,
              duration: duration.round(2)
            )
          end

          # Called from the agent thread for every model call. The fork skips
          # billing on purpose (@is_subagent), so the spend is recorded against
          # the parent session and merged into the parent's running total —
          # otherwise side chat would be free and the sessionbar would lie.
          private def record_spend(token_data)
            cost = token_data[:cost]
            usage = {
              prompt_tokens: token_data[:prompt_tokens].to_i,
              completion_tokens: token_data[:completion_tokens].to_i,
              cache_read_input_tokens: token_data[:cache_read].to_i,
              cache_creation_input_tokens: token_data[:cache_write].to_i
            }
            @mutex.synchronize { @cost += cost.to_f }
            @parent.persist_billing_record(usage, cost, model: @model)
            @parent.absorb_subagent_cost({ total_cost_usd: cost.to_f }, notify_ui: true)
          rescue StandardError => e
            Clacky::Logger.warn("side_chat.billing_error", chat_id: @id, error: e.message)
          end

          private def deliver(event)
            type = event[:type].to_s
            return unless PANEL_EVENTS.include?(type)

            broadcast(type: "event", event: event)
          end

          def broadcast(payload)
            conn = @mutex.synchronize { @conn }
            return unless conn

            conn.send_json(payload.merge(type: "ext.side_chat.#{payload[:type]}", chat_id: @id))
          rescue StandardError => e
            Clacky::Logger.warn("side_chat.send_error", chat_id: @id, error: e.message)
          end

          private def normalize_references(references)
            return [] unless references.is_a?(Array)

            references.first(MAX_REFERENCES).filter_map do |ref|
              next unless ref.is_a?(Hash)
              label = ref[:label] || ref["label"]
              body = (ref[:text] || ref["text"]).to_s.strip[0, MAX_REFERENCE_CHARS]
              next if body.nil? || body.empty?

              { type: "quote", label: label.to_s, text: body, context: context_for(label, body) }
            end
          end

          private def context_for(label, body)
            heading = label.to_s.empty? ? "[Quoted excerpt from this conversation]" :
                                          "[Quoted excerpt from this conversation: #{label}]"
            "#{heading}\n#{body}\n[End of quoted excerpt]"
          end
        end

        class << self
          def open(parent_id:, parent:, model: nil, fresh: false)
            existing = find_by_parent(parent_id)
            return existing if existing && !fresh

            # A fresh open takes over the slot its own parent's branch holds, so
            # the cap only applies when there is nothing of its own to replace.
            check_capacity! unless existing
            register(build(parent: parent, model: model), replace_parent: fresh ? parent_id : nil)
          end

          def find(chat_id)
            id = chat_id.to_s
            return nil if id.empty?

            mutex.synchronize { @chats[id] }
          end

          def find_by_parent(parent_id)
            id = parent_id.to_s
            return nil if id.empty?

            mutex.synchronize { @chats.values.find { |chat| chat.parent_id == id } }
          end

          # Called from the WebSocket reader thread — no locking beyond a swap.
          def close(chat_id)
            chat = mutex.synchronize { @chats.delete(chat_id.to_s) }
            chat&.shutdown
          end

          def detach(conn)
            chats = mutex.synchronize { @chats.values }
            chats.each { |chat| chat.detach(conn) }
          end

          def reset!
            chats = mutex.synchronize do
              list = @chats.values
              @chats = {}
              list
            end
            chats.each(&:shutdown)
          end

          def now
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          private def build(parent:, model:)
            # Forking outside the lock: it deep-copies the whole conversation and
            # must not block the WebSocket reader thread from finding a chat.
            agent = parent.fork_subagent(model: model, forbidden_tools: FORBIDDEN_TOOLS)
            # Same shape append_user_input uses for injected context: the branch
            # reads it, replay and the main conversation never do.
            agent.history.append({ role: "user", content: BRIEF, system_injected: true })

            Chat.new(
              parent: parent,
              agent: agent,
              model: model || parent.config.effective_model_name
            )
          end

          # `build` copies the whole conversation, so forking a chat the cap will
          # refuse wastes that work. `register` re-checks under its own lock,
          # which is what actually enforces the cap — two opens can pass this
          # check together and only one of them will fit.
          private def check_capacity!
            mutex.synchronize do
              sweep_locked
              guard_capacity_locked
            end
          end

          # Replacing the parent's branch happens under the same lock as the
          # insert: closing first and registering afterwards let two concurrent
          # fresh opens leave two branches behind for one session.
          private def register(chat, replace_parent: nil)
            replaced = []
            mutex.synchronize do
              sweep_locked
              if replace_parent
                key = replace_parent.to_s
                @chats.delete_if do |_id, existing|
                  next false unless existing.parent_id == key
                  replaced << existing
                  true
                end
              end
              guard_capacity_locked

              @chats[chat.id] = chat
            end
            replaced.each(&:shutdown)
            chat
          end

          private def guard_capacity_locked
            return if @chats.size < MAX_CHATS

            raise CapacityError, "too many side chats open (max #{MAX_CHATS})"
          end

          private def sweep_locked
            @chats.delete_if do |_id, chat|
              stale = !chat.attached? && chat.idle_for > IDLE_TTL
              chat.shutdown if stale
              stale
            end
          end

          private def mutex
            @mutex ||= Mutex.new
          end

          def chats
            mutex.synchronize { @chats.values }
          end
        end

        @chats = {}
        @mutex = Mutex.new
      end
    end
  end
end
