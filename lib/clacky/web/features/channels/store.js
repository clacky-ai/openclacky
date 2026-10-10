// ── Channels · store — channel status data + Agent-driven actions ──────────
//
// Channels is an Agent-First panel: no config forms. The store fetches platform
// status and runs "open a session and send a /channel-manager command" actions.
// It never renders — it emits events the view reacts to.
//
// Internal bus always live; Clacky.ext.emit mirrors to the extension bus.
//
// `Channels` stays the single public facade.
//
// Depends on: Sessions, I18n, Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const ChannelsStore = (() => {
  let _channels = [];
  let _statusMessages = true;
  let _processMessages = false;
  let _progressCards = true;

  const _listeners = {};

  function _on(event, handler) {
    (_listeners[event] ||= []).push(handler);
    return () => {
      const list = _listeners[event];
      const i = list ? list.indexOf(handler) : -1;
      if (i >= 0) list.splice(i, 1);
    };
  }

  function _emit(event, payload) {
    (_listeners[event] || []).forEach((h) => h(payload));
    if (window.Clacky && Clacky.ext) Clacky.ext.emit(event, payload);
  }

  const state = {
    get channels() { return _channels; },
    get statusMessages() { return _statusMessages; },
    get processMessages() { return _processMessages; },
    get progressCards() { return _progressCards; },
  };

  // Create a session, register it, queue a command, and navigate to it.
  async function _sendToAgent(command, sessionName) {
    try {
      await Sessions.startWith(command, { name: sessionName });
    } catch (e) {
      alert("Error: " + e.message);
    }
  }

  const Channels = {
    on: _on,
    state,

    /** Fetch channel status; emit so the view re-renders. */
    async load({ silent = false } = {}) {
      if (!silent) _emit("channels:loading");
      try {
        const res  = await fetch("/api/channels");
        const data = await res.json();
        _channels      = data.channels || [];
        _statusMessages = data.status_messages === true;
        _processMessages = data.process_messages === true;
        _progressCards = data.progress_cards !== false;
        _emit("channels:changed", { channels: _channels, status_messages: _statusMessages, process_messages: _processMessages, progress_cards: _progressCards });
      } catch (e) {
        _emit("channels:error", { message: e.message });
      }
    },

    /** Toggle a channel's enabled flag; reload silently on success. */
    async toggle(platform, desired) {
      const res = await fetch(`/api/channels/${encodeURIComponent(platform)}/enabled`, {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ enabled: desired }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "toggle failed");
      await Channels.load({ silent: true });
    },

    /** Toggle the global status messages flag; reload silently on success. */
    async setStatusMessages(desired) {
      const res = await fetch("/api/channels/status_messages", {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ status_messages: desired }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "update failed");
      await Channels.load({ silent: true });
    },

    /** Toggle the global process messages flag; reload silently on success. */
    async setProcessMessages(desired) {
      const res = await fetch("/api/channels/process_messages", {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ process_messages: desired }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "update failed");
      await Channels.load({ silent: true });
    },

    /** Toggle the global progress cards flag; reload silently on success. */
    async setProgressCards(desired) {
      const res = await fetch("/api/channels/progress_cards", {
        method:  "PATCH",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ progress_cards: desired }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "update failed");
      await Channels.load({ silent: true });
    },

    /** Start a QQ QR/link bind task; returns { task_id, connect_url }. */
    async qrStart() {
      const res = await fetch("/api/channels/qq/qr/start", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "failed to start QQ binding");
      return { taskId: data.task_id, connectUrl: data.connect_url };
    },

    /** Poll a QQ bind task; returns status pending|completed|expired. */
    async qrPoll(taskId) {
      const res = await fetch("/api/channels/qq/qr/poll", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ task_id: taskId }),
      });
      const data = await res.json();
      const err  = new Error(data.error || "failed to poll QQ binding");
      err.status = res.status;
      if (!res.ok || !data.ok) throw err;
      return data.status;
    },

    /** Open a session and run the channel doctor / setup commands. */
    runTest(command, name)  { return _sendToAgent(command, name); },
    openSetup(command, name) { return _sendToAgent(command, name); },
    sendToAgent: _sendToAgent,
  };

  return Channels;
})();

const Channels = ChannelsStore;
