// ── Brand · view — banners, logo/favicon, owner badge, activation panel ───
//
// Owns all white-label DOM: activation banner, warning bar, header logo +
// favicon + theme color, OWNER badge, the "get serial" link, and the activation
// panel flow. Reads brand info through BrandStore; status/activation network
// calls go through store actions.
//
// Augments the `Brand` facade with the apply* / goToLicenseInput methods that
// other modules call.
//
// Depends on: BrandStore, I18n, Router, Settings (optional), WS/Tasks/Skills
// (boot fallback), global $ helper.
// ───────────────────────────────────────────────────────────────────────────

const BrandView = (() => {

  function _onStatus(data) {
    if (!data) return;
    if (!data.branded) {
      if (data.distribution_refresh_pending) _scheduleDistributionRefreshPoll();
      return;
    }

    if (data.product_name) _applyBrandName(data.product_name);

    if (data.needs_activation) {
      if (data.theme_color) Settings.applyAccentColor(data.theme_color, { persist: true });
      _showActivationBanner(data.product_name);
      _applyHeaderLogo();
      if (data.distribution_refresh_pending) _scheduleDistributionRefreshPoll();
      return;
    }

    if (data.warning) _showWarning(data.warning);
    _applyHeaderLogo();
    _applyOwnerBadge();
  }

  function _showActivationBanner(brandName) {
    if (document.getElementById("brand-activation-banner")) return;

    const name = brandName || I18n.t("brand.banner.defaultName");

    let settled = false;
    const settle = data => {
      if (settled) return;
      settled = true;
      if (document.getElementById("brand-activation-banner")) return;
      _renderActivationBanner(name, data);
    };

    Brand.fetchSkillsBanner().then(settle).catch(() => settle(null));
    setTimeout(() => settle(null), 5000);
  }

  function _renderActivationBanner(name, countsData) {
    const bar = document.createElement("div");
    bar.id        = "brand-activation-banner";
    bar.className = "brand-activation-banner";

    const span = document.createElement("span");
    const link = document.createElement("button");
    link.className = "brand-activation-banner-link";
    link.addEventListener("click", () => _goToLicenseInput());

    let i18nKey  = "brand.banner.prompt";
    let vars     = { name };
    let hideLink = false;

    if (countsData && countsData.ok && countsData.free_mode) {
      const free = (countsData.skills || []).length;
      const paid = Number(countsData.paid_skills_count) || 0;
      vars = { name, free, paid, freePlural: free === 1 ? "" : "s", paidPlural: paid === 1 ? "" : "s" };

      if (free > 0 && paid > 0)        i18nKey = "brand.banner.freePromptBoth";
      else if (free > 0 && paid === 0) { i18nKey = "brand.banner.freePromptOnlyFree"; hideLink = true; }
      else if (free === 0 && paid > 0) i18nKey = "brand.banner.freePromptOnlyPaid";
    }

    span.textContent = I18n.t(i18nKey, vars);
    span.setAttribute("data-i18n", i18nKey);
    span.setAttribute(
      "data-i18n-vars",
      Object.entries(vars).map(([k, v]) => `${k}=${v}`).join(";")
    );

    link.textContent = I18n.t("brand.banner.action");
    link.setAttribute("data-i18n", "brand.banner.action");
    if (hideLink) link.style.display = "none";

    const closeBtn = document.createElement("button");
    closeBtn.className = "brand-activation-banner-close";
    closeBtn.innerHTML = "&#x2715;";
    closeBtn.onclick   = () => bar.remove();

    bar.appendChild(span);
    bar.appendChild(link);
    bar.appendChild(closeBtn);
    document.getElementById("main").prepend(bar);
  }

  function _goToLicenseInput() {
    window.Clacky.Router.navigate("settings");
    if (typeof Settings !== "undefined") Settings.open();
    setTimeout(() => {
      const generalTabBtn = document.querySelector('#settings-tabs .settings-tab[data-tab="general"]');
      if (generalTabBtn && !generalTabBtn.classList.contains("active")) generalTabBtn.click();

      const section         = document.getElementById("brand-license-section");
      const input           = document.getElementById("settings-license-key");
      const scrollContainer = document.getElementById("settings-body");

      if (section && scrollContainer) {
        const containerTop = scrollContainer.getBoundingClientRect().top;
        const sectionTop   = section.getBoundingClientRect().top;
        const offset       = sectionTop - containerTop + scrollContainer.scrollTop - 24;
        scrollContainer.scrollTo({ top: offset, behavior: "smooth" });
      }

      if (section) {
        section.classList.remove("section-highlight");
        void section.offsetWidth; // force reflow to restart animation
        section.classList.add("section-highlight");
        section.addEventListener("animationend", () => section.classList.remove("section-highlight"), { once: true });
      }

      if (input) input.focus();
    }, 300);
  }

  function _bindActivationPanel() {
    $("brand-btn-activate").addEventListener("click", _doActivate);
    $("brand-license-key").addEventListener("keydown", e => {
      if (e.key === "Enter") _doActivate();
    });
    $("brand-btn-skip").addEventListener("click", _skipActivation);
  }

  async function _doActivate() {
    const btn = $("brand-btn-activate");
    const key = $("brand-license-key").value.trim();

    if (!key) {
      _setResult(false, I18n.t("settings.brand.enterKey"));
      return;
    }

    if (!Brand.testMode && !/^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{8}){4}$/.test(key)) {
      _setResult(false, I18n.t("settings.brand.invalidFormat"));
      return;
    }

    btn.disabled    = true;
    btn.textContent = I18n.t("settings.brand.btn.activating");
    _setResult(null, "");

    try {
      const data = await Brand.activate(key);

      if (data.ok) {
        _setResult(true, I18n.t("brand.activate.success"));
        if (data.product_name) _applyBrandName(data.product_name);
        if (data.theme_color) Settings.applyAccentColor(data.theme_color, { persist: true });
        Brand.clearBrandCache();
        _applyHeaderLogo();
        setTimeout(_bootUI, 800);
      } else {
        _setResult(false, data.error || I18n.t("settings.brand.activationFailed"));
        btn.disabled    = false;
        btn.textContent = I18n.t("settings.brand.btn.activate");
      }
    } catch (e) {
      _setResult(false, I18n.t("settings.brand.networkError") + e.message);
      btn.disabled    = false;
      btn.textContent = I18n.t("settings.brand.btn.activate");
    }
  }

  function _skipActivation() {
    _showWarning(I18n.t("brand.skip.warning"), "brand.skip.warning");
    _bootUI();
  }

  function _setResult(ok, msg) {
    const el = $("brand-activate-result");
    if (!el) return;
    if (ok === null) { el.textContent = ""; el.className = "onboard-test-result"; return; }
    el.textContent = ok ? msg : msg;
    el.className   = "onboard-test-result " + (ok ? "result-ok" : "result-fail");
  }

  function _applyBrandName(name) {
    const nodes = {
      "page-title":    name,
      "sidebar-logo":  name,
      "onboard-title": I18n.t("onboard.welcome", { name }),
      "welcome-title": I18n.t("onboard.welcome", { name })
    };
    Object.entries(nodes).forEach(([id, text]) => {
      const el = $(id);
      if (el) el.textContent = text;
    });
  }

  function _applyHeaderLogo() {
    Brand.fetchInfo().then(info => {
      const logoImg   = document.getElementById("header-logo-img");
      const logoText  = document.getElementById("header-logo");
      const brandWrap = document.getElementById("header-brand");

      if (info.theme_color) {
        const metaTheme = document.querySelector("meta[name='theme-color']");
        if (metaTheme) metaTheme.setAttribute("content", info.theme_color);
      }
      const userAccent = (() => { try { return localStorage.getItem("clacky-accent-color"); } catch (_) { return null; } })();
      if (userAccent) {
        Settings.applyAccentColor(userAccent, { persist: false });
      } else if (info.theme_color) {
        Settings.applyAccentColor(info.theme_color, { persist: true });
      } else {
        const root = document.documentElement;
        root.style.removeProperty("--color-accent-primary");
        root.style.removeProperty("--color-accent-hover");
        root.style.removeProperty("--color-button-primary");
        root.style.removeProperty("--color-button-primary-hover");
      }

      const hasLogo = !!(info.logo_url && logoImg);

      if (hasLogo) {
        if (logoImg.src && logoImg.src === info.logo_url) {
          _applyFavicon(info.logo_url);
        } else {
          const img = new Image();
          img.onload = () => {
            logoImg.src           = info.logo_url;
            logoImg.alt           = info.product_name || "";
            logoImg.style.display = "";
            if (brandWrap) brandWrap.classList.add("has-logo");
            _applyFavicon(info.logo_url);
          };
          img.onerror = () => {};
          img.src = info.logo_url;
        }
      } else if (info.product_name) {
        if (logoImg) {
          logoImg.style.display = "none";
          logoImg.src           = "";
        }
        if (brandWrap) brandWrap.classList.remove("has-logo");
      } else {
        _applyDefaultLogo();
      }

      if (logoText) {
        const name = info.product_name || "";
        if (name) {
          logoText.textContent    = name;
          logoText.style.display  = "";
        } else {
          logoText.textContent   = "OpenClacky";
          logoText.style.display = "";
        }
      }
    }).catch(() => {});
  }

  function _applyDefaultLogo() {
    const logoImg   = document.getElementById("header-logo-img");
    const brandWrap = document.getElementById("header-brand");
    if (!logoImg) return;

    logoImg.src           = "/logo_nav_dark.png";
    logoImg.alt           = "OpenClacky";
    logoImg.style.display = "";
    if (brandWrap) brandWrap.classList.add("has-logo");
  }

  function _applyFavicon(url) {
    let link = document.querySelector("link[rel='icon']");
    if (!link) {
      link = document.createElement("link");
      link.rel = "icon";
      document.head.appendChild(link);
    }
    const lower = url.split("?")[0].toLowerCase();
    if (lower.endsWith(".svg"))       link.type = "image/svg+xml";
    else if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) link.type = "image/jpeg";
    else if (lower.endsWith(".ico")) link.type = "image/x-icon";
    else                              link.type = "image/png";
    link.href = url;
  }

  function _showWarning(message, i18nKey) {
    const existing = document.getElementById("brand-warning-bar");
    if (existing) return;

    const bar = document.createElement("div");
    bar.id        = "brand-warning-bar";
    bar.className = "brand-warning-bar";

    const span = document.createElement("span");
    span.textContent = message;
    if (i18nKey) span.setAttribute("data-i18n", i18nKey);

    const renewBtn = document.createElement("button");
    renewBtn.className   = "brand-warning-renew-btn";
    renewBtn.textContent = I18n.t("brand.warning.renewBtn");
    renewBtn.setAttribute("data-i18n", "brand.warning.renewBtn");
    renewBtn.onclick = () => { bar.remove(); _goToLicenseInput(); };

    const closeBtn = document.createElement("button");
    closeBtn.className = "brand-warning-close-btn";
    closeBtn.innerHTML = "&#x2715;";
    closeBtn.onclick   = () => bar.remove();

    bar.appendChild(span);
    bar.appendChild(renewBtn);
    bar.appendChild(closeBtn);
    document.getElementById("main").prepend(bar);
  }

  function _bootUI() {
    if (typeof window.bootAfterBrand === "function") {
      window.bootAfterBrand();
    } else {
      WS.connect();
      Tasks.load();
      Skills.load();
    }
  }

  let _distRefreshPolling = false;
  function _scheduleDistributionRefreshPoll() {
    if (_distRefreshPolling) return;
    _distRefreshPolling = true;

    const delays = [3000, 5000, 7000];
    let attempt  = 0;

    const poll = () => {
      Brand.refresh().then(status => {
        Brand.clearBrandCache();
        return Brand.fetchInfo().then(info => ({ status, info }));
      }).then(({ status, info }) => {
        if (info && info.product_name) _applyBrandName(info.product_name);
        _applyHeaderLogo();
        const refreshSettled = !!(
          status && status.branded && !status.distribution_refresh_pending
        );
        if (refreshSettled || attempt >= delays.length) {
          _distRefreshPolling = false;
          return;
        }
        setTimeout(poll, delays[attempt++]);
      }).catch(() => {
        if (attempt >= delays.length) { _distRefreshPolling = false; return; }
        setTimeout(poll, delays[attempt++]);
      });
    };

    setTimeout(poll, delays[attempt++]);
  }

  function _applyOwnerBadge() {
    const badge = document.getElementById("header-owner-badge");
    if (!badge) return;
    badge.style.display = Brand.userLicensed ? "" : "none";
  }

  function _applyGetSerialLink() {
    const row = document.getElementById("brand-get-serial");
    const btn = document.getElementById("btn-get-serial");
    if (!row || !btn) return;
    Brand.fetchInfo().then(info => {
      const url = info && typeof info.homepage_url === "string" ? info.homepage_url.trim() : "";
      if (url) {
        row.style.display = "";
        btn.dataset.homepageUrl = url;
      } else {
        row.style.display = "none";
        delete btn.dataset.homepageUrl;
      }
    }).catch(() => {
      row.style.display = "none";
    });
  }

  function _subscribe() {
    Brand.on("brand:status", _onStatus);
    window.addEventListener("clacky-theme-change", () => {});
  }

  const viewApi = {
    applyBrandName:     _applyBrandName,
    applyHeaderLogo:    _applyHeaderLogo,
    applyOwnerBadge:    _applyOwnerBadge,
    applyGetSerialLink: _applyGetSerialLink,
    goToLicenseInput:   _goToLicenseInput,
  };

  return { init: _subscribe, api: viewApi };
})();

Object.assign(Brand, BrandView.api);
BrandView.init();
