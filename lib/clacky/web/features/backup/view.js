// ── Backup · view — settings rendering, toggles, download/restore UI ──────

const BackupView = (() => {
  const $ = (id) => document.getElementById(id);
  let _restoreStatusEl = null;

  function _fmtDate(iso) {
    if (!iso) return "";
    try { return new Date(iso).toLocaleString(); } catch (e) { return iso; }
  }

  function _render() {
    const cfg    = Backup.state.config;
    const status = Backup.state.status;
    if (!status) return;

    const autoToggle = $("backup-auto-toggle");
    if (autoToggle) autoToggle.checked = !!cfg.enabled;

    const incl = $("backup-include-sessions");
    if (incl) {
      incl.checked  = cfg.include_sessions !== false;
      incl.disabled = !cfg.enabled;
    }

    const destPath = $("backup-dest-path");
    if (destPath) destPath.textContent = status.dest_dir || "—";

    _renderLastRun(cfg);
  }

  function _renderLastRun(cfg) {
    const el = $("backup-status");
    if (!el) return;
    if (!cfg.last_run_at) { el.textContent = ""; el.className = "model-test-result"; return; }
    if (cfg.last_status === "error") {
      el.textContent = I18n.t("settings.backup.lastError", { msg: cfg.last_error || "" });
      el.className = "model-test-result result-fail";
    } else {
      el.textContent = I18n.t("settings.backup.lastOk", { time: _fmtDate(cfg.last_run_at) });
      el.className = "model-test-result result-ok";
    }
  }

  async function _downloadNow() {
    const btn      = $("btn-backup-now");
    const statusEl = $("backup-manual-status");
    const say = (text, cls) => {
      if (!statusEl) return;
      statusEl.textContent = text;
      statusEl.className = cls || "model-test-result";
    };

    if (btn) btn.disabled = true;
    say(I18n.t("settings.backup.running"));

    // Packing happens before the first response byte, so the download
    // progress callback stays silent for the slowest part. Poll instead.
    let downloading = false;
    const packTimer = setInterval(async () => {
      if (downloading) return;
      const p = await Backup.fetchProgress();
      if (!p || !p.packing || !p.total) return;
      const pct = Math.min(99, Math.round((p.done / p.total) * 100));
      say(I18n.t("settings.backup.packingPct", { pct: pct }));
    }, 500);

    const res = await Backup.fetchArchive((loaded, total) => {
      downloading = true;
      const pct = total ? Math.round((loaded / total) * 100) : 0;
      say(I18n.t("settings.backup.downloadingPct", { pct: pct }));
    });
    clearInterval(packTimer);

    if (res.ok) {
      const url = URL.createObjectURL(res.blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = res.filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      say("");
      Modal.toast(I18n.t("settings.backup.downloaded"), "success");
    } else {
      say(I18n.t("settings.backup.lastError", { msg: res.error }), "model-test-result result-fail");
    }
    if (btn) btn.disabled = false;
  }

  async function _restoreBackup(e) {
    const file = e.target.files[0];
    if (!file) return;
    e.target.value = "";

    const statusEl = $("backup-manual-status");
    const say = (text, cls) => {
      if (!statusEl) return;
      statusEl.textContent = text;
      statusEl.className = cls || "model-test-result";
    };

    say(I18n.t("settings.backup.restoring"));

    const res = await Backup.restore(file, (loaded, total) => {
      const pct = total ? Math.round((loaded / total) * 100) : 0;
      say(I18n.t("settings.backup.uploading", { pct: pct }));
    });

    if (res.ok) {
      say(I18n.t("settings.backup.restoreOk"), "model-test-result result-ok");
      _restoreStatusEl = statusEl;
    } else {
      say(res.error || "Restore failed", "model-test-result result-fail");
    }
  }

  function _bind() {
    const btn = $("btn-backup-now");
    if (btn) btn.addEventListener("click", _downloadNow);

    const autoToggle = $("backup-auto-toggle");
    if (autoToggle) autoToggle.addEventListener("change", () => Backup.saveConfig({ enabled: autoToggle.checked }));

    const incl = $("backup-include-sessions");
    if (incl) incl.addEventListener("change", () => Backup.saveConfig({ include_sessions: incl.checked }));

    const openBtn = $("btn-backup-open-folder");
    if (openBtn) openBtn.addEventListener("click", () => Backup.openFolder());

    const restoreInput = $("input-backup-restore");
    if (restoreInput) restoreInput.addEventListener("change", _restoreBackup);
  }

  function _subscribe() {
    Backup.on("backup:changed", _render);
    document.addEventListener("DOMContentLoaded", _bind);
    WS.onEvent(ev => {
      if (ev.type !== "_ws_connected" || !_restoreStatusEl) return;
      const el = _restoreStatusEl;
      _restoreStatusEl = null;
      if (el) { el.textContent = ""; el.className = "model-test-result"; }
      Modal.toast(I18n.t("settings.backup.restartOk"), "success");
      // The backup UI lives on its own page now — refresh it in place instead of
      // bouncing the user into Settings.
      Backup.load();
    });
  }

  const viewApi = {
    onPanelShow() {
      _bind();
      Backup.load();
    },
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Backup, BackupView.api);
BackupView.init();
