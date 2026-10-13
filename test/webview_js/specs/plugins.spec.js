// The plugin host: sandboxed frames, identity stamping, blocking hooks,
// events, the clipped panel overlay and the Tavo compatibility layer.
import fs from 'node:fs';
import { test, expect } from '@playwright/test';

const URL = '/test/webview_js/harness/plugins.html';

async function setup(page, plugins, extra = {}) {
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(URL);
  await page.evaluate(async ({ list, extra }) => {
    const load = async (p) => (await fetch('/assets/chat_webview/plugins/' + p)).text();
    const sdk = await load('plugin_sdk.js');
    const tavo = await load('compat/tavo_compat.js');
    window.glazePlugins.setup({ sdk, compat: { tavo }, plugins: list, ...extra });
  }, { list: plugins, extra });
  return errors;
}

// The WebView's document-start guard, read from the Dart source and injected
// into every frame the way the WebView does it.
function guardSource(key) {
  const dart = fs.readFileSync(new globalThis.URL('../../../lib/features/chat/bridge/chat_webview_environment.dart', import.meta.url), 'utf8');
  const body = /String _subframeGuardSource\(\) =>\s*'''([\s\S]*?)''';/.exec(dart)[1];
  return body.replace('$chatWebViewRtcToken', key);
}

function plugin(id, extra) {
  return {
    pluginId: id,
    compat: null,
    main: null,
    panels: [],
    config: {},
    i18n: null,
    vars: { chat: { greeting: 'hi' }, global: {} },
    storage: {},
    methods: ['variables.get', 'messages.count', 'ui.toast'],
    events: ['send', 'generation', 'chat', 'message'],
    messageActions: [],
    ...extra,
  };
}

async function calls(page, method) {
  return page.evaluate((m) => window.__calls.filter((c) => c.request.method === m), method);
}

async function toasts(page) {
  return (await calls(page, 'ui.toast')).map((c) => c.request.params[0]);
}

test('send:before handlers rewrite and cancel in plugin order', async ({ page }) => {
  await setup(page, [
    plugin('a', {
      main: `glaze.plugin.on('send:before', (e) => { e.text = e.text.toUpperCase(); });`,
    }),
    plugin('b', {
      main: `glaze.plugin.on('send:before', (e) => { if (e.text.includes('STOP')) e.cancel('nope'); else e.text += '!'; });`,
    }),
  ]);
  await expect.poll(() => page.evaluate(() => window.glazePlugins.hasSubscribers('send:before'))).toBe(true);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.intercept('send:before', { text: 'hello' }).then((r) => r.text))).toBe('HELLO!');
  const cancelled = await page.evaluate(() =>
    window.glazePlugins.intercept('send:before', { text: 'stop' }));
  expect(cancelled).toMatchObject({ cancelled: true, cancelledBy: 'b', message: 'nope', text: 'STOP' });
});

test('a throwing handler keeps the text and the chain going', async ({ page }) => {
  await setup(page, [
    plugin('a', { main: `glaze.plugin.on('generation:prepare', (e) => { e.text = 'lost'; throw new Error('x'); });` }),
    plugin('b', { main: `glaze.plugin.on('generation:prepare', async (e) => { e.text = e.text + ' +ctx'; });` }),
  ]);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.intercept('generation:prepare', { text: 'q' }).then((r) => r.text))).toBe('q +ctx');
});

test('generation:success may not empty the reply', async ({ page }) => {
  await setup(page, [
    plugin('a', { main: `glaze.plugin.on('generation:success', (e) => { e.text = ''; });` }),
    plugin('b', { main: `glaze.plugin.on('generation:success', (e) => { e.text = e.text + ' [b]'; });` }),
  ]);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.intercept('generation:success', { text: 'reply' }).then((r) => r.text))).toBe('reply [b]');
});

test('calls carry the identity of the frame, not what the plugin claims', async ({ page }) => {
  await setup(page, [
    plugin('honest', {
      main: `
        // The message prefix is learned from the host's first reply.
        addEventListener('message', (e) => {
          const t = e.data && e.data.type;
          if (typeof t !== 'string' || !t.endsWith('result') || window.__sent) return;
          window.__sent = true;
          top.postMessage({ type: t.slice(0, -6) + 'call', id: 'x', method: 'ui.toast', params: ['spoof'], pluginId: 'other' }, '*');
        });
        glaze.variables.get('k').then((v) => glaze.ui.toast(String(v)));
      `,
    }),
  ]);
  await expect.poll(async () => (await calls(page, 'ui.toast')).length).toBe(2);
  const all = await calls(page, 'ui.toast');
  for (const c of all) expect(c.request.pluginId).toBe('honest');
  expect(all.map((c) => c.request.params[0])).toContain('value-for-honest');
  expect(all[0].name).toBe('pluginBridge');
});

