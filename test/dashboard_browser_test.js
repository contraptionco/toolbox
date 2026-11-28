'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const publicDir = path.join(__dirname, '../web/public');
const script = fs.readFileSync(path.join(publicDir, 'app.js'), 'utf8');
const html = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8');
const oldRevision = 'a'.repeat(40);
const nextRevision = 'b'.repeat(40);
const flush = () => new Promise((resolve) => setImmediate(resolve));

// Execute the real browser script with isolated DOM/fetch/timers. No HTTP server,
// host collector, browser profile, credentials, or external dependencies are used.
class Node {
  constructor() {
    this.children = []; this.events = new Map(); this.style = {}; this.dataset = {};
    this.classList = { toggle() {}, contains() { return false; } };
    this.disabled = false; this.hidden = false;
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; this.text = ''; }
  set textContent(value) { this.text = String(value); this.children = []; }
  get textContent() { return this.text || this.children.map((child) => child.textContent).join(''); }
  set value(value) { this.selectedValue = value; }
  get value() { return this.selectedValue ?? this.children[0]?.value ?? ''; }
  get options() { return this.children; }
  setAttribute() {}
  removeAttribute() {}
  querySelectorAll() { return []; }
  addEventListener(name, callback) { this.events.set(name, callback); }
  emit(name) { this.events.get(name)?.({ preventDefault() {} }); }
}

