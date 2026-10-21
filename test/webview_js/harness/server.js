// Static file server for the WebView asset tests.
//
// The harness page imports the production modules by their real paths
// (`/assets/chat_webview/formatter/index.js`), so the tests exercise exactly
// the files the app ships. ES modules cannot be imported over `file://`, hence
// a server rather than a bare page load.
import { createServer } from 'node:http';
import { createReadStream, readFileSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..', '..');
const PORT = Number(process.env.GLAZE_WEBVIEW_TEST_PORT || 4176);

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
};

const server = createServer(async (request, response) => {
  const url = new URL(request.url, `http://127.0.0.1:${PORT}`);
  // normalize() collapses `..`, and the prefix check keeps a crafted path from
  // reading outside the repository.
  const target = join(REPO_ROOT, normalize(decodeURIComponent(url.pathname)));
  if (!target.startsWith(REPO_ROOT)) {
    response.writeHead(403).end('forbidden');
    return;
  }
  try {
    const info = await stat(target);
    if (!info.isFile()) throw new Error('not a file');
  } catch {
    response.writeHead(404).end('not found');
    return;
  }
  response.writeHead(200, {
    'content-type': TYPES[extname(target)] || 'application/octet-stream',
    'cache-control': 'no-store',
  });
  createReadStream(target).pipe(response);
});

server.listen(PORT, '127.0.0.1');

// Stands in for the app's plugin package server
// (lib/features/plugins/runtime/plugin_package_server.dart): package files at
// `/plugins/<id>/<path>` with the same headers, and frame documents the host
// hands over (`frames.open`, here a POST to /__frames) served once.
const PACKAGE_PORT = Number(process.env.GLAZE_WEBVIEW_TEST_PACKAGE_PORT || 4177);
const PACKAGES = {
  'pk/style.css': '@font-face{font-family:PkFont;src:url(fonts/inter.ttf)}#x{color:rgb(1,2,3);font-family:PkFont}',
  'pk/fonts/inter.ttf': () => readFileSync(join(REPO_ROOT, 'assets', 'fonts', 'InterVariable.ttf')),
  'pk/data.json': '{"ok":1}',
  // Finds the package the way Academy does: from its own address.
  'pk/ui/probe.js': `(async () => {
    const say = window.tavo ? tavo.utils.toast : glaze.ui.toast;
    try {
      const root = new URL('../', new URL('/plugins/pk/ui/probe.js', location.href)).href;
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = new URL('style.css', root).href;
      await new Promise((ok, no) => { link.onload = ok; link.onerror = no; document.head.append(link); });
      const fonts = await document.fonts.load('16px PkFont');
      const data = await (await fetch(new URL('data.json', root))).text();
      let other = 'read';
      try { await fetch('/plugins/other/secret.txt'); } catch (e) { other = 'blocked'; }
      say([getComputedStyle(document.getElementById('x')).color, fonts.length, data, other].join('|'));
    } catch (e) { say('failed: ' + e.message); }
  })();`,
  'pk/page.html': '<script>parent.postMessage("raw page ran", "*")</script>',
  'other/secret.txt': 'secret',
};
const PACKAGE_TYPES = { ...TYPES, '.ttf': 'font/ttf', '.txt': 'text/plain; charset=utf-8' };
const frameDocs = new Map();

createServer((request, response) => {
  const url = new URL(request.url, `http://127.0.0.1:${PACKAGE_PORT}`);
  if (url.pathname === '/__frames' && request.method === 'POST') {
    let body = '';
    request.on('data', (c) => { body += c; });
    request.on('end', () => {
      const { pluginId, path, doc } = JSON.parse(body);
      const key = Math.random().toString(36).slice(2);
      frameDocs.set(key, { pluginId, path, doc });
      response.writeHead(200, { 'access-control-allow-origin': '*' });
      response.end(`http://127.0.0.1:${PACKAGE_PORT}/plugins/${pluginId}/${path}?glaze-frame=${key}`);
    });
    return;
  }
  const m = /^\/plugins\/([a-z0-9._-]+)\/(.+)$/.exec(url.pathname);
  if (!m) { response.writeHead(404).end(); return; }
  const key = url.searchParams.get('glaze-frame');
  if (key) {
    const frame = frameDocs.get(key);
    if (!frame || frame.pluginId !== m[1] || frame.path !== m[2]) { response.writeHead(404).end(); return; }
    frameDocs.delete(key);
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    response.end(frame.doc);
    return;
  }
  const file = PACKAGES[m[1] + '/' + m[2]];
  if (file === undefined) { response.writeHead(404).end(); return; }
  response.writeHead(200, {
    'content-type': PACKAGE_TYPES[extname(m[2])] || 'application/octet-stream',
    'cache-control': 'no-store',
    'access-control-allow-origin': '*',
    'x-content-type-options': 'nosniff',
    'content-security-policy': "default-src 'none'; sandbox",
  });
  response.end(typeof file === 'function' ? file() : file);
}).listen(PACKAGE_PORT, '127.0.0.1');