test('plugin frames are sandboxed away from the chat page', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      main: `
        let leaked = 'blocked';
        try { leaked = String(top.document.title); } catch (e) {}
        try { if (top.flutter_inappwebview) leaked = 'bridge'; } catch (e) {}
        glaze.ui.toast(leaked);
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['blocked']);
  const sandbox = await page.locator('iframe[data-glaze-plugin="p"]').getAttribute('sandbox');
  expect(sandbox).toBe('allow-scripts');
});

test('only granted methods exist on the glaze object', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      methods: ['ui.toast'],
      main: `glaze.ui.toast([typeof glaze.messages, typeof glaze.composer, typeof glaze.plugin.on].join(','));`,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['undefined,undefined,function']);
});

test('emit reaches the plugin\'s other frames; events reach all frames', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      main: `glaze.plugin.on('chat:opened', (e) => glaze.plugin.emit('ping', { chat: e.chatId }));`,
      panels: [{
        id: 'f',
        placement: 'chat',
        order: 10,
        html: `<script>glaze.plugin.on('ping', (d) => glaze.ui.toast('got ' + d.chat));</script>`,
      }],
    }),
  ]);
  // Frames load asynchronously; the host queues the event until each is ready.
  await page.evaluate(() => window.glazePlugins.dispatchEvent('chat:opened', { chatId: 'c1' }));
  await expect.poll(() => toasts(page)).toEqual(['got c1']);
});

test('a panel takes taps only where it draws', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await setup(page, [
    plugin('p', {
      panels: [{
        id: 'fab',
        placement: 'chat',
        order: 10,
        html: `
          <style>#fab { position: fixed; right: 20px; bottom: calc(var(--glaze-inset-bottom-input, 0px) + 10px); width: 80px; height: 40px; }</style>
          <div id="root" style="position:fixed;left:0;top:0;width:0;height:0">
            <button id="fab" onclick="glaze.ui.toast('fab')">fab</button>
          </div>`,
      }],
    }),
  ]);
  const frame = page.locator('iframe[data-glaze-plugin="p"]');
  await expect.poll(() => frame.evaluate((el) => el.style.clipPath)).toContain('path(');
  // Bottom inset 80 → button spans y 570..610, x 300..380.
  await page.mouse.click(340, 590);
  await expect.poll(async () => (await calls(page, 'ui.toast')).length).toBe(1);
  await page.mouse.click(100, 300);
  expect(await page.evaluate(() => window.__underClicks || 0)).toBe(1);
  // The app is told the same area, so its own controls leave it free.
  const holes = () => page.evaluate(() => window.__calls.filter((c) => c.name === 'pluginHoles').map((c) => c.request));
  await expect.poll(async () => (await holes()).at(-1)).toEqual([[294, 564, 92, 52]]);
  await page.evaluate(() => window.glazePlugins.teardown());
  await expect.poll(async () => (await holes()).at(-1)).toEqual([]);
});

test('the sync variable cache and the storage shim', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      methods: ['variables.get', 'variables.set', 'ui.toast'],
      storage: { kept: 'yes' },
      main: `
        localStorage.setItem('n', '1');
        glaze.ui.toast([glaze.variables.peek('greeting'), localStorage.getItem('kept'), localStorage.getItem('n'), localStorage.length].join('|'));
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['hi|yes|1|2']);
  const stored = await calls(page, 'storage.set');
  expect(stored[0].request.params).toEqual([{ key: 'n', value: '1' }]);
});

test('actions run the main handler and report a missing one', async ({ page }) => {
  await setup(page, [
    plugin('p', { main: `glaze.plugin.onComposerAction('go', async () => { await glaze.ui.toast('went'); });` }),
  ]);
  await expect.poll(() => page.evaluate(() => window.glazePlugins.runAction('p', 'action:composer:go'))).toEqual({ ok: true });
  expect(await page.evaluate(() => window.glazePlugins.runAction('p', 'action:composer:nope')))
    .toEqual({ ok: false, reason: 'missing-handler' });
});

