// The chat chrome (header, composer, drawer) drawn in the chat page — see
// assets/chat_webview/chrome/index.js. What a message can do to it is the
// point: nothing a card's CSS or script does may restyle it, find its nodes,
// or make it speak to Flutter.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

const STATE = {
  theme: { accent: [196, 42, 74, 1], fillHeader: [30, 30, 30, 0.8], fillSurface: [25, 25, 26, 0.8], blurSigma: 12 },
  layout: { safeTop: 24, safeBottom: 16, inset: 16, viewportH: 720, gutter: 0, fades: false,
    drawer: { show: false, height: 300, progress: 0 } },
  header: { show: true, title: 'Seraphina', session: 'Session #3', avatar: { initial: 'S' },
    search: { kind: 'mobile', open: false, hint: 'Search' } },
  composer: { show: true, mode: 'compose', placeholder: 'Message...',
    pins: [{ key: 'action:attach', icon: { cp: 57521 }, tap: true }],
    send: { icon: { cp: 62754 }, tap: true, slot: false } },
};

async function open(page) {
  await page.addInitScript(() => {
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler: (...args) => { window.__calls.push(args); return Promise.resolve(null); },
    };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.__glazeChrome);
  const keys = await page.evaluate((state) => {
    const keys = window.__glazeChrome.handshake();
    window.__glazeChrome.apply(keys.split(':')[0], JSON.stringify(state));
    return keys;
  }, STATE);
  await page.waitForTimeout(100);
  const [keyIn, keyOut] = keys.split(':');
  return { keyIn, keyOut };
}

const intents = (page, keyOut) => page.evaluate((keyOut) => window.__calls
  .filter((c) => c[0] === 'onChromeIntent' && c[1] === keyOut)
  .map((c) => JSON.parse(c[2])), keyOut);

test('the keys are handed out once, and only they drive the chrome', async ({ page }) => {
  await open(page);
  const again = await page.evaluate(() => window.__glazeChrome.handshake());
  expect(again).toBeNull();
  const forged = await page.evaluate(() => window.__glazeChrome.apply('guess', '{"header":{"show":false}}'));
  expect(forged).toBe(false);
  // The API object cannot be swapped or patched.
  const replaced = await page.evaluate(() => {
    try { window.__glazeChrome = { apply: () => true }; } catch (_) {}
    try { window.__glazeChrome.apply = () => true; } catch (_) {}
    return window.__glazeChrome.apply('guess', '{}');
  });
  expect(replaced).toBe(false);
});

test('the safe-area insets reach theme CSS as sat and sab', async ({ page }) => {
  await open(page);
  const insets = await page.evaluate(() => {
    const style = getComputedStyle(document.documentElement);
    return {
      sat: style.getPropertyValue('--sat').trim(),
      sab: style.getPropertyValue('--sab').trim(),
    };
  });
  expect(insets).toEqual({ sat: '24px', sab: '16px' });
});

test('page queries and page CSS cannot reach the chrome', async ({ page }) => {
  await open(page);
  const found = await page.evaluate(() => ({
    textareas: document.querySelectorAll('textarea').length,
    byClass: document.querySelectorAll('.gc-hdr, .gc-pill').length,
  }));
  expect(found).toEqual({ textareas: 0, byClass: 0 });
  // What a hoisted `@import` (INV-MR5) could put in the document. A sheet
  // that hides html or body takes the whole chat with it; everything short of
  // that must leave the chrome alone.
  await page.addStyleTag({ content: `
    body > *, body > * > *, [popover], [popover]:popover-open, *::backdrop {
      display: none !important; opacity: 0 !important; visibility: hidden !important;
      transform: translateY(-9999px) !important; z-index: -1 !important;
    }
  ` });
  await page.waitForTimeout(50);
  const shown = await page.evaluate(() => {
    const host = document.elementFromPoint(200, 70);
    const style = host && getComputedStyle(host);
    return { tag: host && host.tagName.toLowerCase(), display: style && style.display, opacity: style && style.opacity };
  });
  expect(shown.tag).toMatch(/^glaze-/);
  expect(shown.display).toBe('block');
  expect(shown.opacity).toBe('1');
});

test('a removed host is put back', async ({ page }) => {
  await open(page);
  await page.evaluate(() => {
    for (const el of document.body.children) if (el.tagName.startsWith('GLAZE-')) el.remove();
  });
  await page.waitForTimeout(50);
  const back = await page.evaluate(() => [...document.body.children].some((el) => el.tagName.startsWith('GLAZE-')));
  expect(back).toBe(true);
});

test('only trusted input becomes an intent', async ({ page }) => {
  const { keyOut } = await open(page);
  // A synthetic click at the back button, and a forged intent with no key.
  await page.evaluate(() => {
    const host = document.elementFromPoint(40, 60);
    host.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true, clientX: 40, clientY: 60 }));
    window.flutter_inappwebview.callHandler('onChromeIntent', 'nope', '{"t":"back"}');
  });
  expect((await intents(page, keyOut)).filter((i) => i.t === 'back')).toHaveLength(0);
  // A real tap on it does.
  await page.mouse.click(42, 62);
  expect((await intents(page, keyOut)).filter((i) => i.t === 'back')).toHaveLength(1);
});

