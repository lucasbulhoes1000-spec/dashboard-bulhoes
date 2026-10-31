// Service worker do Lume (backoffice da Bulhões): recebe as notificações (avaliação agendada, venda fechada).
// Não guarda páginas em cache: o app sempre abre a versão mais nova do site.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { titulo: 'Lume', corpo: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'Lume', {
    body: d.corpo || '',
    icon: '/icone-192.png',
    badge: '/icone-192.png',
    tag: d.tag || undefined,
    data: { url: d.url || '/' },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || '/', self.location.origin).href;
  e.waitUntil((async () => {
    const janelas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of janelas) {
      if (new URL(w.url).origin === self.location.origin) {
        try { await w.navigate(url); } catch (_) { /* segue */ }
        return w.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
