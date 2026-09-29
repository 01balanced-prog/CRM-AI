// CRM Даима — кэш оболочки. Данные всегда берутся из сети.
const V = 'daima-crm-v23';
// Иконки под новыми именами: под старым адресом телефон держал бы прежнюю картинку
const SHELL = ['./', './index.html', './manifest.json', './daima.svg', './daima-180.png', './daima-192.png', './daima-512.png',
  './fonts/ibm-plex-sans-cyrillic.woff2', './fonts/ibm-plex-sans-latin.woff2', './fonts/unbounded-cyrillic.woff2'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  // Запросы к базе и авторизации мимо кэша — данные должны быть свежими
  if (u.pathname.startsWith('/rest/') || u.pathname.startsWith('/auth/')) return;
  if (e.request.method !== 'GET') return;
  e.respondWith(
    fetch(e.request)
      .then(r => {
        if (r.ok && u.origin === location.origin) {
          const copy = r.clone();
          caches.open(V).then(c => c.put(e.request, copy));
        }
        return r;
      })
      .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html')))
  );
});
