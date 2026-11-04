// Fonctionnement hors ligne : l'app est mise en cache à la première ouverture.
// Les fichiers lourds (lecture des scans) sont mis en cache au premier usage.
const VERSION = 'v1.0.0';
const CORE = [
  './', 'index.html', 'manifest.webmanifest', 'css/app.css',
  'js/app.js', 'js/fiscal.js', 'js/db.js', 'js/extract.js', 'js/export.js',
  'vendor/preact-htm.mjs', 'vendor/pdfjs/pdf.min.mjs', 'vendor/pdfjs/pdf.worker.min.mjs',
  'vendor/jspdf.umd.min.js', 'vendor/jspdf.plugin.autotable.min.js',
  'icons/icon-180.png', 'icons/icon-192.png', 'icons/icon-512.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(CORE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION && k !== 'ocr').map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;

  // Fichiers de reconnaissance de texte : cache permanent, téléchargés une seule fois
  if (url.pathname.includes('/vendor/tesseract/')) {
    e.respondWith(caches.open('ocr').then(async (c) => {
      const hit = await c.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res.ok) c.put(req, res.clone());
      return res;
    }));
    return;
  }

  // Reste de l'app : réseau d'abord (mises à jour), cache si hors ligne
  e.respondWith(
    fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then((hit) => hit || caches.match('index.html')))
  );
});
