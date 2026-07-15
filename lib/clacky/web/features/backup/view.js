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
      el.className = "model-test-result error";
    } else {
      el.textContent = I18n.t("settings.backup.lastOk", { time: _fmtDate(cfg.last_run_at) });
      el.className = "model-test-result success";
    }
  }

  async function _downloadNow() {
    const btn      = $("btn-backup-now");
    const statusEl = $("backup-manual-status");
    if (btn) btn.disabled = true;
    if (statusEl) { statusEl.textContent = I18n.t("settings.backup.downloading"); statusEl.className = "model-test-result"; }

    const res = await Backup.fetchArchive();
    if (res.ok) {
      const url = URL.createObjectURL(res.blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = res.filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      if (statusEl) { statusEl.textContent = ""; statusEl.className = "model-test-result"; }
      Modal.toast(I18n.t("settings.backup.downloaded"), "success");
    } else if (statusEl) {
      statusEl.textContent = I18n.t("settings.backup.lastError", { msg: res.error });
      statusEl.className = "model-test-result error";
    }
    if (btn) btn.disabled = false;
  }

  async function _restoreBackup(e) {
    const file = e.target.files[0];
    if (!file) return;
    e.target.value = "";

    const statusEl = $("backup-manual-status");
    if (statusEl) { statusEl.textContent = I18n.t("settings.backup.restoring"); statusEl.className = "model-test-result"; }

    const buf = await file.arrayBuffer();
    const res = await Backup.restore(buf);
    if (res.ok) {
      if (statusEl) { statusEl.textContent = I18n.t("settings.backup.restoreOk"); statusEl.className = "model-test-result success"; }
      _restoreStatusEl = statusEl;
    } else {
      if (statusEl) { statusEl.textContent = res.error || "Restore failed"; statusEl.className = "model-test-result error"; }
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
      if (typeof Settings !== "undefined") Settings.open();
    });
  }

  return { init: _subscribe };
})();

BackupView.init();
