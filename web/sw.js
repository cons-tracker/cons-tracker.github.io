/* Service worker — lets the app open even without internet (it shows the last data saved on the device)
   Data requests to Supabase always go to the network; they are never cached here */
const VERSION = '20261105195622';
const CACHE = 'hwprog-' + VERSION;
const SHELL = ['./', './index.html', './config.js', './cloud.js', './manifest.json',
  './icons/icon-192.png', './icons/icon-512.png', './icons/icon-maskable-512.png', './icons/apple-touch-icon.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.min.js'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => Promise.all(SHELL.map((u) => c.add(u).catch(() => null)))));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k.startsWith('hwprog-') && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (/supabase\.co$/.test(url.hostname) || url.pathname.includes('/rest/v1/') || url.pathname.includes('/auth/v1/')) return;
  if (url.hostname.endsWith('tile.openstreetmap.org') || url.hostname.endsWith('nominatim.openstreetmap.org')) return;

  const sameOrigin = url.origin === self.location.origin;
  /* app files on the site: try the network first (to get the latest version), fall back to the cache when offline */
  if (sameOrigin) {
    e.respondWith(fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req).then((r) => r || (req.mode === 'navigate' ? caches.match('./index.html') : undefined))));
    return;
  }
  /* external libraries pinned to a version (CDN): use the cache first */
  if (url.hostname === 'cdn.jsdelivr.net') {
    e.respondWith(caches.match(req).then((r) => r || fetch(req).then((res) => {
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res;
    })));
  }
});
