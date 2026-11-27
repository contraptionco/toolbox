"use strict";

// Login challenges and session CSRF tokens stay in memory, never browser storage.
(() => {
  const $ = (id) => document.getElementById(id);
  const page = document.body.dataset.page;
  const params = new URLSearchParams(window.location.search);
  const email = 'philip@ilic.nyc';
  let session = null;
  let csrf = '';
  let pending = false;
  let consent = null;

  function nextPath() {
    const requested = params.get('next') || '/';
    if (!requested.startsWith('/') || requested.startsWith('//') || requested.includes('\\')) return '/';
    try {
      const url = new URL(requested, window.location.origin);
      if (url.origin !== window.location.origin || url.pathname === '/login') return '/';
      return url.pathname + url.search + url.hash;
    } catch { return '/'; }
  }
  function showMessage(message, error = false) {
    $('auth-message').hidden = true;
    $('auth-error').hidden = true;
    if (!message) return;
    const node = $(error ? 'auth-error' : 'auth-message');
    node.textContent = message;
    node.hidden = false;
  }
  function requestLogin() {
    window.location.assign('/login?reauth=1&next=' + encodeURIComponent(window.location.pathname + window.location.search));
  }
  async function api(path, data) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(path, {
        method: data === undefined ? 'GET' : 'POST',
        credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: controller.signal,
        headers: { Accept: 'application/json', ...(data === undefined ? {} : { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf }) },
        ...(data === undefined ? {} : { body: JSON.stringify(data) }),
      });
      const value = (response.headers.get('content-type') || '').includes('application/json') ? await response.json() : {};
      if (!response.ok) {
        if (response.status === 401 && page !== 'login') requestLogin();
        throw new Error(typeof value.error_description === 'string' ? value.error_description : typeof value.error === 'string' ? value.error : 'Unable to complete this request. Please try again.');
      }
      return value;
    } catch (error) {
      if (error.name === 'AbortError') throw new Error('This request took too long. Please try again.');
      throw error;
    } finally { clearTimeout(timer); }
  }
  async function refreshSession() {
    session = await api('/auth/session');
    csrf = session.csrf_token || '';
    if (!csrf) throw new Error('Unable to start a secure session. Please reload this page.');
    return session;
  }
  async function attempt(action, message) {
    if (pending) return;
    pending = true;
    showMessage('');
    const buttons = [...document.querySelectorAll('button')];
    const disabled = buttons.map((button) => button.disabled);
    buttons.forEach((button) => { button.disabled = true; });
    document.querySelector('main').setAttribute('aria-busy', 'true');
    try {
      await action();
      if (message) showMessage(message);
    } catch (error) {
      const canceled = error.name === 'NotAllowedError' || error.name === 'AbortError';
      const unavailable = error.name === 'NotSupportedError' || error.name === 'SecurityError';
      showMessage(canceled ? 'The passkey request was canceled or timed out. You can try again or use an email code.' : unavailable ? 'Passkeys are unavailable in this browser. Use an email code to sign in.' : (error.message || 'Unable to continue. Please try again.'), true);
    } finally {
      pending = false;
      buttons.forEach((button, index) => { if (button.isConnected) button.disabled = disabled[index]; });
      document.querySelector('main').removeAttribute('aria-busy');
    }
  }
  function decode(value) {
    const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
    return Uint8Array.from(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')), (character) => character.charCodeAt(0));
  }
  function encode(value) {
    if (!value) return null;
    return btoa(Array.from(new Uint8Array(value), (byte) => String.fromCharCode(byte)).join('')).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function credentialOptions(value, registration) {
    const options = { ...value, challenge: decode(value.challenge) };
    if (registration) options.user = { ...value.user, id: decode(value.user.id) };
    for (const key of ['allowCredentials', 'excludeCredentials']) {
      if (Array.isArray(value[key])) options[key] = value[key].map((credential) => ({ ...credential, id: decode(credential.id) }));
    }
    return options;
  }
  function credentialJSON(credential) {
    if (!credential) throw new Error('No passkey was returned. Please try again.');
    const response = { clientDataJSON: encode(credential.response.clientDataJSON) };
    for (const key of ['attestationObject', 'authenticatorData', 'signature', 'userHandle']) {
      if (key in credential.response) response[key] = encode(credential.response[key]);
    }
    if (credential.response.getTransports) response.transports = credential.response.getTransports();
    return { id: credential.id, rawId: encode(credential.rawId), type: credential.type,
      response, clientExtensionResults: credential.getClientExtensionResults(), authenticatorAttachment: credential.authenticatorAttachment };
  }
  function requirePasskeys() {
    if (!window.PublicKeyCredential || !navigator.credentials) throw new Error('This browser does not support passkeys. Use an email code to sign in.');
  }
  async function addPasskey(name) {
    requirePasskeys();
    const options = await api('/auth/passkey/register/options', {});
    const credential = await navigator.credentials.create({ publicKey: credentialOptions(options, true) });
    await api('/auth/passkey/register/verify', { response: credentialJSON(credential), name: name || 'My passkey' });
    await refreshSession();
  }
  async function finishLogin(offerPasskey) {
    await refreshSession();
    $('code').value = '';
    if (offerPasskey && (!session.passkeys || session.passkeys.length === 0) && window.PublicKeyCredential) {
      $('login-email-step').hidden = true;
      $('login-code-step').hidden = true;
      $('login-passkey-step').hidden = false;
      $('login-title').textContent = 'A simpler sign-in.';
      $('setup-passkey').focus();
    } else window.location.assign(nextPath());
  }
  async function sendCode() {
    await api('/auth/email', { email });
    $('login-email-step').hidden = true;
    $('login-passkey-step').hidden = true;
    $('login-code-step').hidden = false;
    $('login-title').textContent = 'Check your inbox.';
    $('code').value = '';
    $('code').focus();
  }
  function initLogin() {
    $('email-form').addEventListener('submit', (event) => { event.preventDefault(); void attempt(sendCode); });
    $('code-form').addEventListener('submit', (event) => {
      event.preventDefault();
      void attempt(async () => { await api('/auth/verify', { email, code: $('code').value.trim() }); await finishLogin(true); });
    });
    $('resend-code').addEventListener('click', () => { void attempt(sendCode, 'A new code has been sent. Use the most recent email.'); });
    $('back-to-email').addEventListener('click', () => {
      $('login-code-step').hidden = true;
      $('login-email-step').hidden = false;
      $('login-title').textContent = 'Sign in to Toolbox.';
      $('code').value = '';
      showMessage('');
      $('login-passkey').focus();
    });
    $('login-passkey').addEventListener('click', () => {
      void attempt(async () => {
        requirePasskeys();
        const options = await api('/auth/passkey/login/options', {});
        const credential = await navigator.credentials.get({ publicKey: credentialOptions(options, false) });
        await api('/auth/passkey/login/verify', { response: credentialJSON(credential) });
        await finishLogin(false);
      });
    });
    $('setup-passkey').addEventListener('click', () => { void attempt(async () => { await addPasskey('My passkey'); window.location.assign(nextPath()); }); });
    $('skip-passkey').addEventListener('click', () => window.location.assign(nextPath()));
  }
  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function date(value) {
    if (!value) return '';
    const parsed = new Date(typeof value === 'number' && value < 1e12 ? value * 1000 : value);
    return Number.isNaN(parsed.getTime()) ? '' : parsed.toLocaleDateString([], { year: 'numeric', month: 'short', day: 'numeric' });
  }
  function emptyList(id, text) { $(id).replaceChildren(element('li', 'security-empty', text)); }
  function renderPasskeys() {
    const keys = Array.isArray(session.passkeys) ? session.passkeys : [];
    if (!keys.length) return emptyList('passkey-list', 'No passkeys saved yet.');
    $('passkey-list').replaceChildren(...keys.map((key) => {
      const row = element('li');
      const details = element('div');
      details.append(element('span', 'security-item-title', key.name || 'Passkey'));
      if (date(key.created_at)) details.append(element('span', 'security-item-detail', 'Added ' + date(key.created_at)));
      const remove = element('button', 'auth-button', 'Remove');
      remove.type = 'button';
      remove.setAttribute('aria-label', 'Remove ' + (key.name || 'passkey'));
      remove.addEventListener('click', () => {
        if (!window.confirm('Remove this passkey? You can still sign in with an email code.')) return;
        void attempt(async () => { await api('/auth/passkey/delete', { id: key.id }); await refreshSession(); renderPasskeys(); }, 'Passkey removed.');
      });
      row.append(details, remove);
      return row;
    }));
  }
  async function renderConnections() {
    const value = await api('/oauth/connections');
    const connections = Array.isArray(value.connections) ? value.connections : [];
    if (!connections.length) return emptyList('connection-list', 'No apps are connected.');
    $('connection-list').replaceChildren(...connections.map((connection) => {
      const row = element('li');
      const details = element('div');
      details.append(element('span', 'security-item-title', connection.client_name || 'Connected app'));
      details.append(element('span', 'security-item-detail', 'Read-only access' + (date(connection.created_at) ? ' · Connected ' + date(connection.created_at) : '')));
      const disconnect = element('button', 'auth-button', 'Disconnect');
      disconnect.type = 'button';
      disconnect.addEventListener('click', () => {
        void attempt(async () => { await api('/oauth/connections/revoke', { id: connection.id }); await renderConnections(); }, 'App disconnected. Its access has been revoked.');
      });
      row.append(details, disconnect);
      return row;
    }));
  }
  function initSecurity() {
    $('add-passkey-form').addEventListener('submit', (event) => {
      event.preventDefault();
      void attempt(async () => { await addPasskey($('passkey-name').value.trim()); $('passkey-name').value = ''; renderPasskeys(); }, 'Passkey saved.');
    });
    $('security-logout').addEventListener('click', () => {
      void attempt(async () => { await api('/auth/logout', {}); session = null; csrf = ''; navigator.serviceWorker?.controller?.postMessage({ type: 'CLEAR_TOOLBOX_CACHE' }); window.location.assign('/login'); });
    });
    $('copy-mcp').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText($('mcp-url').textContent); showMessage('Connector address copied.'); }
      catch { showMessage('Select the connector address to copy it.', true); }
    });
  }
  async function initConsent() {
    consent = await api('/oauth/consent?' + params.toString());
    $('consent-client').textContent = (consent.client_name || 'This app') + ' is requesting access to Toolbox as ' + email + '.';
    let host;
    try { host = new URL(consent.client_origin).hostname; } catch { throw new Error('The app’s callback address is invalid.'); }
    $('consent-host').textContent = 'You will return to ' + host + ' after approving.';
    $('consent-logs').hidden = !Array.isArray(consent.scopes) || !consent.scopes.includes('toolbox:logs');
    for (const [id, approve] of [['consent-approve', true], ['consent-deny', false]]) {
      $(id).disabled = false;
      $(id).addEventListener('click', () => {
        void attempt(async () => {
          const result = await api('/oauth/authorize', { id: consent.id, approve });
          const redirect = new URL(result.redirect);
          if (redirect.protocol !== 'https:' || redirect.origin !== new URL(consent.client_origin).origin) throw new Error('The app’s callback address is invalid.');
          window.location.assign(redirect.href);
        });
      });
    }
  }
  async function boot() {
    try {
      await refreshSession();
      if (page === 'login') {
        if (session.authenticated && params.get('reauth') !== '1') { window.location.replace(nextPath()); return; }
        $('send-code').disabled = false;
        $('login-passkey').disabled = false;
      } else {
        if (!session.authenticated) { requestLogin(); return; }
        if (page === 'security') {
          renderPasskeys();
          $('add-passkey').disabled = false;
          try { await renderConnections(); } catch (error) { emptyList('connection-list', 'Unable to load connected apps. Reload to try again.'); throw error; }
        } else if (page === 'consent') await initConsent();
      }
    } catch (error) { showMessage(error.message || 'Unable to load this page. Please reload to try again.', true); }
  }
  if (page === 'login') initLogin();
  if (page === 'security') initSecurity();
  window.addEventListener('pagehide', () => { csrf = ''; session = null; consent = null; if ($('code')) $('code').value = ''; });
  window.addEventListener('pageshow', (event) => { if (event.persisted) window.location.reload(); });
  void boot();
})();