function page(revision = oldRevision, initial = {}) {
  const nodes = new Map([...html.matchAll(/\bid="([^"]+)"/g)].map((match) => [match[1], new Node()]));
  const document = new Node();
  document.body = new Node();
  document.getElementById = (id) => { assert.ok(nodes.has(id), `real HTML contains #${id}`); return nodes.get(id); };
  document.querySelector = (selector) => { assert.equal(selector, 'meta[name="toolbox-revision"]'); return revision == null ? null : { content: revision }; };
  document.createElement = () => new Node();
  document.createTextNode = (text) => { const node = new Node(); node.textContent = text; return node; };
  const window = new Node();
  let reloads = 0;
  window.location = { reload() { reloads += 1; } };
  const timers = new Map();
  let timerId = 0;
  let data = { deployment: { dashboard_commit: revision }, applications: [], containers: [], log_sources: [], ...initial };
  const requests = [];
  const context = vm.createContext({
    document, window, navigator: { onLine: true }, URL, AbortController,
    setTimeout(fn) { const id = ++timerId; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
    async fetch(url, options) {
      requests.push({ url, options });
      return { status: 200, ok: true, headers: { get: () => 'application/json' },
        json: async () => url === '/api/status' ? data : { lines: ['fixture log'] } };
    },
  });
  vm.runInContext(script, context, { filename: 'app.js' });
  return { nodes, document, window, timers, requests, get reloads() { return reloads; },
    async poll(next) { data = next; nodes.get('refresh').emit('click'); await flush(); },
  };
}

test('checkout advance and new application data update the open page without a reload', async () => {
  const browser = page();
  await flush();
  await browser.poll({ deployment: { dashboard_commit: oldRevision, checkout_commit: nextRevision },
    applications: [{ name: 'new-service', type: 'docker', status: 'running' }], containers: [],
    log_sources: [{ id: 'heartbeat', label: 'Heartbeat' }, { id: 'container:new-service', label: 'New service' }] });
  assert.equal(browser.reloads, 0);
  assert.match(browser.nodes.get('application-list').textContent, /new-service/);
  assert.equal(browser.nodes.get('deploy-commit').textContent, 'bbbbbbbb');
  assert.deepEqual(browser.nodes.get('log-source').options.map((option) => option.value), ['heartbeat', 'container:new-service']);
  assert.equal(browser.requests[0].options.cache, 'no-store');
});

test('changed runtime reloads once, stops polling, and clears private readings', async () => {
  const browser = page();
  await flush();
  await browser.poll({ deployment: { dashboard_commit: nextRevision } });
  assert.equal(browser.reloads, 1);
  assert.equal(browser.timers.size, 0);
  assert.equal(browser.nodes.get('dashboard-commit').textContent, '—');
  assert.equal(browser.nodes.get('log-output').textContent, 'Live logs are not stored offline.');
  const requests = browser.requests.length;
  browser.window.emit('pageshow');
  browser.window.emit('online');
  browser.document.emit('visibilitychange');
  await browser.poll({ deployment: { dashboard_commit: nextRevision } });
  assert.equal(browser.reloads, 1);
  assert.equal(browser.requests.length, requests);
});

test('new process on the first status response is compared with HTML, not accepted as the baseline', async () => {
  const browser = page(oldRevision, { deployment: { dashboard_commit: nextRevision } });
  await flush();
  assert.equal(browser.reloads, 1);
  const refreshed = page(nextRevision);
  await flush();
  await refreshed.poll({ deployment: { dashboard_commit: nextRevision } });
  assert.equal(refreshed.reloads, 0);
});

test('demo, missing and malformed revision evidence never triggers navigation', async () => {
  for (const [documentRevision, runtimeRevision] of [
    ['demo', nextRevision], [null, nextRevision], ['', nextRevision],
    [oldRevision, undefined], [oldRevision, 'demo'], [oldRevision, 'b'.repeat(39)],
    [oldRevision, 'b'.repeat(41)], [oldRevision, {}], [oldRevision, oldRevision.toUpperCase()],
  ]) {
    const browser = page(documentRevision, { deployment: { dashboard_commit: runtimeRevision } });
    await flush();
    assert.equal(browser.reloads, 0, `${documentRevision}: ${String(runtimeRevision)}`);
  }
  const sha256 = page('a'.repeat(64), { deployment: { dashboard_commit: 'b'.repeat(64) } });
  await flush();
  assert.equal(sha256.reloads, 1);
});

test('revisioned dashboard assets bypass the service worker cache fallback', () => {
  const handlers = new Map();
  vm.runInNewContext(fs.readFileSync(path.join(publicDir, 'sw.js'), 'utf8'), {
    self: { location: { origin: 'https://toolbox.example' }, addEventListener(name, callback) { handlers.set(name, callback); } }, URL,
  });
  for (const asset of ['/app.js', '/style.css', '/auth.css']) {
    let intercepted = false;
    handlers.get('fetch')({ request: { method: 'GET', url: `https://toolbox.example${asset}?revision=${nextRevision}`, mode: 'cors' },
      respondWith() { intercepted = true; } });
    assert.equal(intercepted, false, asset);
  }
});

const authScript = fs.readFileSync(path.join(publicDir, 'auth.js'), 'utf8');
function authPage({ capability, pageName = 'login', passkeys = [{ id: 'key-1', name: 'Fixture key' }],
  support = true, credentialError, sessionError, emailError } = {}) {
  const authHTML = fs.readFileSync(path.join(publicDir, pageName + '.html'), 'utf8');
  const nodes = new Map();
  const allNodes = [];
  for (const match of authHTML.matchAll(/<([a-z][a-z0-9]*)\b([^>]*)>/gi)) {
    const node = new Node();
    node.tag = match[1];
    node.hidden = /\bhidden(?:\s|$)/.test(match[2]);
    node.disabled = /\bdisabled(?:\s|$)/.test(match[2]);
    node.isConnected = true;
    node.focus = () => {};
    allNodes.push(node);
    const id = /\bid="([^"]+)"/.exec(match[2]);
    if (id) nodes.set(id[1], node);
  }
  const document = new Node();
  document.body = { dataset: { page: pageName } };
  document.getElementById = (id) => { assert.ok(nodes.has(id), `real ${pageName} HTML contains #${id}`); return nodes.get(id); };
  document.querySelector = (selector) => { assert.equal(selector, 'main'); return allNodes.find((node) => node.tag === 'main'); };
  document.querySelectorAll = (selector) => { assert.equal(selector, 'button'); return allNodes.filter((node) => node.tag === 'button'); };
  document.createElement = (tag) => {
    const node = new Node(); node.tag = tag; node.isConnected = true; allNodes.push(node); return node;
  };
  const window = new Node();
  const navigations = [];
  const confirmations = [];
  window.location = { origin: 'https://toolbox.example', pathname: '/' + pageName, search: '',
    assign(url) { navigations.push(url); }, replace(url) { navigations.push(url); } };
  window.confirm = (message) => { confirmations.push(message); return true; };
  if (support) window.PublicKeyCredential = class {};
  const requests = [];
  const timers = new Map();
  let timerId = 0;
  let authenticated = pageName === 'security';
  const credential = { id: 'key-1', rawId: new Uint8Array([1]), type: 'public-key',
    response: { clientDataJSON: new Uint8Array([1]), authenticatorData: new Uint8Array([1]), signature: new Uint8Array([1]) },
    getClientExtensionResults() { return {}; } };
  const context = vm.createContext({
    document, window, URL, URLSearchParams, AbortController, atob, btoa,
    navigator: support ? { credentials: { async get() { if (credentialError) throw credentialError; return credential; } } } : {},
    setTimeout(fn) { const id = ++timerId; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
    async fetch(url, options) {
      requests.push({ url, options });
      let status = 200;
      let data = {};
      if (url === '/auth/session') {
        status = sessionError ? 503 : 200;
        data = { authenticated, email_sign_in_enabled: capability, csrf_token: 'fixture-csrf', passkeys,
          ...(sessionError ? { error: 'Unable to start a session.' } : {}) };
      } else if (url === '/auth/email') {
        if (emailError) { status = 403; data = { error: emailError }; }
      } else if (url === '/auth/passkey/login/options') data = { challenge: 'AQ', allowCredentials: [] };
      else if (url === '/auth/passkey/login/verify' || url === '/auth/verify') authenticated = true;
      else if (url === '/auth/passkey/delete') passkeys = passkeys.filter((key) => key.id !== JSON.parse(options.body).id);
      else if (url === '/oauth/connections') data = { connections: [] };
      else assert.fail('Unexpected auth request: ' + url);
      return { status, ok: status === 200, headers: { get: () => 'application/json' }, json: async () => data };
    },
  });
  vm.runInContext(authScript, context, { filename: 'auth.js' });
  return { nodes, requests, navigations, confirmations,
    async emit(id, event = 'click') { nodes.get(id).emit(event); await flush(); } };
}

test('email sign-in stays hidden and sends nothing unless the capability is exactly true', async () => {
  for (const capability of [false, null, undefined, 'true', 1, {}]) {
    const browser = authPage({ capability });
    await flush();
    assert.equal(browser.nodes.get('login-email-option').hidden, true);
    assert.equal(browser.nodes.get('send-code').disabled, true);
    assert.equal(browser.nodes.get('login-passkey').disabled, false);
    assert.equal(browser.nodes.get('login-description').textContent, 'Use a saved passkey to sign in.');
    await browser.emit('email-form', 'submit');
    await browser.emit('resend-code');
    await browser.emit('code-form', 'submit');
    assert.deepEqual(browser.requests.map((request) => request.url), ['/auth/session']);
    assert.equal(browser.nodes.get('login-code-step').hidden, true);
    assert.equal(browser.navigations.length, 0);
  }
});

test('email controls are hidden initially and stay unavailable when session loading fails', async () => {
  const browser = authPage({ capability: true, sessionError: true });
  assert.equal(browser.nodes.get('login-email-option').hidden, true);
  assert.equal(browser.nodes.get('send-code').disabled, true);
  await flush();
  assert.equal(browser.nodes.get('login-email-option').hidden, true);
  assert.equal(browser.nodes.get('login-passkey').disabled, true);
  assert.match(browser.nodes.get('auth-error').textContent, /Unable to start a session/);
  assert.equal(browser.navigations.length, 0);
});

test('passkey-only login completes the challenge and verification before navigating', async () => {
  const browser = authPage();
  await flush();
  await browser.emit('login-passkey');
  assert.deepEqual(browser.requests.map((request) => request.url), [
    '/auth/session', '/auth/passkey/login/options', '/auth/passkey/login/verify', '/auth/session',
  ]);
  assert.deepEqual(browser.navigations, ['/']);
  const verification = browser.requests[2].options;
  assert.equal(verification.headers['X-CSRF-Token'], 'fixture-csrf');
  assert.equal(verification.cache, 'no-store');
});

test('unavailable and canceled passkeys only suggest email when it is enabled', async () => {
  for (const capability of [false, true]) {
    for (const condition of [{ support: false }, ...['NotAllowedError', 'AbortError', 'NotSupportedError', 'SecurityError'].map((name) => ({ credentialError: Object.assign(new Error('Fixture error'), { name }) }))]) {
      const browser = authPage({ capability, ...condition });
      await flush();
      await browser.emit('login-passkey');
      assert.equal(browser.nodes.get('auth-error').hidden, false);
      assert.equal(/email code/i.test(browser.nodes.get('auth-error').textContent), capability);
      assert.equal(browser.nodes.get('login-passkey').disabled, false);
      assert.equal(browser.navigations.length, 0);
    }
  }
});

test('enabled recovery can send, resend, and verify a code', async () => {
  const browser = authPage({ capability: true });
  await flush();
  assert.equal(browser.nodes.get('login-email-option').hidden, false);
  assert.equal(browser.nodes.get('send-code').disabled, false);
  await browser.emit('email-form', 'submit');
  assert.equal(browser.nodes.get('login-code-step').hidden, false);
  await browser.emit('resend-code');
  browser.nodes.get('code').value = '123456';
  await browser.emit('code-form', 'submit');
  assert.deepEqual(browser.requests.map((request) => request.url), ['/auth/session', '/auth/email', '/auth/email', '/auth/verify', '/auth/session']);
  assert.equal(JSON.parse(browser.requests[3].options.body).code, '123456');
  assert.deepEqual(browser.navigations, ['/']);
});

test('a rejected recovery request never claims that a code was sent', async () => {
  const browser = authPage({ capability: true, emailError: 'Email sign-in is disabled.' });
  await flush();
  await browser.emit('email-form', 'submit');
  assert.equal(browser.nodes.get('login-code-step').hidden, true);
  await browser.emit('resend-code');
  assert.equal(browser.nodes.get('auth-message').hidden, true);
  assert.match(browser.nodes.get('auth-error').textContent, /disabled/);
  assert.equal(browser.navigations.length, 0);
});

test('the last required passkey cannot be removed in the security UI', async () => {
  const browser = authPage({ pageName: 'security' });
  await flush();
  const row = browser.nodes.get('passkey-list').children[0];
  const remove = row.children[1];
  assert.equal(remove.disabled, true);
  assert.match(row.textContent, /Add another passkey before removing this one/);
  remove.emit('click');
  await flush();
  assert.equal(browser.confirmations.length, 0);
  assert.equal(browser.requests.some((request) => request.url === '/auth/passkey/delete'), false);
});

test('passkey removal describes only the sign-in methods that remain available', async () => {
  for (const capability of [false, true]) {
    const browser = authPage({ pageName: 'security', capability,
      passkeys: capability ? [{ id: 'key-1' }] : [{ id: 'key-1' }, { id: 'key-2' }] });
    await flush();
    const remove = browser.nodes.get('passkey-list').children[0].children[1];
    assert.equal(remove.disabled, false);
    remove.emit('click');
    await flush();
    assert.equal(browser.confirmations.length, 1);
    assert.equal(/email code/.test(browser.confirmations[0]), capability);
    assert.equal(browser.requests.some((request) => request.url === '/auth/passkey/delete'), true);
  }
});
