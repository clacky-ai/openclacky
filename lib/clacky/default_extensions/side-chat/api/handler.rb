# frozen_string_literal: true

require_relative "runtime"

# Side chat: a read-only branch of the session shown in the right-hand panel.
#
# HTTP opens the branch (it is the only layer that can resolve a session's live
# agent through the registry); the main WebSocket carries the data plane, so the
# branch's own thread can push deltas to the panel that opened it. No second
# socket is needed — the frames are namespaced with `ext.side_chat.`.
class SideChatExtension < Clacky::ApiExtension
  WS_PREFIX = "ext.side_chat."
  RUNTIME = Clacky::Extensions::SideChat::Runtime

  # `fresh: true` drops the existing branch for that session and forks the
  # conversation again — used when the main thread has moved on and the panel's
  # context is stale.
  post "/open" do
    body = json_body
    session_id = body["session_id"].to_s
    error!("session_id is required", status: 400) if session_id.empty?

    parent = parent_agent_for(session_id)
    error!("session not found", status: 404) unless parent

    chat = begin
      RUNTIME.open(parent_id: session_id, parent: parent, fresh: body["fresh"] == true)
    rescue RUNTIME::CapacityError => e
      error!(e.message, status: 429)
    end

    json(chat_id: chat.id)
  end

  post "/close" do
    RUNTIME.close(json_body["chat_id"].to_s)
    json(ok: true)
  end

  # Runs on the WebSocket reader thread: every branch must stay cheap. Forking
  # and running happen in HTTP or in a managed thread, never here.
  def self.on_ws_event(conn, message)
    type = message["type"].to_s
    return false unless type.start_with?(WS_PREFIX)

    chat_id = message["chat_id"].to_s

    case type.delete_prefix(WS_PREFIX)
    when "attach"
      chat = RUNTIME.find(chat_id)
      # A restarted server has no branches; drop the client's stale pane instead
      # of leaving it waiting for events that can never arrive.
      if chat
        chat.attach(conn)
      else
        conn.send_json(type: "ext.side_chat.gone", chat_id: chat_id)
      end
    when "send"
      chat = RUNTIME.find(chat_id)
      if chat.nil?
        conn.send_json(type: "ext.side_chat.gone", chat_id: chat_id)
      elsif chat.ask(text: message["text"], files: message["files"], references: message["references"]) == :busy
        conn.send_json(type: "ext.side_chat.busy", chat_id: chat_id)
      end
    when "interrupt"
      RUNTIME.find(chat_id)&.interrupt
    when "detach"
      RUNTIME.find(chat_id)&.detach(conn)
    when "close"
      RUNTIME.close(chat_id)
    else
      return false
    end
    true
  end

  def self.on_ws_close(conn)
    RUNTIME.detach(conn)
  end

  private def parent_agent_for(session_id)
    reg = registry
    return nil unless reg

    # A session that is on screen but was never restored in this process (e.g.
    # the server restarted) has to be loaded before it can be forked.
    reg.ensure(session_id) unless reg.exist?(session_id)
    reg.get(session_id)&.dig(:agent)
  end
end
