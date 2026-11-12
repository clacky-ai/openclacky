// ── sidebar.js — Left sidebar navigation ──────────────────────────────────
//
// Owns ONLY the left-rail navigation buttons whose sole job is to switch
// the main router view. Any "business action" button that happens to live
// in the sidebar (e.g. "new session") belongs to its own domain module
// (Sessions, Skills, …), not here.
//
// It also owns the collapsible section headers (Config / My Data), which
// mirror the Projects section behaviour: click the title to fold the group,
// and the folded state survives a reload.
//
// The "Data" rail entry opens the data-management page (archive / recycle
// bin / backup tabs). It routes to the archive tab — the page's default —
// and the tab bar takes over from there.
//
// Contract:
//   Sidebar.init() — attach click handlers. Must be called after DOM ready.
// ──────────────────────────────────────────────────────────────────────────

const Sidebar = (() => {
  const COLLAPSE_KEY = "clacky-sidebar-collapsed-sections";
  const SETTINGS_TIP_KEY = "clacky-settings-tip-dismissed";
  // Let the shell settle first, otherwise the hint flashes during boot.
  const SETTINGS_TIP_DELAY = 1200;

  function _readCollapsedSections() {
    try {
      const raw = JSON.parse(localStorage.getItem(COLLAPSE_KEY));
      return new Set(Array.isArray(raw) ? raw : []);
    } catch (err) {
      return new Set();
    }
  }

  function _initSectionCollapse() {
    const collapsed = _readCollapsedSections();

    document.querySelectorAll("[data-collapsible-section]").forEach(header => {
      const bodyId = header.dataset.collapsibleSection;
      const body = document.getElementById(bodyId);
      if (!body) return;

      const apply = isCollapsed => {
        body.classList.toggle("is-collapsed", isCollapsed);
        header.classList.toggle("is-collapsed", isCollapsed);
      };

      apply(collapsed.has(bodyId));

      header.addEventListener("click", e => {
        if (e.target.closest(".sidebar-divider-actions")) return;
        const next = !body.classList.contains("is-collapsed");
        apply(next);
        if (next) collapsed.add(bodyId); else collapsed.delete(bodyId);
        try {
          localStorage.setItem(COLLAPSE_KEY, JSON.stringify(Array.from(collapsed)));
        } catch (err) {
          // Storage may be full or blocked; folding still works for this session.
        }
      });
    });
  }

  // One-shot hint advertising what lives behind Settings (models, memory,
  // language). Closing it or opening Settings retires it for good.
  function _initSettingsTip() {
    const tip = document.getElementById("settings-tip");
    if (!tip) return;

    let dismissed = false;
    try {
      dismissed = localStorage.getItem(SETTINGS_TIP_KEY) === "1";
    } catch (err) {
      // Storage may be blocked; showing the hint again beats never showing it.
    }
    if (dismissed) return;

    const dismiss = () => {
      dismissed = true;
      tip.style.display = "none";
      try {
        localStorage.setItem(SETTINGS_TIP_KEY, "1");
      } catch (err) {
        // Non-fatal: the hint simply reappears on the next reload.
      }
    };

    document.getElementById("settings-tip-close").addEventListener("click", e => {
      e.stopPropagation();
      dismiss();
    });
    // Opening Settings is exactly what the hint advertises, so stop nagging.
    document.getElementById("btn-settings").addEventListener("click", dismiss);

    setTimeout(() => {
      if (!dismissed) tip.style.display = "flex";
    }, SETTINGS_TIP_DELAY);
  }

  function init() {
    // Settings button toggles between "settings" and "welcome" view.
    document.getElementById("btn-settings").addEventListener("click", () => {
      if (Router.current !== "settings") {
        Router.navigate("settings");
      }
    });

    // Primary navigation items — each just swaps the current route.
    document.getElementById("tasks-sidebar-item").addEventListener("click", () => Router.navigate("tasks"));
    document.getElementById("skills-sidebar-item").addEventListener("click", () => Router.navigate("skills"));
    document.getElementById("channels-sidebar-item").addEventListener("click", () => Router.navigate("channels"));
    document.getElementById("mcp-sidebar-item").addEventListener("click", () => Router.navigate("mcp"));
    document.getElementById("extensions-sidebar-item").addEventListener("click", () => Router.navigate("extensions"));
    document.getElementById("data-management-sidebar-item").addEventListener("click", () => Router.navigate("archive"));
    document.getElementById("profile-sidebar-item").addEventListener("click", () => Router.navigate("profile"));
    document.getElementById("billing-sidebar-item").addEventListener("click", () => Router.navigate("billing"));

    // memories-sidebar-item is retained as a hidden legacy placeholder — no click handler.

    _initSectionCollapse();
    _initSettingsTip();
  }

  return { init };
})();
