// FluviFinance — service worker SEM cache (v2.2 §3.2 item 9, §7): existe só para a PWA
// instalável. Não intercepta requisições (sem handler de fetch) e apaga qualquer cache
// deixado por versões anteriores: nenhum dado financeiro fica guardado no aparelho.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) await caches.delete(key);
    await self.clients.claim();
  })());
});
