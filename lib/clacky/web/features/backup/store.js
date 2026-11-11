// ── Backup · store — backup status/config + network ───────────────────────
//
// Owns the backup status/config state and the network calls to
// /api/backup/{status,config,download}. It never renders.
//
// `Backup` stays the single public facade.
//
// Depends on: Clacky.ext.
// ───────────────────────────────────────────────────────────────────────────

const BackupStore = (() => {
  let _status = null;
  let _saving = false;

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
    get status() { return _status; },
    get config() { return (_status && _status.config) || {}; },
  };

  const Backup = {
    on: _on,
    state,

    async load() {
      try {
        const res = await fetch("/api/backup/status");
        _status = await res.json();
        _emit("backup:changed");
      } catch (e) {
        // Backup section is non-critical; fail quietly.
      }
    },

    async saveConfig(patch) {
      if (_saving) return { ok: false };
      _saving = true;
      try {
        const res = await fetch("/api/backup/config", {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(patch)
        });
        const data = await res.json();
        if (data.ok) { _status = data.status; _emit("backup:changed"); }
        return data;
      } catch (e) {
        return { ok: false, error: e.message };
      } finally {
        _saving = false;
      }
    },

    async openFolder() {
      try {
        await fetch("/api/backup/open-folder", { method: "POST" });
      } catch (e) {
        // Non-critical, fail quietly.
      }
    },

    /**
     * Upload a tar.gz archive to restore ~/.clacky. Returns { ok, error }.
     *
     * The File goes to XHR untouched so the browser streams it off disk.
     * Reading it into an ArrayBuffer first keeps a second full copy in the
     * web process, which is what kills multi-hundred-MB restores.
     */
    restore(file, onProgress) {
      return new Promise((resolve) => {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", "/api/backup/restore");
        xhr.setRequestHeader("Content-Type", "application/octet-stream");
        xhr.upload.onprogress = (e) => {
          if (onProgress && e.lengthComputable) onProgress(e.loaded, e.total);
        };
        xhr.onload = () => {
          let data = {};
          try { data = JSON.parse(xhr.responseText); } catch (e) {}
          if (xhr.status >= 200 && xhr.status < 300) resolve({ ok: true });
          else resolve({ ok: false, error: data.error || `Restore failed (HTTP ${xhr.status})` });
        };
        xhr.onerror = () => resolve({ ok: false, error: "Network error" });
        xhr.send(file);
      });
    },

    /** Progress of the archive being packed, or { packing: false }. */
    async fetchProgress() {
      try {
        const res = await fetch("/api/backup/progress");
        if (!res.ok) return { packing: false };
        return await res.json();
      } catch (e) {
        return { packing: false };
      }
    },

    /**
     * Fetch a one-off archive. Returns { ok, blob, filename, error }.
     *
     * XHR instead of fetch because only XHR reports download progress; the
     * server sends a Content-Length, so `lengthComputable` is true.
     */
    fetchArchive(onProgress) {
      return new Promise((resolve) => {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", "/api/backup/download");
        xhr.responseType = "blob";
        xhr.onprogress = (e) => {
          if (onProgress && e.lengthComputable) onProgress(e.loaded, e.total);
        };
        xhr.onload = async () => {
          const cd = xhr.getResponseHeader("Content-Disposition") || "";
          const m  = cd.match(/filename="?([^"]+)"?/);
          const filename = (m && m[1]) || "clacky-backup.tar.gz";
          if (xhr.status >= 200 && xhr.status < 300) {
            resolve({ ok: true, blob: xhr.response, filename });
            return;
          }
          let msg = `Backup failed (HTTP ${xhr.status})`;
          try {
            const body = JSON.parse(await xhr.response.text());
            msg = body.error || msg;
          } catch (e) {}
          resolve({ ok: false, error: msg });
        };
        xhr.onerror = () => resolve({ ok: false, error: "Network error" });
        xhr.send();
      });
    },
  };

  return Backup;
})();

const Backup = BackupStore;
Clacky.Backup = Backup;
