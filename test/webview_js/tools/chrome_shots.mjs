// Draws the chat chrome in the real chat page for the scenes
// test/chat_chrome_golden_test.dart wrote out, and puts each next to the
// Flutter chrome it replaced.
//
//   GLAZE_GOLDENS=1 flutter test --update-goldens test/chat_chrome_golden_test.dart
//   cd test/webview_js && node tools/chrome_shots.mjs
//
// Output: test-results/chat_chrome/after_<scene>.png and compare_<scene>.png.
import { spawn } from 'node:child_process';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const ROOT = resolve(fileURLToPath(new URL('.', import.meta.url)), '..', '..', '..');
const OUT = resolve(ROOT, 'test-results', 'chat_chrome');
const PORT = 4183;
const BANDS = ['#26323A', '#6A3D5A', '#2E4B3F', '#8A6A2E', '#3B3466'];

const server = spawn('node', ['test/webview_js/harness/server.js'], {
  cwd: ROOT,
  env: { ...process.env, GLAZE_WEBVIEW_TEST_PORT: String(PORT) },
});
await new Promise((r) => setTimeout(r, 500));
const font = `data:font/ttf;base64,${readFileSync(resolve(ROOT, 'assets/fonts/InterVariable.ttf')).toString('base64')}`;
// No hinting: glyph advances stay fractional, the way Flutter and the phones
// lay text out. Hinted, headless Chrome on Linux sets text ~3% wider.
const browser = await chromium.launch({ args: ['--font-render-hinting=none'] });

async function scene(name, extra) {
  const state = JSON.parse(readFileSync(resolve(OUT, `state_${name}.json`), 'utf8'));
  const page = await browser.newPage({ viewport: { width: 412, height: 860 }, deviceScaleFactor: 2 });
  await page.addInitScript(() => {
    window.__calls = [];
    window.flutter_inappwebview = { callHandler: (...args) => { window.__calls.push(args); return Promise.resolve(null); } };
  });
  page.on('pageerror', (e) => console.log(`[${name}] pageerror`, e.message));
  await page.goto(`http://127.0.0.1:${PORT}/assets/chat_webview/index.html`);
  await page.waitForFunction(() => !!window.__glazeChrome);
  await page.evaluate((bands) => {
    document.documentElement.style.background = '#121212';
    const c = document.getElementById('chat-container');
    for (let i = 0; i < 20; i++) {
      const band = document.createElement('div');
      band.style.cssText = `height:43px;background:${bands[i % bands.length]}`;
      c.appendChild(band);
    }
    document.getElementById('loading-screen').style.display = 'none';
  }, BANDS);
  await page.evaluate(({ state, font, extra }) => {
    const key = window.__glazeChrome.handshake().split(':')[0];
    const msg = {
      theme: state.theme,
      font: { data: font, weights: '100 900' },
      layout: state.layout,
      header: state.header,
      composer: state.composer,
      text: state.text,
      ...(state.drawer ? { drawer: state.drawer } : {}),
      ...(extra || {}),
    };
    window.__glazeChrome.apply(key, JSON.stringify(msg));
  }, { state, font, extra });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(400);
  await page.screenshot({ path: resolve(OUT, `after_${name}.png`) });
  await page.close();
}

async function compare(name) {
  const before = resolve(ROOT, 'test', 'goldens', `chat_chrome_before_${name}.png`);
  if (!existsSync(before)) return;
  const after = resolve(OUT, `after_${name}.png`);
  const b64 = (p) => `data:image/png;base64,${readFileSync(p).toString('base64')}`;
  const page = await browser.newPage({ viewport: { width: 860, height: 900 }, deviceScaleFactor: 2 });
  await page.setContent(`<body style="margin:0;background:#000;font:13px sans-serif;color:#ccc;display:flex;gap:12px;padding:8px">
    <figure style="margin:0"><figcaption>Flutter (before)</figcaption><img src="${b64(before)}" width="412"></figure>
    <figure style="margin:0"><figcaption>WebView (after)</figcaption><img src="${b64(after)}" width="412"></figure></body>`);
  await page.screenshot({ path: resolve(OUT, `compare_${name}.png`), fullPage: true });
  await page.close();
}

const scenes = readdirSync(OUT)
  .filter((f) => /^state_.*\.json$/.test(f))
  .map((f) => f.slice(6, -5));
for (const name of scenes) {
  await scene(name);
  await compare(name);
  console.log('shot', name);
}
await browser.close();
server.kill();
