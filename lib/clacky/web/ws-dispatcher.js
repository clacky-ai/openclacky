// ── WS event dispatcher ───────────────────────────────────────────────────
//
// Consumes events emitted by WS (ws.js) and dispatches them to the right
// business module (Sessions, Tasks, Skills, Channels, Settings, Brand, ...).
//
// Kept as a separate file from ws.js on purpose:
//   - ws.js is a pure transport layer (connect / send / subscribe / reconnect)
//   - this file is the application-level router that knows about every
//     business module. Mixing the two would force ws.js to depend on every
//     other module, breaking layering.
//
// Depends on: WS (ws.js), Sessions, Tasks, Skills, Channels, Settings, Brand,
//             Router, I18n, global $ / escapeHtml / showConfirmModal helpers.
// ─────────────────────────────────────────────────────────────────────────
(function() {
  // Guard: restore hash routing only once after initial session_list arrives.
  let _initialRestoreDone = false;

  // ── Phase grouping (folds subagent runs like skill evolution) ───────────
  //
  // Strategy: when a phase_start arrives, we append a foldable card to the
  // outer message stream and push its body onto RenderTarget. Sessions.append*
  // resolves its destination via RenderTarget.current(), so subagent events
  // land inside the card. Infrastructure paths (history fetch, empty-hint,
  // scroll, container clear) read RenderTarget.outer() and stay anchored to
  // the real #messages node — phase activity never pollutes them.
  //
  // The DOM id "messages" is never swapped: external code, CSS, devtools and
  // closures all see a stable identity.
  const RenderTarget = (() => {
    const stack = [];
    return {
      push(el) { stack.push(el); },
      pop()    { return stack.pop(); },
      current(){ return stack[stack.length - 1] || document.getElementById("messages"); },
      outer()  { return document.getElementById("messages"); },
      depth()  { return stack.length; },
    };
  })();
  window.RenderTarget = RenderTarget;

  const _phaseStack = []; // [{ id, kind, card, body, summary }]

  function _activePhase() {
    return _phaseStack[_phaseStack.length - 1] || null;
  }

  function _phaseLabel(kind) {
    const map = {
      skill_evolution: I18n.t ? (I18n.t("phase.skill_evolution") || "Skill evolution") : "Skill evolution",
    };
    return map[kind] || kind;
  }

  function _beginPhase(ev) {
    if (_phaseStack.length > 0) return; // single-level for now

    const outer = RenderTarget.outer();
    if (!outer) return;

    const card = document.createElement("details");
    card.className = "msg-phase";
    card.dataset.phaseId = ev.phase_id;
    card.dataset.phaseKind = ev.kind || "phase";

    const summary = document.createElement("summary");
    summary.className = "msg-phase-summary";
    const labelText = ev.label || _phaseLabel(ev.kind);
    summary.innerHTML = `<span class="msg-phase-icon">🧬</span><span class="msg-phase-label">${escapeHtml(labelText)}</span><span class="msg-phase-status">…</span>`;
    card.appendChild(summary);

    const body = document.createElement("div");
    body.className = "msg-phase-body";
    card.appendChild(body);

    outer.appendChild(card);
    RenderTarget.push(body);

    _phaseStack.push({
      id: ev.phase_id,
      kind: ev.kind,
      card,
      body,
      summary,
    });

    outer.scrollTop = outer.scrollHeight;
  }

  function _endPhase(phaseId, summary) {
    const idx = _phaseStack.findIndex(p => p.id === phaseId);
    if (idx === -1) return;
    while (_phaseStack.length > idx) {
      const phase = _phaseStack.pop();
      RenderTarget.pop();
      _finalizePhase(phase, { summary: phase.id === phaseId ? summary : null });
    }
  }

  function _finalizePhase(phase, { summary, incomplete } = {}) {
    const body = phase.body;
    const isEmpty = !incomplete && body && body.children.length === 0;
    if (isEmpty) phase.card.classList.add("msg-phase-empty");

    const statusEl = phase.summary && phase.summary.querySelector(".msg-phase-status");
    if (statusEl) {
      if (incomplete) {
        statusEl.textContent = " (interrupted)";
        statusEl.classList.add("msg-phase-status-incomplete");
      } else if (isEmpty) {
        const noChange = I18n.t ? (I18n.t("phase.no_changes") || "no changes needed") : "no changes needed";
        statusEl.textContent = ` ✓ ${noChange}`;
      } else if (summary) {
        statusEl.textContent = ` ✓ ${summary}`;
      } else {
        statusEl.textContent = " ✓";
      }
    }
  }

  function _closeAllPhases(reason) {
    while (_phaseStack.length > 0) {
      const phase = _phaseStack.pop();
      RenderTarget.pop();
      _finalizePhase(phase, { incomplete: reason === "incomplete" });
    }
  }

  window._closeAllPhases = _closeAllPhases;


WS.onEvent(ev => {
  // Safety nets:
  // - User just sent a message → any open phase is stale, close it.
  // - Session changed → phase belongs to the previous session, close it.
  if (ev.type === "history_user_message" || ev.type === "subscribed") {
    _closeAllPhases("incomplete");
  }

  switch (ev.type) {

    // ── Phase grouping ─────────────────────────────────────────────────
    case "phase_start": {
      if (ev.session_id !== Sessions.activeId) break;
      _beginPhase(ev);
      break;
    }

    case "phase_end": {
      if (ev.session_id !== Sessions.activeId) break;
      _endPhase(ev.phase_id, ev.summary);
      break;
    }


    // ── Internal WS lifecycle ──────────────────────────────────────────
    case "_ws_connected": {
      const banner = document.getElementById("offline-banner");
      if (banner) banner.style.display = "none";
      const hint = $("ws-disconnect-hint");
      if (hint) hint.style.display = "none";
      break;
    }

    case "_ws_disconnected": {
      const banner = document.getElementById("offline-banner");
      if (banner) {
        banner.textContent = I18n.t("offline.banner");
        banner.style.display = "block";
      }
      // Do NOT force status bar to "idle" here — on a brief WS hiccup the
      // agent may still be running, and reconnect will deliver a fresh
      // session snapshot that patches the real status. Forcing idle here
      // caused stuck UI after reconnect when the snapshot logic wasn't
      // re-asserting status on every reconnect.
      Sessions.clearAllProgress();
      _closeAllPhases("incomplete");
      break;
    }

    // ── Session list ───────────────────────────────────────────────────
    case "session_list": {
      Sessions.setAll(ev.sessions || [], !!ev.has_more, ev.cron_count || 0);
      Sessions.renderList();

      // Restore URL hash once on initial connect; ignore subsequent session_list events.
      // Skip if we are already on a session view (e.g. onboard flow navigated there
      // before WS connected) — restoreFromHash would wrongly redirect to "welcome"
      // because there is no hash set during onboarding.
      if (!_initialRestoreDone) {
        _initialRestoreDone = true;
        if (Router.current !== "session") {
          Router.restoreFromHash();
        }
      } else {
        // If active session was deleted, go to welcome
        if (Sessions.activeId && !Sessions.find(Sessions.activeId)) {
          Router.navigate("welcome");
        }
      }
      break;
    }

    // ── Session lifecycle ──────────────────────────────────────────────
    case "subscribed": {
      // Re-enable send button now that the server has confirmed the subscription.
      $("btn-send").disabled = false;
      $("user-input").focus();
      // If this session was created by Tasks.run(), fire the agent now that
      // we're guaranteed to receive its broadcasts.
      const pendingId = Sessions.takePendingRunTask();
      if (pendingId && pendingId === ev.session_id) {
        WS.send({ type: "run_task", session_id: pendingId });
      }
      // If a slash-command was queued (e.g. /onboard from first-boot flow),
      // send it now — after restoreFromHash has settled — so appendMsg won't be wiped.
      const pendingMsg = Sessions.takePendingMessage();
      if (pendingMsg && pendingMsg.session_id === ev.session_id) {
        Sessions.appendMsg("user", escapeHtml(pendingMsg.content), { time: new Date() });
        WS.send({ type: "message", session_id: pendingMsg.session_id, content: pendingMsg.content, lang: I18n.lang() });
      }
      break;
    }

    case "session_update": {
      // Two shapes arrive under this type:
      //   (1) Full session object from http_server broadcast_session_update:
      //       { type, session: { id, name, status, total_cost, total_tasks, ... } }
      //   (2) Partial real-time update from web_ui_controller (cost/tasks/status):
      //       { type, session_id, cost?, tasks?, status? }
      let sid, patch;
      if (ev.session) {
        // Shape (1): full session — use as-is
        sid   = ev.session.id;
        patch = ev.session;
      } else {
        // Shape (2): partial update — build patch from top-level fields
        sid   = ev.session_id;
        patch = {};
        if (ev.cost    !== undefined) patch.total_cost     = ev.cost;
        if (ev.tasks   !== undefined) patch.total_tasks    = ev.tasks;
        if (ev.status  !== undefined) patch.status         = ev.status;
        // Latency pushed by Agent after each LLM call (see update_sessionbar).
        // Stored under latest_latency — same field name the HTTP /api/sessions
        // list returns, so updateInfoBar doesn't need to branch on the source.
        if (ev.latency !== undefined) patch.latest_latency = ev.latency;
      }
      if (!sid) break;
      Sessions.patch(sid, patch);
      Sessions.renderList();
      if (sid === Sessions.activeId) {
        const current = Sessions.find(sid);
        if (patch.status !== undefined) Sessions.updateStatusBar(patch.status);
        Sessions.updateInfoBar(current);
        // Update chat title/subtitle in case session was renamed or working_dir changed
        Sessions.updateChatHeader(current);
      }
      // When a session finishes, refresh tasks and skills, and clear any progress state
      if (patch.status === "idle") {
        Tasks.load();
        Skills.load();
        // Clear progress state for this session (even if not currently active)
        Sessions.clearProgress(sid);
      }
      break;
    }

    // Transient global signal emitted the moment any agent task finishes
    // (broadcast to every client, not just session subscribers). Used only
    // to play the optional completion chime; the toggle gates it and the
    // module decides whether the user is looking at that session.
    case "task_finished":
      if (typeof Notify !== "undefined") Notify.onTaskFinished(ev.session_id);
      break;

    case "session_renamed": {
      Sessions.patch(ev.session_id, { name: ev.name });
      Sessions.renderList();
      // Title is now shown only in the sidebar; chat-header element was removed.
      break;
    }

    case "session_deleted":
      Sessions.remove(ev.session_id);
      if (ev.session_id === Sessions.activeId) Router.navigate("welcome");
      Sessions.renderList();
      break;

    case "session_restored":
      // A soft-deleted session was restored from the session trash.
      // Insert it back into the local list (idempotent — Sessions.add no-ops
      // if the id already exists) and re-render the sidebar.
      if (ev.session) {
        Sessions.add(ev.session);
        Sessions.renderList();
      }
      break;

    // ── Chat messages ──────────────────────────────────────────────────
    case "history_user_message":
      // Emitted by show_user_message before agent.run; stamp the authoritative
      // created_at onto the optimistically-rendered bubble and register it in
      // the dedup set so the subsequent history fetch skips this round.
      if (ev.session_id === Sessions.activeId && ev.created_at) {
        Sessions.stampLastUserBubble(ev.created_at);
      }
      break;

    case "assistant_message":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendMsg("assistant", ev.content);
      break;

    case "tool_call":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.appendToolCall(ev.name, ev.args, ev.summary);
      break;

    case "tool_result":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendToolResult(ev.result);
      break;

    case "tool_stdout":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendToolStdout(ev.lines);
      break;

    case "tool_error":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendMsg("info", `⚠ Tool error: ${escapeHtml(ev.error)}`);
      break;

    case "token_usage":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.appendTokenUsage(ev);
      break;

    case "progress":
      if (ev.session_id !== Sessions.activeId) break;
      if (ev.phase === "active" || ev.status === "start") {
        const progress_type = ev.progress_type || "thinking";
        const metadata = ev.metadata || {};
        Sessions.showProgress(ev.message, progress_type, metadata, ev.started_at || null);
      } else {
        Sessions.clearProgress(ev.message);
      }
      break;

    case "complete":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
      _closeAllPhases("incomplete"); // safety net: missed phase_end
      {
        const costSource = ev.cost_source;
        const symbol = typeof Billing !== "undefined" ? Billing.getCurrencySymbol() : "$";
        const rawCost = ev.cost || 0;
        const cost = typeof Billing !== "undefined" ? Billing.convertCost(rawCost) : rawCost;
        const costDisplay = (!costSource || costSource === "estimated")
          ? "N/A"
          : `${symbol}${cost.toFixed(4)}`;
        let mainLine = I18n.t("chat.done", { n: ev.iterations, cost: costDisplay });
        if (typeof ev.duration === "number" && ev.duration > 0) {
          mainLine += I18n.t("chat.done.duration", { duration: ev.duration.toFixed(1) });
        }
        let cacheLine = null;
        const cs = ev.cache_stats;
        const total = cs && (cs.total_requests || cs["total_requests"]);
        const hits = cs && (cs.cache_hit_requests || cs["cache_hit_requests"]);
        const cachedTokens = cs && (cs.cache_read_input_tokens || cs["cache_read_input_tokens"]);
        if (total && total > 0 && cachedTokens && cachedTokens > 0) {
          const rate = ((hits / total) * 100).toFixed(1);
          const tokensFmt = cachedTokens >= 1000
            ? `${(cachedTokens / 1000).toFixed(1)}k`
            : `${cachedTokens}`;
          cacheLine = I18n.t("chat.done.cache", {
            rate, hits, total: total, tokens: tokensFmt
          });
        }
        Sessions.appendInfo(`✓ ${mainLine}`, cacheLine);
      }
      if (typeof Share !== "undefined") Share.maybePromptOnComplete();
      break;

    case "request_feedback":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.showFeedbackRequest(ev.question, ev.context, ev.options);
      break;

    case "request_confirmation":
      if (ev.session_id !== Sessions.activeId) break;
      showConfirmModal(ev.id, ev.message);
      break;

    case "interrupted":
      if (ev.session_id !== Sessions.activeId) break;
      Sessions.clearProgress();
      Sessions.collapseToolGroup();
      _closeAllPhases("incomplete");
      Sessions.appendInfo(I18n.t("chat.interrupted"));
      break;

    // ── Info / errors ──────────────────────────────────────────────────
    case "info":
      Sessions.appendInfo(ev.message);
      break;

    case "warning":
      // Optimize retry messages for better UX
      const friendlyWarning = _transformRetryWarning(ev.message);
      if (friendlyWarning) {
        Sessions.appendInfo(friendlyWarning);
      }
      break;

    case "success":
      Sessions.appendMsg("success", "✓ " + escapeHtml(ev.message));
      break;

    case "error":
      if (!ev.session_id || ev.session_id === Sessions.activeId) {
        renderErrorEvent(ev);
      }
      break;
  }
});

// ── Warning transformation ─────────────────────────────────────────────────

function _transformRetryWarning(message) {
  return message;
}

// ── Error rendering ────────────────────────────────────────────────────────

function renderErrorEvent(ev) {
  if (ev.code === "insufficient_credit") {
    const body = escapeHtml(I18n.t("error.insufficient_credit"));
    const action = ev.top_up_url
      ? ` <a href="${escapeHtml(ev.top_up_url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(I18n.t("error.insufficient_credit.action"))} →</a>`
      : "";
    Sessions.appendMsg("error", `<span>${body}${action}</span>`);
    return;
  }
  Sessions.appendMsg("error", escapeHtml(ev.message));
}

window.renderErrorEvent = renderErrorEvent;


})();
