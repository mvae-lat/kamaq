/* Kamaq — Service Worker (PWA).
   Estrategia network-first SOLO para navegación: siempre trae el sitio fresco
   (el deploy cambia index.html seguido) y cae a la copia cacheada si no hay red.
   Las llamadas a Supabase / fuentes / imágenes NO se interceptan → pasan directo. */
const CACHE = 'kamaq-v1';

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET' || req.mode !== 'navigate') return;
  e.respondWith(
    fetch(req)
      .then(r => { const c = r.clone(); caches.open(CACHE).then(ca => ca.put('/', c)); return r; })
      .catch(() => caches.match('/').then(r => r || new Response('Sin conexión — vuelve a intentar.', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } })))
  );
});

/* Base para notificaciones push (se activa cuando montemos el backend de push + VAPID). */
self.addEventListener('push', (e) => {
  let data = {};
  try { data = e.data ? e.data.json() : {}; } catch (_) {}
  const title = data.title || 'Kamaq';
  e.waitUntil(self.registration.showNotification(title, {
    body: data.body || '',
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    data: { url: data.url || '/' }
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(clients.openWindow((e.notification.data && e.notification.data.url) || '/'));
});