test('file handlers return text, or the next one is tried', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      main: `glaze.plugin.registerFileHandler('txt', { extract: async (f) => ({ content: 'read ' + f.name }) });`,
    }),
  ]);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.runFileHandler('p', 'txt', { name: 'a.txt', path: 'files/tmp/a.txt' }, [])))
    .toEqual({ ok: true, content: 'read a.txt' });
  const own = await page.evaluate(() => window.glazePlugins.runFileHandler('p', 'csv', { name: 'b.csv' }, [
    { name: 'csv.js', source: `glaze.plugin.registerFileHandler('csv', { extract: async () => { const e = new Error('no'); e.code = 'unsupported_format'; throw e; } });` },
  ]));
  expect(own).toMatchObject({ ok: false, error: { code: 'unsupported_format' } });
});

test('Tavo plugins get tavo.* mapped onto glaze.*', async ({ page }) => {
  await setup(page, [
    plugin('t', {
      compat: 'tavo',
      main: `
        tavo.plugin.on('input:beforeSend', (e) => { e.text = '[t] ' + e.text; });
        tavo.plugin.onInputAction('go', () => tavo.utils.toast('went'));
        tavo.variable.get('k').then((v) => tavo.utils.toast(v + '|' + tavo.get('greeting')));
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['value-for-t|hi']);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.intercept('send:before', { text: 'x' }).then((r) => r.text))).toBe('[t] x');
  await expect.poll(() => page.evaluate(() => window.glazePlugins.runAction('t', 'action:composer:go'))).toEqual({ ok: true });
  await expect.poll(() => toasts(page)).toEqual(['value-for-t|hi', 'went']);
});

async function netReports(page) {
  return page.evaluate(() => window.__calls.filter((c) => c.name === 'pluginNetwork').map((c) => c.request));
}

test('without the network permission nothing is loaded from outside', async ({ page }) => {
  await setup(page, [
    plugin('off', {
      main: `
        fetch('https://example.com/x').then(() => glaze.ui.toast('loaded'), () => glaze.ui.toast('failed'));
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['failed']);
  await expect.poll(() => netReports(page)).toContainEqual({ pluginId: 'off', host: 'example.com', blocked: true });
  expect((await netReports(page)).some((r) => !r.blocked)).toBe(false);
});

test('with the network permission hosts are logged', async ({ page }) => {
  await setup(page, [
    plugin('on', {
      network: true,
      // The test server is on loopback.
      localNetwork: true,
      main: `fetch('http://127.0.0.1:4176/test/webview_js/harness/plugins.html').catch(() => {}).then(() => glaze.ui.toast('done'));`,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['done']);
  await expect.poll(() => netReports(page)).toContainEqual({ pluginId: 'on', host: '127.0.0.1', blocked: false });
});

test('a frame without internet access cannot navigate away, and is removed', async ({ page }) => {
  const leaks = [];
  page.on('request', (r) => { if (r.url().includes('leak=')) leaks.push(r.url()); });
  await setup(page, [
    plugin('nav', { main: `setTimeout(() => { location.href = 'http://127.0.0.1:4176/test/webview_js/harness/plugins.html?leak=chat'; }, 50);` }),
  ]);
  await expect.poll(() => page.locator('iframe[data-glaze-plugin="nav"]').count()).toBe(0);
  await expect.poll(() => netReports(page)).toContainEqual({ pluginId: 'nav', host: 'navigation', blocked: true });
  // Stopped by the wrapper's policy before anything was sent.
  expect(leaks).toEqual([]);
});

test('with a host list only those hosts are reachable', async ({ page }) => {
  await setup(page, [
    plugin('list', {
      network: ['127.0.0.1'],
      localNetwork: true,
      main: `
        const ok = await fetch('http://127.0.0.1:4176/test/webview_js/harness/plugins.html', { mode: 'no-cors' }).then(() => 'ok', () => 'fail');
        const other = await fetch('https://example.com/x', { mode: 'no-cors' }).then(() => 'ok', () => 'fail');
        glaze.ui.toast(ok + '|' + other);
      `.replace(/^/, '(async () => {').concat('})();'),
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['ok|fail']);
  await expect.poll(() => netReports(page)).toContainEqual({ pluginId: 'list', host: 'example.com', blocked: true });
  expect((await netReports(page)).filter((r) => r.host === '127.0.0.1').every((r) => !r.blocked)).toBe(true);
});

const LOCAL_PROBE = `
  (async () => {
    const page = 'http://127.0.0.1:4176/test/webview_js/harness/plugins.html';
    const plain = await fetch(page, { mode: 'no-cors' }).then(() => 'ok', () => 'fail');
    // Refused like a network failure, so the plugin cannot tell.
    const secure = await fetch('https://192.168.0.1/', { mode: 'no-cors' }).then(() => 'ok', (e) => e.message === 'Failed to fetch' ? 'refused' : 'other');
    glaze.ui.toast(plain + '|' + secure);
  })();
`;

test('the local network is out of reach unless allowed', async ({ page }) => {
  await setup(page, [
    plugin('any', { network: true, main: LOCAL_PROBE }),
    plugin('list', { network: ['127.0.0.1', '192.168.0.1'], main: LOCAL_PROBE }),
    plugin('local', { network: true, localNetwork: true, main: LOCAL_PROBE.replace("'https://192.168.0.1/'", 'page') }),
  ]);
  await expect.poll(async () => (await toasts(page)).sort()).toEqual(['fail|refused', 'fail|refused', 'ok|ok']);
  const reports = await netReports(page);
  expect(reports).toContainEqual({ pluginId: 'any', host: '127.0.0.1', blocked: true });
  expect(reports).toContainEqual({ pluginId: 'list', host: '192.168.0.1', blocked: true });
  expect(reports.filter((r) => r.pluginId === 'local').every((r) => !r.blocked)).toBe(true);
});

test('what plugin frames post never reaches the page past the plugin host', async ({ page }) => {
  await page.addInitScript(() => {
    window.__leaked = [];
    // Registered after the host, like the page's own relays.
    addEventListener('load', () => addEventListener('message', (e) => {
      if (e.data && e.data.probe) window.__leaked.push(e.data.probe);
    }));
  });
  await setup(page, [
    plugin('p', {
      main: `
        top.postMessage({ probe: 'direct', type: 'glaze:request' }, '*');
        const f = document.createElement('iframe');
        f.srcdoc = '<script>top.postMessage({ probe: "nested", type: "glaze:request" }, "*"); parent.postMessage({ probe: "up" }, "*")<\\/script>';
        document.body.appendChild(f);
        setTimeout(() => glaze.ui.toast('posted'), 300);
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['posted']);
  // A frame that is not a plugin's still gets through.
  await page.evaluate(() => {
    const f = document.createElement('iframe');
    f.srcdoc = '<script>parent.postMessage({ probe: "card" }, "*")<\/script>';
    document.body.appendChild(f);
  });
  await expect.poll(() => page.evaluate(() => window.__leaked)).toEqual(['card']);
});

const RTC_PROBE = `
  (async () => {
    let r;
    try { new RTCPeerConnection(); r = 'ok'; } catch (e) { r = e.name; }
    glaze.ui.toast(typeof RTCPeerConnection + ':' + r + ':' + typeof window.__rtcGate);
  })();
`;

test('without a guard, WebRTC is refused unless any host is allowed', async ({ page }) => {
  await setup(page, [
    plugin('off', { main: RTC_PROBE }),
    plugin('list', { network: ['example.com'], main: RTC_PROBE }),
  ]);
  await expect.poll(async () => (await toasts(page)).sort())
    .toEqual(['function:NotAllowedError:undefined', 'function:NotAllowedError:undefined']);
  await expect.poll(() => netReports(page)).toContainEqual({ pluginId: 'off', host: 'webrtc', blocked: true });
});

test('the WebView guard gives WebRTC back only for any host and the right key', async ({ page }) => {
  await page.addInitScript(guardSource('k1'));
  await setup(page, [
    plugin('any', { network: true, main: RTC_PROBE }),
    plugin('list', { network: ['example.com'], main: RTC_PROBE }),
    plugin('nested', {
      network: true,
      // A nested frame has no SDK and no key: no WebRTC there.
      main: `
        const f = document.createElement('iframe');
        f.srcdoc = '<script>parent.postMessage({ rtc: typeof RTCPeerConnection, hook: typeof __rtcGate, give: String(__rtcGate && __rtcGate("bad")) }, "*")<\\/script>';
        addEventListener('message', (e) => { if (e.data && e.data.rtc) glaze.ui.toast('nested:' + e.data.rtc + ':' + e.data.hook + ':' + e.data.give); });
        document.body.appendChild(f);
      `,
    }),
  ], { rtcToken: 'k1' });
  await expect.poll(async () => (await toasts(page)).sort()).toEqual([
    'function:NotAllowedError:undefined',
    'function:ok:undefined',
    'nested:undefined:function:null',
  ]);
  await expect.poll(() => netReports(page)).toContainEqual({ pluginId: 'any', host: 'webrtc', blocked: false });
});

test('a message panel reaches the app through its host, once', async ({ page }) => {
  await page.goto(URL);
  const calls = await page.evaluate(async () => {
    window.__glazeSdkSource = await (await fetch('/assets/chat_webview/glaze_sdk.js')).text();
    const { PanelHost } = await import('/assets/chat_webview/bridge/panel_host.js');
    const section = document.createElement('div');
    section.dataset.messageId = 'm1';
    document.body.appendChild(section);
    const calls = [];
    const host = new PanelHost({
      _sendToFlutter: () => {},
      _callGlazeBridge: async (request) => { calls.push(request); return 'ok'; },
    });
    host.open('m1', '<script>setTimeout(() => glaze.showToast("hi"), 50)<\/script>', '{}');
    await new Promise((r) => setTimeout(r, 500));
    return calls.map((c) => ({ method: c.method, panel: !!c.context.panelId, owned: host.owns(document.querySelector('iframe.interactive-panel-frame').contentWindow) }));
  });
  expect(calls).toEqual([{ method: 'showToast', panel: true, owned: true }]);
});

test('hooks and notifications need their permissions', async ({ page }) => {
  await setup(page, [
    plugin('none', {
      events: [],
      main: `
        glaze.plugin.on('send:before', (e) => { e.text = 'stolen'; });
        glaze.plugin.on('send:after', () => {});
        glaze.plugin.on('message:added', () => glaze.ui.toast('saw none'));
      `,
    }),
    plugin('chat', {
      events: ['chat', 'message'],
      main: `glaze.plugin.on('message:added', (e) => glaze.ui.toast('saw ' + e.message.id));`,
    }),
  ]);
  // The refused kinds are reported once each.
  await expect.poll(async () => (await calls(page, 'events.subscribe')).map((c) => c.request.params[0]).sort())
    .toEqual(['message', 'send']);
  expect(await page.evaluate(() => window.glazePlugins.hasSubscribers('send:before'))).toBe(false);
  const out = await page.evaluate(() => window.glazePlugins.intercept('send:before', { text: 'mine' }));
  expect(out.text).toBe('mine');
  await page.evaluate(() => window.glazePlugins.dispatchEvent('message:added', { message: { id: 'm1' } }));
  await expect.poll(() => toasts(page)).toEqual(['saw m1']);
});

test('variable updates reach only the plugin that owns them', async ({ page }) => {
  await setup(page, [
    plugin('a', { methods: ['variables.get', 'ui.toast'], main: `setTimeout(() => glaze.ui.toast('a:' + glaze.variables.peek('x')), 300);` }),
    plugin('b', { methods: ['variables.get', 'ui.toast'], main: `setTimeout(() => glaze.ui.toast('b:' + glaze.variables.peek('x')), 300);` }),
  ]);
  await page.evaluate(() => window.glazePlugins.pushVars('a', 'chat', { x: 1 }));
  await expect.poll(async () => (await toasts(page)).sort()).toEqual(['a:1', 'b:undefined']);
});

test('panel scripts before the head run under the policy, after the SDK', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      panels: [{
        id: 'early',
        placement: 'chat',
        html: `<!doctype html><script>
          glaze.ui.toast(typeof glaze);
          fetch('https://example.com/').then(() => glaze.ui.toast('leaked'), () => glaze.ui.toast('blocked'));
        </script><html><head><title>t</title></head><body></body></html>`,
      }],
    }),
  ]);
  await expect.poll(async () => (await toasts(page)).sort()).toEqual(['blocked', 'object']);
  const mode = await page.locator('iframe[data-glaze-plugin="p"]').evaluate((f) => f.contentDocument === null);
  expect(mode).toBe(true);
});

test('a converted plugin sees only tavo, and nothing of the host', async ({ page }) => {
  await setup(page, [
    plugin('t', {
      compat: 'tavo',
      network: true,
      main: `
        (async () => {
          const seen = [
            typeof window.glaze,
            typeof window.__pluginBoot,
            document.scripts.length,
            /native code/.test(String(fetch)),
            /native code/.test(Function.prototype.toString.call(XMLHttpRequest.prototype.open)),
            /native code/.test(String(WebSocket)),
            await tavo.app.version(),
            await tavo.app.versionNumber(),
          ];
          tavo.utils.toast(seen.join('|'));
        })();
      `,
    }),
  ]);
  // One script is the plugin's own, still running.
  await expect.poll(() => toasts(page)).toEqual(['undefined|undefined|1|true|true|true|0.93.0|930']);
});
