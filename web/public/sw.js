'use strict';
// Only generic, static assets are stored. Navigations, host metrics, logs and
// Cloudflare authentication responses are NEVER cached or replayed offline.
const CACHE = 'toolbox-shell-v1';
const ASSETS = ['/offline.html', '/style.css', '/app.js', '/manifest.webmanifest', '/icons/icon.svg', '/icons/icon-192.png', '/icons/icon-512.png', '/icons/apple-touch-icon.png'];
self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    for (const asset of ASSETS) {
      const response = await fetch(asset, { cache: 'reload', redirect: 'error' });
      if (!response.ok || response.redirected) throw new Error('Static asset unavailable');
      // An expired Access session must never turn a login page into an asset.
      const contentType = response.headers.get('content-type') || '';
      if (asset !== '/offline.html' && contentType.includes('text/html')) throw new Error('Authentication required');
      await cache.put(asset, response);
    }
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) if (name.startsWith('toolbox-shell-') && name !== CACHE) await caches.delete(name);
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/cdn-cgi/') || url.pathname === '/healthz') return;
  if (event.request.mode === 'navigate') {
    event.respondWith(fetch(event.request).catch(async () => (await caches.match('/offline.html')) || new Response('Toolbox is offline. Reconnect to view live readings.', { headers: { 'Content-Type': 'text/plain; charset=utf-8' } })));
    return;
  }
  if (!ASSETS.includes(url.pathname) || url.search) return;
  // Network first keeps releases current; fallback includes no private data.
  event.respondWith(fetch(event.request).catch(() => caches.match(url.pathname)));
});
self.addEventListener('message', (event) => {
  if (event.data?.type === 'CLEAR_TOOLBOX_CACHE') event.waitUntil((async () => {
    for (const name of await caches.keys()) if (name.startsWith('toolbox-shell-')) await caches.delete(name);
  })());
});
