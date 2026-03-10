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
      const iconName = theme === "light" ? "moon" : "sun";
      headerToggle.innerHTML = `<i data-lucide="${iconName}" class="icon-sm"></i>`;
      // Reinitialize Lucide icons
      if (typeof window.reinitLucide === 'function') {
        window.reinitLucide();
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
