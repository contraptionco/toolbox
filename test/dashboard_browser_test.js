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