test('typing reports the text, and a patched prototype sees no chrome node', async ({ page }) => {
  const { keyIn, keyOut } = await open(page);
  await page.evaluate(() => {
    window.__leaked = [];
    const orig = Node.prototype.appendChild;
    Node.prototype.appendChild = function (child) { window.__leaked.push(child); return orig.call(this, child); };
    const set = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent').set;
    Object.defineProperty(Node.prototype, 'textContent', {
      set(v) { window.__leaked.push(this); set.call(this, v); }, configurable: true,
    });
  });
  const layout = (await intents(page, keyOut)).filter((i) => i.t === 'layout').at(-1).d;
  const [x, y, w, h] = layout.composer;
  const cx = x + w / 2;
  const cy = y + h / 2;
  const box = await page.evaluate(([cx, cy]) => document.elementFromPoint(cx, cy).tagName, [cx, cy]);
  expect(box).toMatch(/^GLAZE-/);
  await page.mouse.click(cx, cy);
  await page.keyboard.type('hello');
  const texts = (await intents(page, keyOut)).filter((i) => i.t === 'text').map((i) => i.d.v);
  expect(texts.at(-1)).toBe('hello');
  // Re-render something in the chrome after the patch went in.
  await page.evaluate((key) => window.__glazeChrome.apply(key, JSON.stringify({
    header: { title: 'Renamed', session: 'Session #4' },
    composer: { pins: [{ key: 'action:fullscreen', icon: { cp: 58059 }, tap: true }] },
  })), keyIn);
  const leaked = await page.evaluate(() => window.__leaked.length);
  expect(leaked).toBe(0);
});

test('the send button follows the field on every keystroke, without Flutter', async ({ page }) => {
  const { keyIn, keyOut } = await open(page);
  // Dead while empty, live once something is typed — as in edit mode.
  await page.evaluate((key) => window.__glazeChrome.apply(key, JSON.stringify({
    composer: { send: { icon: { cp: 62754 }, tap: false, slot: false, faces: {
      empty: { icon: { cp: 57415 }, tap: false },
      guide: { icon: { cp: 57686 }, tap: true },
      content: { icon: { cp: 62754 }, tap: true },
    } } },
    text: { v: '', rev: 3 },
  })), keyIn);
  const all = await intents(page, keyOut);
  const layout = all.filter((i) => i.t === 'layout').at(-1).d;
  const [x, y, w, h] = layout.composer;
  const [sx, sy, sw, sh] = layout.send;
  const sends = async () => (await intents(page, keyOut)).filter((i) => i.t === 'sendTap');
  await page.mouse.click(sx + sw / 2, sy + sh / 2);
  expect(await sends()).toHaveLength(0);
  await page.mouse.click(x + w / 2, y + h / 2);
  await page.keyboard.type('hi');
  // No state came back from Flutter in between.
  await page.mouse.click(sx + sw / 2, sy + sh / 2);
  expect((await sends()).map((i) => i.d.v)).toEqual(['hi']);
  // Each change carries the revision of the text Flutter last wrote.
  const texts = (await intents(page, keyOut)).filter((i) => i.t === 'text');
  expect(texts.at(-1).d).toEqual({ v: 'hi', rev: 3 });
});

test('plugin chat panels draw over the chrome', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  const { keyOut } = await open(page);
  await page.evaluate(async () => {
    window.__toasts = [];
    const handler = window.flutter_inappwebview.callHandler;
    window.flutter_inappwebview.callHandler = (name, req, ...rest) => {
      if (name === 'pluginBridge' && req && req.method === 'ui.toast') window.__toasts.push(req.params);
      return handler(name, req, ...rest);
    };
    const sdk = await (await fetch('/assets/chat_webview/plugins/plugin_sdk.js')).text();
    window.glazePlugins.setup({
      sdk,
      plugins: [{
        pluginId: 'p', compat: null, main: null, config: {}, i18n: null,
        vars: { chat: {}, global: {} }, storage: {}, methods: ['ui.toast'], events: [],
        messageActions: [],
        panels: [{
          id: 'top', placement: 'chat', order: 1,
          // A button right over the header's back arrow.
          html: `<button id="b" style="position:fixed;left:16px;top:34px;width:60px;height:56px"
                   onclick="glaze.ui.toast('panel')">x</button>`,
        }],
      }],
    });
  });
  const frame = page.locator('iframe[data-glaze-plugin="p"]');
  await expect.poll(() => frame.evaluate((el) => el.style.clipPath)).toContain('path(');
  // The panel is in the top layer, after the chrome.
  const order = await page.evaluate(() => {
    const frame = document.querySelector('iframe[data-glaze-plugin="p"]');
    return { open: frame.matches(':popover-open'), top: document.elementFromPoint(40, 60) === frame };
  });
  expect(order).toEqual({ open: true, top: true });
  // A tap there is the panel's, not the back button's.
  await page.mouse.click(40, 60);
  await expect.poll(() => page.evaluate(() => window.__toasts.length)).toBe(1);
  expect((await intents(page, keyOut)).filter((i) => i.t === 'back')).toHaveLength(0);
  // Outside the panel the chrome is still there to tap.
  await page.mouse.click(370, 62);
  await expect.poll(async () => (await intents(page, keyOut)).filter((i) => i.t === 'searchOpen').length).toBe(1);
  // Another element entering the top layer raises the chrome, and the panel
  // is put back over it.
  await page.evaluate(() => {
    const d = document.createElement('div');
    d.setAttribute('popover', 'manual');
    document.body.appendChild(d);
    d.showPopover();
  });
  await page.waitForTimeout(50);
  expect(await page.evaluate(() =>
    document.elementFromPoint(40, 60) === document.querySelector('iframe[data-glaze-plugin="p"]'))).toBe(true);
});
