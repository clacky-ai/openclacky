const Auth = (() => {
  // ── Constants ──────────────────────────────────────────────────────────
  const COOKIE_NAME      = 'clacky_access_key';
  const STORAGE_KEY      = 'clacky-access-key';
  const PROBE_ENDPOINT   = '/api/sessions?limit=1';
  const MAX_PROMPT_TRIES = 3;

  const PROBE = Object.freeze({
    OK:           'ok',
    UNAUTHORIZED: 'unauthorized',
    SERVER_ERR:   'server_error',
    NETWORK_ERR:  'network_error',
  });

  // ── Module state ───────────────────────────────────────────────────────
  let _authCheckPromise = null;
  let _authPassed       = false;

  // ── Storage helpers ────────────────────────────────────────────────────
  const Cookie = {
    set(key) {
      const secure = location.protocol === 'https:' ? '; Secure' : '';
      document.cookie =
        `${COOKIE_NAME}=${encodeURIComponent(key)}; path=/; SameSite=Strict${secure}`;
    },
    clear() {
      document.cookie =
        `${COOKIE_NAME}=; path=/; max-age=0; SameSite=Strict`;
    },
  };

  function _getStoredKey() {
    return (
      localStorage.getItem(STORAGE_KEY) ||
      new URLSearchParams(location.search).get('access_key') ||
      null
    );
  }

  // ── Auth probe ─────────────────────────────────────────────────────────
  async function _probe() {
    try {
      const r = await fetch(PROBE_ENDPOINT);
      if (r.ok)             return PROBE.OK;
      if (r.status === 401) return PROBE.UNAUTHORIZED;
      return PROBE.SERVER_ERR;
    } catch {
      return PROBE.NETWORK_ERR;
    }
  }

  // ── Prompt helper ──────────────────────────────────────────────────────
  async function _askUserForKey() {
    const message = (typeof I18n !== 'undefined')
      ? I18n.t('auth.accessKeyRequired')
      : 'Access key required:';

    const el = document.getElementById('prompt-modal-input');
    if (el) el.type = 'password';

    try {
      const input = (typeof Modal !== 'undefined' && Modal.prompt)
        ? await Modal.prompt(message)
        : prompt(message);
      return input?.trim() || null;
    } finally {
      if (el) el.type = 'text';
    }
  }

  // ── Core flow ──────────────────────────────────────────────────────────
  async function _doCheck() {
    const existing = _getStoredKey();
    if (existing) Cookie.set(existing);       // seed cookie before probe

    const result = await _probe();

    if (result === PROBE.OK) {
      _authPassed = true;
      return true;
    }

    if (result === PROBE.UNAUTHORIZED) {
      Cookie.clear();
      localStorage.removeItem(STORAGE_KEY);
      return _promptAndRetry();
    }

    // Server/network error — let app proceed
    _authPassed = true;
    return true;
  }

  async function _promptAndRetry() {
    for (let attempt = 1; attempt <= MAX_PROMPT_TRIES; attempt++) {
      const key = await _askUserForKey();
      if (!key) {
        _authPassed = false;
        return false;
      }

      Cookie.set(key);
      const result = await _probe();

      if (result === PROBE.OK) {
        localStorage.setItem(STORAGE_KEY, key);   // persist only after success
        _authPassed = true;
        return true;
      }

      if (result !== PROBE.UNAUTHORIZED) {
        _authPassed = true;                        // transient — proceed
        return true;
      }

      Cookie.clear();                              // wrong key → try again
    }

    _authPassed = false;
    return false;
  }

  // ── Public API (compatible with the original ws.js/app.js usage) ───────
  function check() {
    if (!_authCheckPromise) _authCheckPromise = _doCheck();
    return _authCheckPromise;
  }

  return {
    check,

    // Returns an Authorization header object, or {} if no key present.
    getHeaders() {
      const k = _getStoredKey();
      return k ? { Authorization: `Bearer ${k}` } : {};
    },

    // Returns the raw key (or null). Used by ws.js for WebSocket URLs.
    getKey: _getStoredKey,

    // Clears auth state so check() will re-probe on next call.
    reset() {
      _authCheckPromise = null;
      _authPassed       = false;
    },

    // Read-only getter: `Auth.passed` (not a function call).
    get passed() { return _authPassed; },
  };
})();

Clacky.Auth = Auth;
