const CACHE_NAME = "darwin-switch-cockpit-v33";

const APP_SHELL = [
  "/",
  "/index.html",
  "/setup.html",
  "/styles.css",
  "/app.js",
  "/setup.js",
  "/robot3d.js",
  "/model-check.html",
  "/manifest.webmanifest",
  "/assets/darwin-icon.png",
  "/assets/darwin.glb",
  "/vendor/three.module.min.js",
  "/vendor/GLTFLoader.js",
  "/vendor/BufferGeometryUtils.js"
];

const MUTABLE_SHELL = new Set([
  "/",
  "/index.html",
  "/setup.html",
  "/model-check.html",
  "/styles.css",
  "/app.js",
  "/setup.js",
  "/robot3d.js",
  "/sw.js",
  "/manifest.webmanifest"
]);

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(
        names.filter((name) => name !== CACHE_NAME).map((name) => caches.delete(name))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  if (shouldBypassCache(url)) {
    return;
  }

  if (event.request.mode === "navigate") {
    event.respondWith(networkFirst(event.request, "/index.html"));
    return;
  }

  if (MUTABLE_SHELL.has(url.pathname)) {
    event.respondWith(networkFirst(event.request, url.pathname));
    return;
  }

  event.respondWith(cacheFirst(event.request));
});

function shouldBypassCache(url) {
  if (url.pathname.startsWith("/api/")) return true;
  const action = url.searchParams.get("action");
  return action === "stream" || action === "snapshot";
}

async function networkFirst(request, fallbackPath) {
  const cache = await caches.open(CACHE_NAME);
  try {
    const response = await fetch(request);
    if (response.ok) await cache.put(request, response.clone());
    return response;
  } catch (_err) {
    return (await cache.match(request)) || cache.match(fallbackPath);
  }
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok) await cache.put(request, response.clone());
  return response;
}
