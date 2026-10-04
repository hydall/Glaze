// Static file server for the WebView asset tests.
//
// The harness page imports the production modules by their real paths
// (`/assets/chat_webview/formatter/index.js`), so the tests exercise exactly
// the files the app ships. ES modules cannot be imported over `file://`, hence
// a server rather than a bare page load.
import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
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
