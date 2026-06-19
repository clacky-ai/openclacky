// backup.js — Backup settings panel (Settings → General → Backup).
//
// Talks to /api/backup/{status,config,download}. Lets the user toggle automatic
// backups (handled by the server-side Scheduler — fixed daily at 03:00, keeps 7)
// and download a one-off archive directly to the browser.

const Backup = (() => {

  let _status = null;
  let _saving = false;

  async function load() {
    try {
      const res = await fetch("/api/backup/status");
      _status = await res.json();
      _render();
    } catch (e) {
      // Backup section is non-critical; fail quietly.
    }
  }

  function _render() {
    if (!_status) return;
    const cfg = _status.config || {};

    const incl = $("backup-include-sessions");
    if (incl) incl.checked = cfg.include_sessions !== false;

    const autoToggle = $("backup-auto-toggle");
    if (autoToggle) autoToggle.checked = !!cfg.enabled;

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
    const btn = $("btn-backup-now");
    const el = $("backup-status");
    if (btn) btn.disabled = true;
    if (el) { el.textContent = I18n.t("settings.backup.running"); el.className = "model-test-result"; }
    try {
      const res = await fetch("/api/backup/download");
      if (!res.ok) {
        let msg = "failed";
        try { msg = (await res.json()).error || msg; } catch (e) {}
        throw new Error(msg);
      }
      const blob = await res.blob();
      const cd = res.headers.get("Content-Disposition") || "";
      const m = cd.match(/filename="?([^"]+)"?/);
      const name = (m && m[1]) || "clacky-backup.tar.gz";
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      if (el) { el.textContent = I18n.t("settings.backup.downloaded"); el.className = "model-test-result success"; }
    } catch (e) {
      if (el) { el.textContent = I18n.t("settings.backup.lastError", { msg: e.message }); el.className = "model-test-result error"; }
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  async function _saveConfig(patch) {
    if (_saving) return;
    _saving = true;
    try {
      const res = await fetch("/api/backup/config", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patch)
      });
      const data = await res.json();
      if (data.ok) { _status = data.status; _render(); }
    } catch (e) {
      // ignore — next load will resync
    } finally {
      _saving = false;
    }
  }

  function _fmtDate(iso) {
    if (!iso) return "";
    try { return new Date(iso).toLocaleString(); } catch (e) { return iso; }
  }

  function _bind() {
    const btn = $("btn-backup-now");
    if (btn) btn.addEventListener("click", _downloadNow);

    const autoToggle = $("backup-auto-toggle");
    if (autoToggle) autoToggle.addEventListener("change", () => _saveConfig({ enabled: autoToggle.checked }));

    const incl = $("backup-include-sessions");
    if (incl) incl.addEventListener("change", () => _saveConfig({ include_sessions: incl.checked }));
  }

  document.addEventListener("DOMContentLoaded", _bind);

  return { load };
})();

window.Backup = Backup;
