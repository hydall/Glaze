// The Tavo-compatible plugin host: sandboxed frames, identity stamping,
// blocking hooks, events and the clipped fragment overlay.
import { test, expect } from '@playwright/test';

const URL = '/test/webview_js/harness/plugins.html';

async function setup(page, plugins) {
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(URL);
  await page.evaluate(async (list) => {
    const sdk = await (await fetch('/assets/chat_webview/plugins/tavo_sdk.js')).text();
    window.glazePlugins.setup({ sdk, plugins: list });
  }, plugins);
  return errors;
}

function plugin(id, extra) {
  return {
    pluginId: id,
    entry: null,
    fragments: [],
    config: {},
    i18n: null,
    vars: { chat: { greeting: 'hi' }, global: {} },
    storage: {},
    methods: ['variable.get', 'message.count', 'utils.toast'],
    ...extra,
  };
}

async function calls(page, method) {
  return page.evaluate((m) => window.__calls.filter((c) => c.request.method === m), method);
}

test('input:beforeSend handlers rewrite and cancel in plugin order', async ({ page }) => {
  await setup(page, [
    plugin('a', {
      entry: `tavo.plugin.on('input:beforeSend', (e) => { e.text = e.text.toUpperCase(); });`,
    }),
    plugin('b', {
      entry: `tavo.plugin.on('input:beforeSend', (e) => { if (e.text.includes('STOP')) e.cancel('nope'); else e.text += '!'; });`,
    }),
  ]);
  await expect.poll(() => page.evaluate(() => window.glazePlugins.hasSubscribers('input:beforeSend'))).toBe(true);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.intercept('input:beforeSend', { text: 'hello' }).then((r) => r.text))).toBe('HELLO!');
  const cancelled = await page.evaluate(() =>
    window.glazePlugins.intercept('input:beforeSend', { text: 'stop' }));
  expect(cancelled).toMatchObject({ cancelled: true, cancelledBy: 'b', message: 'nope', text: 'STOP' });
});

test('a throwing handler keeps the text and the chain going', async ({ page }) => {
  await setup(page, [
    plugin('a', { entry: `tavo.plugin.on('generation:prepare', (e) => { e.text = 'lost'; throw new Error('x'); });` }),
    plugin('b', { entry: `tavo.plugin.on('generation:prepare', async (e) => { e.text = e.text + ' +ctx'; });` }),
  ]);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.intercept('generation:prepare', { text: 'q' }).then((r) => r.text))).toBe('q +ctx');
});

test('calls carry the identity of the frame, not what the plugin claims', async ({ page }) => {
  await setup(page, [
    plugin('honest', {
      entry: `
        tavo.variable.get('k').then((v) => tavo.utils.toast(String(v)));
        parent.postMessage({ type: 'tavo:call', id: 'x', method: 'utils.toast', params: ['spoof'], pluginId: 'other' }, '*');
      `,
    }),
  ]);
  await expect.poll(async () => (await calls(page, 'utils.toast')).length).toBe(2);
  const toasts = await calls(page, 'utils.toast');
  for (const c of toasts) expect(c.request.pluginId).toBe('honest');
  expect(toasts.map((c) => c.request.params[0])).toContain('value-for-honest');
});

test('plugin frames are sandboxed away from the chat page', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      entry: `
        let leaked = 'blocked';
        try { leaked = String(parent.document.title); } catch (e) {}
        try { if (parent.flutter_inappwebview) leaked = 'bridge'; } catch (e) {}
        tavo.utils.toast(leaked);
      `,
    }),
  ]);
  await expect.poll(async () => (await calls(page, 'utils.toast')).map((c) => c.request.params[0])).toEqual(['blocked']);
  const sandbox = await page.locator('iframe[data-glaze-plugin="p"]').getAttribute('sandbox');
  expect(sandbox).toBe('allow-scripts');
});

test('only granted methods exist on the scoped tavo object', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      methods: ['utils.toast'],
      entry: `tavo.utils.toast([typeof tavo.message.count, typeof tavo.input.get, typeof tavo.plugin.on].join(','));`,
    }),
  ]);
  await expect.poll(async () => (await calls(page, 'utils.toast')).map((c) => c.request.params[0]))
    .toEqual(['undefined,undefined,function']);
});

test('emit reaches the plugin\'s other frames; events reach all frames', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      entry: `tavo.plugin.on('chat:opened', (e) => tavo.plugin.emit('ping', { chat: e.chatId }));`,
      fragments: [{
        id: 'f',
        order: 10,
        html: `<script>tavo.plugin.on('ping', (d) => tavo.utils.toast('got ' + d.chat));</script>`,
      }],
    }),
  ]);
  // Frames load asynchronously; the host queues the event until each is ready.
  await page.evaluate(() => window.glazePlugins.dispatchEvent('chat:opened', { chatId: 'c1' }));
  await expect.poll(async () => (await calls(page, 'utils.toast')).map((c) => c.request.params[0])).toEqual(['got c1']);
});

test('a fragment takes taps only where it draws', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await setup(page, [
    plugin('p', {
      fragments: [{
        id: 'fab',
        order: 10,
        html: `
          <style>#fab { position: fixed; right: 20px; bottom: calc(var(--tavo-inset-bottom-input, 0px) + 10px); width: 80px; height: 40px; }</style>
          <div id="root" style="position:fixed;left:0;top:0;width:0;height:0">
            <button id="fab" onclick="tavo.utils.toast('fab')">fab</button>
          </div>`,
      }],
    }),
  ]);
  const frame = page.locator('iframe[data-glaze-plugin="p"]');
  await expect.poll(() => frame.evaluate((el) => el.style.clipPath)).toContain('path(');
  // Bottom inset 80 → button spans y 570..610, x 300..380.
  await page.mouse.click(340, 590);
  await expect.poll(async () => (await calls(page, 'utils.toast')).length).toBe(1);
  await page.mouse.click(100, 300);
  expect(await page.evaluate(() => window.__underClicks || 0)).toBe(1);
});

test('the sync variable cache and the storage shim', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      storage: { kept: 'yes' },
      entry: `
        localStorage.setItem('n', '1');
        tavo.utils.toast([tavo.get('greeting'), localStorage.getItem('kept'), localStorage.getItem('n'), localStorage.length].join('|'));
      `,
    }),
  ]);
  await expect.poll(async () => (await calls(page, 'utils.toast')).map((c) => c.request.params[0])).toEqual(['hi|yes|1|2']);
  const stored = await calls(page, 'storage.set');
  expect(stored[0].request.params).toEqual({ key: 'n', value: '1' });
});

test('actions run the entry handler and report a missing one', async ({ page }) => {
  await setup(page, [
    plugin('p', { entry: `tavo.plugin.onInputAction('go', async () => { await tavo.utils.toast('went'); });` }),
  ]);
  await expect.poll(() => page.evaluate(() => window.glazePlugins.runAction('p', 'inputActions:go'))).toEqual({ ok: true });
  expect(await page.evaluate(() => window.glazePlugins.runAction('p', 'inputActions:nope')))
    .toEqual({ ok: false, reason: 'missing-handler' });
});
