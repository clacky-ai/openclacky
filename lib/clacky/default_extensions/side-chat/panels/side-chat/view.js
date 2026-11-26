// ── Official panel: side chat ─────────────────────────────────────────────
//
// A read-only branch of the conversation shown in the right-hand aside. The
// user opens it mid-task to ask about something they did not understand,
// without scrolling to the composer and interrupting the main thread.
//
// The branch itself lives in the openclacky process (see api/runtime.rb): a
// fork_subagent of the session's agent with the write tools denied. This file
// owns only the view, and it rides the main WebSocket — the frames are
// namespaced `ext.side_chat.`, so no second socket is needed.
//
// Rendering reuses the main conversation's vocabulary on purpose: the same
// `.msg` / `.msg-user` / `.msg-assistant` / `.tool-group` classes, the same
// markdown pipeline (Sessions.renderMarkdown), the same composer component
// (ChatComposer). A message has to read the same in both places, and the quote
// chips have to behave the same, which only happens if the DOM does too.
// ─────────────────────────────────────────────────────────────────────────

(() => {
  if (!window.Clacky || !Clacky.ext) return;

  const API_BASE = "/api/ext/side-chat";
  const WS_PREFIX = "ext.side_chat.";
  const SLOT = "session.aside";
  const TAB_ID = "side-chat";
  const STREAM_RENDER_MS = 60;
  const BOTTOM_SLACK = 48;

  const t = (key, fallback, params) => {
    const value = (typeof I18n !== "undefined") ? I18n.t(key, params) : null;
    return (value && value !== key) ? value : fallback;
  };

  const session = () => (window.Clacky && Clacky.ext && Clacky.ext.context && Clacky.ext.context.sessionId) || null;
  const sessionsApi = () => (window.Clacky && Clacky.Sessions) || null;
  const toolViewApi = () => {
    const api = sessionsApi();
    return (api && api.toolView) || null;
  };

  const runtimes = new Map(); // sessionId -> runtime (one branch per session)

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function markdown(text) {
    const api = sessionsApi();
    if (api && typeof api.renderMarkdown === "function") return api.renderMarkdown(text || "");
    const node = el("div");
    node.textContent = text || "";
    return escapeHtml(node.innerHTML);
  }

  function referenceBadges(references) {
    const api = sessionsApi();
    if (!api || typeof api.renderReferenceBadge !== "function") return "";
    return (references || []).map(api.renderReferenceBadge).join(" ");
  }

  function styles() {
    if (document.getElementById("side-chat-ext-css")) return;
    const style = document.createElement("style");
    style.id = "side-chat-ext-css";
    style.textContent = `
      .sidechat { flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column; }
      /* Same scroll container as #messages, sized for a narrow column. */
      .sidechat-body { padding: 0.75rem 0.75rem 0.5rem; gap: 0.5rem; }
      .sidechat-body .msg { max-width: 100%; font-size: 0.85rem; padding: 0.5rem 0.75rem; }
      .sidechat-body .msg-user-wrap { padding-bottom: 0; }
      .sidechat-body .msg p:first-child { margin-top: 0; }
      .sidechat-body .msg p:last-child { margin-bottom: 0; }
      .sidechat-body .tool-group { max-width: 100%; }
      .sidechat-opening { margin: auto; padding: 1.5rem 1rem; text-align: center; font-size: 0.8rem;
                        line-height: 1.6; color: var(--color-text-tertiary); }
      .sidechat-note { font-size: 0.75rem; line-height: 1.5; color: var(--color-text-tertiary);
                       padding: 0 0.25rem; }
      .sidechat-note-error { color: var(--color-danger, #dc2626); }
      .sidechat-foot { flex: none;
                       padding: 0.5rem 0.625rem 0.625rem; display: flex; flex-direction: column; }
      .sidechat-composer { flex: none; }
      /* Taller than one line for a comfortable click target; the padding has to
         absorb the extra height, or the line box sticks to the top of the box
         and any chip in it reads as sitting too high. */
      .sidechat-composer .composer-input { min-height: 2.25rem; padding-top: 0.375rem; padding-bottom: 0.375rem; }
    `;
    document.head.appendChild(style);
  }

  // ── Runtime ──────────────────────────────────────────────────────────────

  function ensureRuntime(sessionId) {
    let rt = runtimes.get(sessionId);
    if (rt) return rt;
    rt = {
      sessionId: sessionId,
      chatId: null,
      status: "idle", // idle | opening | running
      entries: [],
      streaming: null,
      progress: null,
      progressEl: null,
      progressTimer: null,
      notes: [],
      pendingQuotes: [],
      pendingFresh: false,
      forking: false,
      queued: null,
      el: null,
      opening: null,
      renderTimer: null,
      pinBottom: true,
      disposed: false,
    };
    runtimes.set(sessionId, rt);
    bindWs();
    return rt;
  }

  function create(ctx) {
    const sessionId = ctx && ctx.sessionId;
    if (!sessionId) return null;
    const rt = ensureRuntime(sessionId);
    rt.dispose = () => {
      if (rt.disposed) return;
      rt.disposed = true;
      if (rt.renderTimer) { clearTimeout(rt.renderTimer); rt.renderTimer = null; }
      clearProgress(rt);
      if (rt.chatId && window.Clacky && Clacky.WS) {
        Clacky.WS.send({ type: "ext.side_chat.close", chat_id: rt.chatId });
      }
      rt.chatId = null;
      rt.el = null;
      runtimes.delete(sessionId);
    };
    return rt;
  }

  // ── Transport ────────────────────────────────────────────────────────────

  function wsSend(frame) {
    if (!window.Clacky || !Clacky.WS) return;
    Clacky.WS.send(frame);
  }

  function attach(rt) {
    if (!rt.chatId) return;
    wsSend({ type: "ext.side_chat.attach", chat_id: rt.chatId });
  }

  // The socket has no unsubscribe, so the extension subscribes once for the
  // module and routes each frame to the runtime that owns the branch. Binding a
  // handler per runtime would leave a dead closure behind on every session
  // switch, all of them still running their filter on every frame.
  let wsBound = false;
  function bindWs() {
    if (wsBound || !window.Clacky || !Clacky.WS) return;
    wsBound = true;
    Clacky.WS.onEvent(onWsEvent);
  }

  function onWsEvent(event) {
    if (!event || typeof event.type !== "string") return;

    if (event.type === "_ws_connected") {
      // A reconnect loses every panel's binding; the server drops the
      // connection reference with it.
      runtimes.forEach((rt) => { if (!rt.disposed && rt.chatId) attach(rt); });
      return;
    }
    if (!event.type.startsWith(WS_PREFIX)) return;
    runtimes.forEach((rt) => onServerEvent(rt, event));
  }

  // Opens the branch. `fresh` drops the existing one so the panel catches up
  // with the main thread when it has moved on.
  function openChat(rt, options) {
    const fresh = !!(options && options.fresh);
    if (rt.opening) return rt.opening;
    if (rt.chatId && !fresh) {
      attach(rt);
      return Promise.resolve();
    }

    rt.status = "opening";
    if (fresh) rt.forking = true;
    scheduleRender(rt, 0);

    rt.opening = fetch(API_BASE + "/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session_id: rt.sessionId, fresh: fresh }),
    })
      .then((response) => response.json().catch(() => ({})).then((data) => ({ response, data })))
      .then(({ response, data }) => {
        if (!response.ok || !data.chat_id) {
          throw new Error(data.error || ("HTTP " + response.status));
        }
        if (fresh) {
          rt.entries = [];
          rt.streaming = null;
          rt.notes = [];
          rt.pinBottom = true;
          clearProgress(rt);
        }
        rt.chatId = data.chat_id;
        rt.status = "idle";
        attach(rt);
      })
      .catch((error) => {
        rt.status = "idle";
        rt.notes.push({
          kind: "error",
          text: t("sidechat.openFailed", "Could not open the side chat: {{error}}", {
            error: (error && error.message) || String(error),
          }),
        });
      })
      .then(() => {
        rt.opening = null;
        rt.forking = false;
        renderMessages(rt);
        flushQueued(rt);
        if (rt.el && rt.el.composer) rt.el.composer.focus();
      });

    return rt.opening;
  }

  function flushQueued(rt) {
    const queued = rt.queued;
    if (!queued || !rt.chatId) return;
    rt.queued = null;
    queued.forEach((payload) => deliver(rt, payload));
  }

  function deliver(rt, payload) {
    // A quote picked in the main conversation promises nothing until the user
    // actually sends: the old branch is replaced here, not when the quote was
    // clicked, so an abandoned quote leaves the conversation untouched.
    const refork = !!rt.pendingFresh && !!rt.chatId;
    if (refork || rt.forking || !rt.chatId) {
      rt.pendingFresh = false;
      // Queued rather than sent: the new branch does not exist until /open
      // answers, and a second message in that window must join the queue
      // instead of hitting the branch being replaced.
      rt.queued = (rt.queued || []).concat([payload]);
      if (!rt.forking) openChat(rt, { fresh: refork });
      return;
    }
    wsSend({
      type: "ext.side_chat.send",
      chat_id: rt.chatId,
      text: payload.text || "",
      files: payload.files || [],
      references: payload.references || [],
    });
  }

  function onServerEvent(rt, event) {
    if (!event || rt.disposed) return;
    if (typeof event.type !== "string" || !event.type.startsWith(WS_PREFIX)) return;
    if (event.chat_id !== rt.chatId) return;

    switch (event.type.slice(WS_PREFIX.length)) {
      case "attached":
        rt.status = event.running ? "running" : "idle";
        renderMessages(rt);
        break;

      case "user":
        rt.streaming = null;
        // The main conversation force-scrolls on a user message ("user just
        // sent one"); reading history must not hide the question you asked.
        rt.pinBottom = true;
        rt.entries.push({
          kind: "user",
          text: event.text || "",
          references: event.references || [],
          files: event.files || [],
        });
        renderMessages(rt);
        break;

      case "event":
        onAgentEvent(rt, event.event || {});
        break;

      case "turn":
        rt.status = "idle";
        rt.streaming = null;
        clearProgress(rt);
        renderMessages(rt);
        break;

      case "busy":
        rt.status = "running";
        renderMessages(rt);
        break;

      case "gone":
        rt.chatId = null;
        rt.streaming = null;
        rt.status = "idle";
        clearProgress(rt);
        rt.notes.push({ kind: "note", text: t("sidechat.gone", "This side chat expired — open it again to start a new one.") });
        renderMessages(rt);
        break;

      default:
        break;
    }
  }

  function onAgentEvent(rt, event) {
    switch (event.type) {
      case "assistant_message_delta":
        if (!rt.streaming) rt.streaming = { text: "" };
        rt.streaming.text += event.delta || "";
        scheduleRender(rt, STREAM_RENDER_MS);
        break;

      case "assistant_message_stream_end":
        // The final text arrives as `assistant_message`; dropping the preview
        // here keeps the swap from showing the text twice.
        if (rt.streaming) { rt.streaming = null; scheduleRender(rt); }
        break;

      case "assistant_message":
        rt.streaming = null;
        clearProgress(rt);
        if (event.content && String(event.content).trim()) {
          rt.entries.push({ kind: "assistant", text: event.content });
        }
        scheduleRender(rt);
        break;

      case "tool_call":
        rt.entries.push({
          kind: "tool",
          name: event.name || "tool",
          args: event.args,
          summary: event.summary || "",
          state: "running",
          result: null,
          ui: null,
          expanded: false,
        });
        rt.status = "running";
        clearProgress(rt);
        scheduleRender(rt);
        break;

      case "tool_result": {
        const running = lastRunningTool(rt);
        if (running) {
          running.state = "ok";
          running.result = (event.result == null) ? "" : String(event.result);
          running.ui = event.ui || null;
        }
        scheduleRender(rt);
        break;
      }

      case "tool_error":
        rt.notes.push({ kind: "note", text: "⚠ Tool error: " + String(event.error || event.message || "") });
        scheduleRender(rt);
        break;

      case "progress":
        if (event.phase === "active" || event.status === "start") {
          const previous = rt.progress;
          rt.progress = {
            text: event.message || "",
            type: event.progress_type || "thinking",
            metadata: event.metadata || {},
            startedAt: event.started_at || (previous && previous.startedAt) || Date.now(),
            lastChunkAt: Date.now(),
          };
          startProgressTicker(rt);
        } else {
          clearProgress(rt);
        }
        scheduleRender(rt);
        break;

      case "error":
        rt.streaming = null;
        clearProgress(rt);
        rt.notes.push({
          kind: "error",
          text: t("sidechat.failed", "Side chat failed: {{error}}", {
            error: event.message || "",
          }),
        });
        scheduleRender(rt);
        break;

      // info / warning / tool_args: transient chatter that a narrow panel has no
      // room for. The main conversation still shows the full trail.
      default:
        break;
    }
  }

  function lastRunningTool(rt) {
    for (let i = rt.entries.length - 1; i >= 0; i -= 1) {
      const entry = rt.entries[i];
      if (entry.kind === "tool") return entry.state === "running" ? entry : null;
      if (entry.kind === "assistant" || entry.kind === "user") return null;
    }
    return null;
  }

  // ── Progress line ────────────────────────────────────────────────────────
  //
  // Same line the main conversation shows ("思考中… (3s · 120 tok)"): the
  // formatter is borrowed from Sessions rather than reimplemented, so elapsed
  // seconds, token counts and the model's own label read identically in both
  // places instead of drifting apart.

  function progressLine(rt) {
    const p = rt.progress;
    if (!p) return "";
    const api = sessionsApi();
    const label = (api && typeof api._buildDisplayText === "function")
      ? api._buildDisplayText(p.text, p.type, p.metadata)
      : (p.text || t("chat.thinking", "Thinking…"));
    if (api && typeof api._composeProgressLine === "function") {
      return api._composeProgressLine(label, p.startedAt, p.metadata, p.lastChunkAt);
    }
    const secs = Math.floor((Date.now() - p.startedAt) / 1000);
    return secs > 0 ? label.replace(/(?:\.{2,}|…)\s*$/, "") + "… (" + secs + "s)" : label;
  }

  // Only the text of the line ticks, not the whole body: a full render would
  // re-parse every markdown bubble four times a second.
  function startProgressTicker(rt) {
    if (rt.progressTimer) return;
    rt.progressTimer = setInterval(() => {
      const node = rt.progressEl;
      if (!node || !node.isConnected) return;
      node.textContent = progressLine(rt);
    }, 250);
  }

  function clearProgress(rt) {
    if (rt.progressTimer) {
      clearInterval(rt.progressTimer);
      rt.progressTimer = null;
    }
    rt.progress = null;
    rt.progressEl = null;
  }

  // ── Rendering ────────────────────────────────────────────────────────────

  function scheduleRender(rt, delay) {
    if (rt.disposed || !rt.el) return;
    if (rt.renderTimer) return;
    rt.renderTimer = setTimeout(() => {
      rt.renderTimer = null;
      renderMessages(rt);
    }, delay || 16);
  }

  // Status only ever changes together with a render, so the composer's
  // send/stop swap rides along instead of being wired into every event.
  function syncComposer(rt) {
    const composer = rt.el && rt.el.composer;
    if (composer) composer.setRunning(rt.status === "running");
  }

  const nearBottom = (node) => node.scrollHeight - node.scrollTop - node.clientHeight < BOTTOM_SLACK;

  // The host mounts a tab body hidden and flips .active only after render()
  // returns, so on the first pass the body has no height and a scrollTop write
  // is dropped. The intent to stay pinned therefore lives on the runtime, not
  // in one assignment: the resize observer in render() replays it once the
  // panel is actually laid out. A body with no height yet is left alone.
  function scrollToBottom(rt) {
    const body = rt.el && rt.el.body;
    if (body && body.clientHeight > 0) body.scrollTop = body.scrollHeight;
  }

  function renderMessages(rt) {
    const body = rt.el && rt.el.body;
    if (!body) return;
    syncComposer(rt);

    const frag = document.createDocumentFragment();

    if (rt.status === "opening" && !rt.entries.length && !rt.streaming && !rt.notes.length) {
      const opening = el("div", "sidechat-opening");
      opening.textContent = t("sidechat.opening", "Opening…");
      frag.appendChild(opening);
    }

    let index = 0;
    while (index < rt.entries.length) {
      const entry = rt.entries[index];
      if (entry.kind !== "tool") {
        frag.appendChild(renderEntry(entry));
        index += 1;
        continue;
      }
      const run = [];
      while (index < rt.entries.length && rt.entries[index].kind === "tool") {
        run.push(rt.entries[index]);
        index += 1;
      }
      frag.appendChild(renderToolRun(rt, run));
    }

    if (rt.streaming && rt.streaming.text) {
      const bubble = el("div", "msg msg-assistant");
      bubble.innerHTML = markdown(rt.streaming.text);
      frag.appendChild(bubble);
    }

    if (rt.progress) {
      const line = el("div", "progress-msg", progressLine(rt));
      rt.progressEl = line;
      frag.appendChild(line);
    } else {
      rt.progressEl = null;
    }

    rt.notes.forEach((note) => {
      frag.appendChild(el("div", note.kind === "error" ? "sidechat-note sidechat-note-error" : "sidechat-note", note.text));
    });

    body.replaceChildren(frag);
    if (rt.pinBottom) scrollToBottom(rt);
  }

  function renderEntry(entry) {
    if (entry.kind === "user") {
      const wrap = el("div", "msg-user-wrap");
      const bubble = el("div", "msg msg-user");
      const badges = referenceBadges(entry.references);
      // marked appends a newline after the closing tag; the bubble is pre-wrap,
      // so that newline would render as an empty trailing line.
      const text = entry.text ? markdown(entry.text).replace(/\s+$/, "") : "";
      const attachments = (entry.files || []).map((file) =>
        `<span class="msg-pdf-badge"><span class="msg-pdf-badge-info"><span class="msg-pdf-badge-name">${escapeHtml(file.name || "")}</span></span></span>`
      ).join(" ");
      bubble.innerHTML =
        (badges ? badges + (text || attachments ? "<br>" : "") : "") +
        (attachments ? attachments + (text ? "<br>" : "") : "") +
        text;
      wrap.appendChild(bubble);
      return wrap;
    }

    const bubble = el("div", "msg msg-assistant");
    bubble.innerHTML = markdown(entry.text);
    return bubble;
  }

  // One group for a run of consecutive tool calls, built with the main
  // conversation's own helpers (Clacky.Sessions.toolView): same rows, same
  // collapse header, same args pane / diff / stdout. The panel re-renders from
  // `entries` on every frame, so the expanded state travels on the entry
  // instead of the DOM.
  function renderToolRun(rt, run) {
    const api = toolViewApi();
    if (!api) return renderToolPlain(run);

    const group = api.makeGroup();
    const promoted = [];
    run.forEach((entry) => {
      const item = api.addCall(group, entry.name, entry.args, entry.summary);
      if (rt) item.dataset.sidechatIndex = String(rt.entries.indexOf(entry));
      if (entry.state === "ok") {
        api.complete(item, entry.result, { ui: entry.ui });
        if (entry.ui && api.isPromoted && api.isPromoted(entry.ui)) promoted.push(entry.ui);
      }
      if (entry.expanded) api.toggleDetails(item);
    });
    if (run.every((entry) => entry.state !== "running")) api.collapse(group);
    if (run[0].runExpanded) group.classList.add("expanded");
    if (!promoted.length || !api.promoteResult) return group;
    // Cards sit after the run, where the main conversation puts them.
    const out = document.createDocumentFragment();
    out.appendChild(group);
    promoted.forEach((ui) => api.promoteResult(out, ui));
    return out;
  }

  // Only reachable if sessions.js is an older build without the export.
  function renderToolPlain(run) {
    const group = el("div", "tool-group expanded");
    const body = el("div", "tool-group-body");
    run.forEach((entry) => {
      const item = el("div", "tool-item");
      const header = el("div", "tool-item-header");
      header.appendChild(el("span", "tool-item-name", "⚙ " + (entry.summary || entry.name)));
      header.appendChild(el("span", entry.state === "running" ? "tool-item-status running" : "tool-item-status ok",
        entry.state === "running" ? "…" : "✓"));
      item.appendChild(header);
      body.appendChild(item);
    });
    group.appendChild(body);
    return group;
  }

  // ── Panel body ───────────────────────────────────────────────────────────

  function render(container, ctx, runtime) {
    if (!runtime || !container) return undefined;
    const rt = runtime;
    styles();
    container.replaceChildren();

    const root = el("div", "sidechat");
    const body = el("div", "chat-messages-scroll sidechat-body");
    const foot = el("div", "sidechat-foot");
    const composerHost = el("div", "sidechat-composer");
    foot.appendChild(composerHost);
    root.appendChild(body);
    root.appendChild(foot);
    container.appendChild(root);

    rt.el = { root: root, body: body, composerHost: composerHost, composer: null };

    // Reading the user's scroll is the only input: leaving the bottom unpins,
    // returning pins. Every render() below appends to the same body, so the
    // pin has to be re-applied there rather than computed from a DOM that is
    // about to be replaced.
    body.addEventListener("scroll", () => { rt.pinBottom = nearBottom(body); });
    if (typeof ResizeObserver === "function") {
      // Fires when the host reveals the tab (display:none → laid out) and on
      // every width/padding change, which is exactly when a dropped scrollTop
      // can finally be applied.
      const observer = new ResizeObserver(() => { if (rt.pinBottom) scrollToBottom(rt); });
      observer.observe(body);
      rt.el.observer = observer;
    }

    // The main conversation delegates tool-header clicks from #messages; the
    // panel lives outside that node, so it needs its own delegation to open
    // the args / stdout pane.
    body.addEventListener("click", (e) => {
      const groupHeader = e.target.closest && e.target.closest(".tool-group-header");
      if (groupHeader) {
        // The group's own handler already toggled it; remember the choice so
        // the next render does not snap a run the user opened back shut.
        const group = groupHeader.closest(".tool-group");
        const first = group && group.querySelector(".tool-item");
        const entry = first && rt.entries[Number(first.dataset.sidechatIndex)];
        if (entry) entry.runExpanded = group.classList.contains("expanded");
        return;
      }
      const header = e.target.closest && e.target.closest(".tool-item-header.tool-item-expandable");
      if (!header) return;
      e.preventDefault();
      e.stopPropagation();
      const item = header.closest(".tool-item");
      const api = toolViewApi();
      if (api) api.toggleDetails(item);
      const entry = rt.entries[Number(item.dataset.sidechatIndex)];
      if (entry) entry.expanded = item.classList.contains("expanded");
    });

    if (window.Clacky && Clacky.ChatComposer) {
      rt.el.composer = Clacky.ChatComposer.create({
        mount: composerHost,
        slash: false,
        dropZone: composerHost,
        placeholder: () => t("sidechat.placeholder", "Ask about this conversation…"),
        hasExtra: (input) => QuoteSelect.list(input).length > 0,
        onSend: (payload) => sendFromComposer(rt, payload),
        onStop: () => interrupt(rt),
      });
    }

    renderMessages(rt);
    flushQuotes(rt);
    // The branch is forked on the first send, not on open: a panel the user
    // merely looked at must not pin a snapshot of the conversation.
    if (rt.chatId) attach(rt);

    return () => {
      // Leaving the tab keeps the branch alive server-side (it is reaped after
      // an hour idle) but drops this connection's binding.
      if (rt.chatId) wsSend({ type: "ext.side_chat.detach", chat_id: rt.chatId });
      if (rt.el && rt.el.observer) rt.el.observer.disconnect();
      rt.el = null;
    };
  }

  function sendFromComposer(rt, payload) {
    const input = rt.el && rt.el.composer && rt.el.composer.input;
    // Read the quote chips while the composer still holds them: submit() calls
    // onSend before clearing.
    const references = input ? QuoteSelect.toReferences(input) : [];
    deliver(rt, {
      text: (payload && payload.text) || "",
      files: (payload && payload.files) || [],
      references: references,
    });
  }

  function interrupt(rt) {
    if (!rt.chatId) return;
    wsSend({ type: "ext.side_chat.interrupt", chat_id: rt.chatId });
  }

  // Quotes selected in the main conversation land in this composer as chips, so
  // the panel's first question carries the passage the user was looking at.
  function flushQuotes(rt) {
    const input = rt.el && rt.el.composer && rt.el.composer.input;
    if (!input || !input.isConnected || !rt.pendingQuotes.length) return;
    const pending = rt.pendingQuotes;
    rt.pendingQuotes = [];
    pending.forEach((snap) => QuoteSelect.stage(snap, input));
  }

  // ── Entry point for the selection bar ────────────────────────────────────

  function ask(quote) {
    const sessionId = session();
    if (!sessionId) return;
    const rt = ensureRuntime(sessionId);
    if (quote && quote.text) rt.pendingQuotes.push({ role: quote.role, index: quote.index, text: quote.text });
    reveal();
    if (rt.chatId) {
      // A quote picked in the main conversation asks about the thread as it
      // stands now, so the send that follows starts a new branch — that is how
      // a side chat catches up after the main thread has moved on. The reset
      // waits for the send: forking on the click would wipe a conversation the
      // user only meant to look at. Chips already staged in the composer
      // survive either way.
      rt.pendingFresh = true;
    } else {
      rt.entries = [];
      rt.streaming = null;
      rt.notes = [];
      rt.pinBottom = true;
      renderMessages(rt);
    }
    // activateTab paints the body before it returns, so the composer is here by
    // now; when it is not (the slot has nothing to paint), the chip stays
    // pending and lands on the next render instead of spinning on frames.
    flushQuotes(rt);
    if (rt.el && rt.el.composer) rt.el.composer.focus();
  }

  function reveal() {
    const api = window.Clacky && Clacky.Aside;
    if (api && api.open) api.open();
    // The host's activateTab runs the whole paint synchronously, so this either
    // shows the panel now or never: a false return means the slot has nothing
    // registered to paint, and asking again on the next frame asks the same
    // question.
    if (window.Clacky && Clacky.ext) Clacky.ext.activateTab(SLOT, TAB_ID);
  }

  function available() {
    return !!(window.Clacky && Clacky.WS && session());
  }

  Clacky.SideChat = { ask: ask, available: available };

  Clacky.ext.ui.mount(SLOT, { create: create, render: render }, {
    order: 34,
    tab: {
      id: TAB_ID,
      label: () => t("sidechat.tab", "Side chat"),
      icon:
        '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
        '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/><path d="M13 8H7"/><path d="M17 12H7"/></svg>',
    },
  });
})();
