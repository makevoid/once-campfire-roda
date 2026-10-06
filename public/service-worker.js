"use strict";
self.addEventListener("push", event => {
  if (!event.data) return;
  const payload = event.data.json();
  event.waitUntil(self.registration.showNotification(payload.title, payload.options));
});
self.addEventListener("notificationclick", event => {
  event.notification.close();
  const path = event.notification.data?.path || "/";
  const url = new URL(path, self.location.origin);
  if (url.origin !== self.location.origin) return;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({type: "window"});
    const window = windows.find(client => client.focused) || windows[0];
    if (window) { await window.navigate(url.href); await window.focus(); }
    else await self.clients.openWindow(url.href);
  })());
});
