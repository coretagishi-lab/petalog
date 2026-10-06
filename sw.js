/* 旧アドレスの service worker を片付ける（ぺたろぐは https://petalog-stamp.github.io/ へ引っ越しました） */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (ks) { return Promise.all(ks.map(function (k) { return caches.delete(k); })); })
    .then(function () { return self.registration.unregister(); })
    .then(function () { return self.clients.matchAll({ type: "window" }); })
    .then(function (cs) { cs.forEach(function (c) { try { c.navigate(c.url); } catch (x) {} }); }));
});
