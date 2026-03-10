// theme.js — Theme switcher module
// Handles light/dark theme persistence and switching

const Theme = (() => {
  const STORAGE_KEY = "clacky-theme";
  const ATTR_NAME = "data-theme";

  // Initialize theme from localStorage or system preference
  function init() {
    const saved = localStorage.getItem(STORAGE_KEY);
    const theme = saved || (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
    apply(theme);
  }

  // Apply theme to document
  function apply(theme) {
    document.documentElement.setAttribute(ATTR_NAME, theme);
    localStorage.setItem(STORAGE_KEY, theme);
    
    // Update header toggle button if it exists
    const headerToggle = document.getElementById("theme-toggle-header");
    if (headerToggle) {
      if (theme === "light") {
        headerToggle.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon-sm">
          <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>
        </svg>`;
      } else {
        headerToggle.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon-sm">
          <circle cx="12" cy="12" r="4"/>
          <path d="M12 2v2"/>
          <path d="M12 20v2"/>
          <path d="m4.93 4.93 1.41 1.41"/>
          <path d="m17.66 17.66 1.41 1.41"/>
          <path d="M2 12h2"/>
          <path d="M20 12h2"/>
          <path d="m6.34 17.66-1.41 1.41"/>
          <path d="m19.07 4.93-1.41 1.41"/>
        </svg>`;
      }
    }
    
    // Update settings toggle button if it exists (legacy)
    const toggle = document.getElementById("theme-toggle");
    if (toggle) {
      const icon = theme === "light" ? "🌙" : "☀️";
      const label = theme === "light" ? "Dark" : "Light";
      toggle.innerHTML = `<span class="theme-icon">${icon}</span><span>${label}</span>`;
    }
  }

  // Toggle between light and dark
  function toggle() {
    const current = document.documentElement.getAttribute(ATTR_NAME) || "dark";
    const next = current === "dark" ? "light" : "dark";
    apply(next);
  }

  // Get current theme
  function current() {
    return document.documentElement.getAttribute(ATTR_NAME) || "dark";
  }

  return { init, toggle, current };
})();

// Initialize theme on page load
Theme.init();
