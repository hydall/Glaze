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

test('panels are told to avoid the status bar, not the app header', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      methods: ['ui.toast'],
      panels: [{
        id: 'x',
        placement: 'chat',
        html: `<script>setTimeout(() => { const i = glaze.ui.insets(); glaze.ui.toast(i.topBar + '|' + i.topSafe + '|' + i.bottomInput); }, 100);<\/script>`,
      }],
    }),
  ]);
  // The harness page pads the chat 60 px under a header, 80 px over the composer.
  await expect.poll(() => toasts(page)).toEqual(['0|0|80']);
});

test('the storage shim refuses a write past its quota, like a browser', async ({ page }) => {
  await setup(page, [
    plugin('p', {
      methods: ['ui.toast'],
      // 'kept' + 'yes' = 7 bytes; 'я' is two.
      storage: { kept: 'yes' },
      storageQuota: 20,
      main: `
        const out = [];
        localStorage.setItem('a', 'яя');
        try { localStorage.setItem('b', 'x'.repeat(20)); } catch (e) { out.push(e.name); }
        out.push(localStorage.getItem('b'));
        localStorage.removeItem('a');
        localStorage.setItem('b', 'x'.repeat(11));
        out.push(localStorage.getItem('b').length);
        glaze.ui.toast(out.join('|'));
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['QuotaExceededError||11']);
  const stored = (await calls(page, 'storage.set')).map((c) => c.request.params[0].key);
  expect(stored).toEqual(['a', 'b']);
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

test('Tavo plugins read messages through tavo.message', async ({ page }) => {
  await setup(page, [
    plugin('t', {
      compat: 'tavo',
      methods: ['messages.list', 'messages.get', 'ui.toast'],
      main: `
        tavo.plugin.on('message:added', (e) => tavo.utils.toast('event:' + e.message.id + ':' + e.message.role));
        (async () => {
          const all = await tavo.message.find();
          const one = await tavo.message.get('m9');
          tavo.utils.toast(all.map((m) => m.id + ':' + m.role + ':' + m.content).join(',') + '|' + one.content);
        })().catch((e) => tavo.utils.toast('failed: ' + e.message));
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['m1:user:hi,m2:assistant:hello|one']);
  await page.evaluate(() => window.glazePlugins.dispatchEvent('message:added', { message: { id: 'm3', role: 'user' } }));
  await expect.poll(async () => (await toasts(page)).at(-1)).toBe('event:m3:user');
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

test('glaze.net.fetch goes through the app and answers with a Response', async ({ page }) => {
  await setup(page, [
    plugin('n', {
      methods: ['net.fetch', 'net.abort', 'ui.toast'],
      main: `
        (async () => {
          const res = await glaze.net.fetch('https://api.example/echo', {
            method: 'POST', headers: { 'X-Key': 'k' }, body: JSON.stringify({ a: 1 }),
          });
          const echo = await res.json();
          const key = echo.headers.find((h) => h[0] === 'x-key');
          glaze.ui.toast([res.status, res.ok, res.statusText, res.url, res.redirected, res.headers.get('x-echo'),
            echo.method, key && key[1], echo.body, typeof glaze.net.abort].join('|'));
          const ctl = new AbortController();
          const slow = glaze.net.fetch('https://api.example/slow', { signal: ctl.signal });
          setTimeout(() => ctl.abort(), 50);
          await slow.catch((e) => glaze.ui.toast('aborted:' + e.name));
        })().catch((e) => glaze.ui.toast('failed: ' + e.message));
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual([
    '201|true|Created|https://api.example/echo?final|true|yes|POST|k|{"a":1}|undefined',
    'aborted:AbortError',
  ]);
  const slow = (await calls(page, 'net.fetch')).at(-1).request.params[1].id;
  expect((await calls(page, 'net.abort')).map((c) => c.request.params[0])).toEqual([slow]);
});

async function netReports(page) {
  return page.evaluate(() => window.__calls.filter((c) => c.name === 'pluginNetwork').map((c) => c.request));
}

async function httpReports(page) {
  return page.evaluate(() => window.__calls.filter((c) => c.name === 'pluginHttp').map((c) => c.request));
}

test('what a frame sends and gets back reaches the request log', async ({ page }) => {
  await page.route('http://127.0.0.1:4176/api/**', (route) => route.fulfill({
    status: route.request().url().endsWith('/missing') ? 404 : 200,
    contentType: 'application/json',
    body: JSON.stringify({ echo: route.request().postData() }),
  }));
  await setup(page, [
    plugin('on', {
      network: true,
      localNetwork: true,
      main: `
        (async () => {
          const res = await fetch('http://127.0.0.1:4176/api/chat', {
            method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer k' },
            body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }] }),
          });
          const own = await res.json();
          const xhr = new XMLHttpRequest();
          xhr.open('GET', 'http://127.0.0.1:4176/api/missing');
          await new Promise((r) => { xhr.onloadend = r; xhr.send(); });
          glaze.ui.toast(own.echo + '|' + xhr.status);
        })().catch((e) => glaze.ui.toast('failed: ' + e.message));
      `,
    }),
  ]);
  await expect.poll(() => toasts(page)).toEqual(['{"messages":[{"role":"user","content":"hi"}]}|404']);
  await expect.poll(async () => (await httpReports(page)).length).toBe(4);
  const reports = await httpReports(page);
  const starts = reports.filter((r) => r.phase === 'start');
  const ends = reports.filter((r) => r.phase === 'end');
  expect(reports.every((r) => r.pluginId === 'on')).toBe(true);
  const post = starts.find((r) => r.via === 'fetch');
  expect(post).toMatchObject({ method: 'POST', url: 'http://127.0.0.1:4176/api/chat' });
  expect(post.headers).toContainEqual(['authorization', 'Bearer k']);
  expect(JSON.parse(post.body).messages[0].content).toBe('hi');
  expect(ends.find((r) => r.id === post.id)).toMatchObject({ status: 200, error: null });
  expect(JSON.parse(ends.find((r) => r.id === post.id).body).echo).toContain('hi');
  const get = starts.find((r) => r.via === 'xhr');
  expect(get).toMatchObject({ method: 'GET', url: 'http://127.0.0.1:4176/api/missing' });
  expect(ends.find((r) => r.id === get.id)).toMatchObject({ status: 404 });
});

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

// A draggable panel button the way plugins write one: inline left/top, moved
// by its own pointer handlers. [top] is where it starts (or was restored to).
function fabPanel(top, extra = '') {
  return plugin('p', {
    panels: [{
      id: 'fab',
      placement: 'chat',
      html: `
        <div id="fab" style="position:fixed;left:100px;top:${top}px;width:56px;height:56px;background:#7b5cd6;${extra}"></div>
        <script>
          const b = document.getElementById('fab');
          let start = null;
          b.addEventListener('pointerdown', (e) => {
            start = { x: e.clientX, y: e.clientY, left: b.offsetLeft, top: b.offsetTop };
            b.setPointerCapture(e.pointerId);
          });
          b.addEventListener('pointermove', (e) => {
            if (!start) return;
            b.style.left = start.left + e.clientX - start.x + 'px';
            b.style.top = start.top + e.clientY - start.y + 'px';
          });
          b.addEventListener('pointerup', () => { start = null; });
        <\/script>`,
    }],
  });
}

const fabRect = (page) => page.frameLocator('iframe[data-glaze-plugin="p"]')
  .frameLocator('iframe').locator('#fab')
  .evaluate((el) => { const r = el.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left }; });

test('a panel button dragged onto the message box comes back above it', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await setup(page, [fabPanel(200)]);
  const frame = page.locator('iframe[data-glaze-plugin="p"]');
  await expect.poll(() => frame.evaluate((el) => el.style.clipPath)).toContain('path(');

  await page.mouse.move(128, 228);
  await page.mouse.down();
  await page.mouse.move(128, 690, { steps: 6 });
  await page.mouse.up();

  // Bottom inset 80, 8 px margin: the button may end no lower than 612.
  await expect.poll(async () => (await fabRect(page)).bottom).toBe(612);
  expect((await fabRect(page)).left).toBe(100);
});

test('a panel button restored into the message box is moved out on open', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await setup(page, [fabPanel(660)]);
  await expect.poll(async () => (await fabRect(page)).bottom).toBe(612);
});

test('a panel button anchored by bottom keeps that anchor', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await setup(page, [fabPanel(0, 'top:auto;bottom:4px;')]);
  const style = () => page.frameLocator('iframe[data-glaze-plugin="p"]').frameLocator('iframe')
    .locator('#fab').evaluate((el) => [el.style.top, el.style.bottom]);
  await expect.poll(style).toEqual(['auto', '88px']);
});

test('a full-screen panel is left where the plugin put it', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await setup(page, [plugin('p', {
    panels: [{ id: 'big', placement: 'chat', html: '<div id="big" style="position:fixed;inset:0;background:#000"></div>' }],
  })]);
  const frame = page.locator('iframe[data-glaze-plugin="p"]');
  await expect.poll(() => frame.evaluate((el) => el.style.clipPath)).toContain('path(');
  await page.waitForTimeout(500);
  const style = await page.frameLocator('iframe[data-glaze-plugin="p"]').frameLocator('iframe')
    .locator('#big').evaluate((el) => el.style.cssText);
  expect(style).toBe('position: fixed; inset: 0px; background: rgb(0, 0, 0);');
});

// Stands in for the WebView's visual viewport, which the soft keyboard
// shrinks while the page keeps its full size. Plugin frames keep their own.
async function fakeKeyboard(page) {
  await page.addInitScript(() => {
    if (window !== window.top) return;
    const vv = new EventTarget();
    let kb = 0;
    Object.defineProperties(vv, {
      height: { get: () => window.innerHeight - kb },
      offsetTop: { get: () => 0 },
      scale: { get: () => 1 },
    });
    Object.defineProperty(window, 'visualViewport', { configurable: true, get: () => vv });
    window.__keyboard = (px) => { kb = px; vv.dispatchEvent(new Event('resize')); };
  });
}

// A messenger the way Tavo panels write one: a composer pinned to the bottom
// of the frame's own viewport.
function composerPanel(id) {
  return plugin(id, {
    methods: ['ui.toast'],
    panels: [{
      id: 'chat',
      placement: 'chat',
      html: `
        <input id="field" style="position:fixed;left:0;bottom:0;width:200px;height:40px">
        <script>
          window.addEventListener('resize', () => {
            glaze.ui.toast(innerHeight + '|' + glaze.ui.insets().keyboard + '|' + glaze.ui.insets().bottomInput);
          });
        <\/script>`,
    }],
  });
}

const panelFrame = (page, id) => page.locator(`iframe[data-glaze-plugin="${id}"]`);

test('the focused panel is fitted above the keyboard and back', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await fakeKeyboard(page);
  await setup(page, [composerPanel('p')]);
  await expect.poll(() => panelFrame(page, 'p').evaluate((el) => el.style.clipPath)).toContain('path(');
  await page.frameLocator('iframe[data-glaze-plugin="p"]').frameLocator('iframe').locator('#field').focus();

  await page.evaluate(() => window.__keyboard(300));
  await expect.poll(() => panelFrame(page, 'p').evaluate((el) => el.style.height)).toBe('400px');
  // The composer's 80 px are inside the 300 px the keyboard took.
  await expect.poll(() => toasts(page)).toEqual(['400|300|0']);

  await page.evaluate(() => window.__keyboard(0));
  await expect.poll(() => panelFrame(page, 'p').evaluate((el) => el.style.height)).toBe('100%');
  await expect.poll(() => toasts(page)).toEqual(['400|300|0', '700|0|80']);
});

test('the keyboard of something else leaves a panel full size', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  await fakeKeyboard(page);
  await setup(page, [composerPanel('p')]);
  await expect.poll(() => panelFrame(page, 'p').evaluate((el) => el.style.clipPath)).toContain('path(');
  await page.evaluate(() => window.__keyboard(300));
  await page.waitForTimeout(300);
  expect(await panelFrame(page, 'p').evaluate((el) => el.style.height)).toBe('100%');
  expect(await toasts(page)).toEqual([]);
});

/* ---------- The plugin layer ---------- */
// Where the app lays the plugin layer over its controls, the chat page keeps
// main and message frames and the layer holds the chat panels; Dart carries
// emits and insets between the two.

const LAYER_URL = '/assets/chat_webview/plugin_layer.html';

// The layer page with the same stub of the Flutter side as the harness.
async function setupLayer(page, plugins) {
  await page.addInitScript(() => {
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler: async (name, request) => {
        window.__calls.push({ name, request });
        return { ok: true, result: null };
      },
    };
  });
  await page.goto(LAYER_URL);
  return page.evaluate(async (list) => {
    const sdk = await (await fetch('/assets/chat_webview/plugins/plugin_sdk.js')).text();
    return window.glazePlugins.setup({ sdk, compat: {}, plugins: list, layer: 'panels' });
  }, plugins);
}

const handlerCalls = (page, name) =>
  page.evaluate((n) => window.__calls.filter((c) => c.name === n).map((c) => c.request), name);

function layeredPlugin(id) {
  return plugin(id, {
    main: `glaze.plugin.on('chat:opened', (e) => glaze.plugin.emit('ping', { chat: e.chatId }));`,
    panels: [{
      id: 'f',
      placement: 'chat',
      order: 10,
      html: `
        <style>#fab { position: fixed; right: 20px; bottom: calc(var(--glaze-inset-bottom-input, 0px) + 10px); width: 80px; height: 40px; box-shadow: 0 0 30px red; }</style>
        <button id="fab" onclick="glaze.ui.toast('fab')">fab</button>
        <script>
          glaze.plugin.on('ping', (d) => glaze.ui.toast('got ' + d.chat));
          glaze.plugin.on('chat:opened', () => glaze.plugin.emit('pong', {}));
        <\/script>`,
    }],
  });
}

test('with a plugin layer the chat page leaves chat panels to it', async ({ page }) => {
  await setup(page, [layeredPlugin('p')], { layer: 'chat' });
  await expect.poll(() => page.locator('iframe[data-glaze-plugin-kind="main"]').count()).toBe(1);
  expect(await page.locator('iframe[data-glaze-plugin-kind="panel"]').count()).toBe(0);
  // The layer is told the insets it cannot measure.
  await expect.poll(async () => (await handlerCalls(page, 'pluginInsets')).at(-1))
    .toMatchObject({ bottomInput: 80 });
  // What main emits goes to the layer too, stamped with the plugin.
  await page.evaluate(() => window.glazePlugins.dispatchEvent('chat:opened', { chatId: 'c1' }));
  await expect.poll(() => handlerCalls(page, 'pluginEmit'))
    .toEqual([{ pluginId: 'p', event: 'ping', detail: { chat: 'c1' } }]);
});

test('the plugin layer holds chat panels only, drawn whole', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  expect(await setupLayer(page, [layeredPlugin('p')])).toBe(1);
  const frames = page.locator('iframe[data-glaze-plugin]');
  await expect.poll(() => frames.count()).toBe(1);
  expect(await frames.getAttribute('data-glaze-plugin-kind')).toBe('panel');
  await page.evaluate(() => window.glazePlugins.setInsets({ topSafe: 0, topBar: 0, bottomInput: 80, bottomSafe: 0 }));
  // Takes taps where it draws, and is not clipped: its shadow stays whole.
  await expect.poll(async () => (await handlerCalls(page, 'pluginHoles')).at(-1)).toEqual([[294, 564, 92, 52]]);
  expect(await frames.evaluate((el) => [el.style.clipPath, el.style.pointerEvents])).toEqual(['none', 'auto']);
  await page.mouse.click(340, 590);
  await expect.poll(async () => (await handlerCalls(page, 'pluginBridge')).map((r) => r.params[0])).toEqual(['fab']);
  // An emit from the chat page reaches the panel; the panel's goes back.
  await page.evaluate(() => window.glazePlugins.relayEmit('p', 'ping', { chat: 'c1' }));
  await expect.poll(async () => (await handlerCalls(page, 'pluginBridge')).map((r) => r.params[0])).toEqual(['fab', 'got c1']);
  await page.evaluate(() => window.glazePlugins.dispatchEvent('chat:opened', { chatId: 'c1' }));
  await expect.poll(() => handlerCalls(page, 'pluginEmit')).toEqual([{ pluginId: 'p', event: 'pong', detail: {} }]);
});

test('two panels in the plugin layer are clipped to take their own taps', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  const fab = (id, side) => plugin(id, {
    panels: [{
      id: 'f',
      placement: 'chat',
      order: 10,
      html: `<button style="position:fixed;${side}:20px;top:100px;width:80px;height:40px" onclick="glaze.ui.toast('${id}')">x</button>`,
    }],
  });
  await setupLayer(page, [fab('a', 'left'), fab('b', 'right')]);
  const frame = (id) => page.locator(`iframe[data-glaze-plugin="${id}"]`);
  await expect.poll(() => frame('a').evaluate((el) => el.style.clipPath)).toContain('path(');
  await expect.poll(() => frame('b').evaluate((el) => el.style.clipPath)).toContain('path(');
  await page.mouse.click(60, 120);
  await page.mouse.click(340, 120);
  await expect.poll(async () => (await handlerCalls(page, 'pluginBridge')).map((r) => r.pluginId)).toEqual(['a', 'b']);
});

// A plugin whose package the app serves (harness/server.js stands in for the
// package server).
function packaged(extra) {
  return plugin('pk', {
    package: 'http://127.0.0.1:4177/plugins/pk/',
    panels: [{ id: 'main', placement: 'chat', src: 'ui/panel.html', html: '<div id="x">x</div><script src="/plugins/pk/ui/probe.js"></script>' }],
    ...extra,
  });
}

for (const compat of [null, 'tavo']) {
  test(`a served panel loads its own files, and only those (${compat || 'glaze'})`, async ({ page }) => {
    const errors = await setup(page, [packaged({ compat })]);
    await expect.poll(() => toasts(page)).toEqual(['rgb(1, 2, 3)|1|{"ok":1}|blocked']);
    const frame = page.locator('iframe[data-glaze-plugin="pk"]');
    const src = await frame.evaluate((f) => f.contentDocument === null);
    expect(src).toBe(true);
    // Its own files are not the network.
    expect((await page.evaluate(() => window.__calls.filter((c) => c.name === 'pluginNetwork')))
      .map((c) => c.request.host)).toEqual(['127.0.0.1']);
    expect(errors).toEqual([]);
  });
}

test('a frame document is served once, from the package path', async ({ page }) => {
  await setup(page, [packaged()]);
  await expect.poll(() => toasts(page)).toHaveLength(1);
  const urls = await page.evaluate(() => window.__frameUrls);
  expect(urls).toHaveLength(1);
  expect(urls[0]).toMatch(/^http:\/\/127\.0\.0\.1:4177\/plugins\/pk\/ui\/panel\.html\?glaze-frame=/);
  expect((await page.request.get(urls[0])).status()).toBe(404);
});

test('a raw package page runs nothing', async ({ page }) => {
  await setup(page, [packaged({
    panels: [{
      id: 'main', placement: 'chat', src: 'ui/panel.html',
      html: `<script>
        addEventListener('message', (e) => { if (typeof e.data === 'string') glaze.ui.toast(e.data); });
        const f = document.createElement('iframe');
        f.src = '/plugins/pk/page.html';
        f.onload = () => setTimeout(() => glaze.ui.toast('loaded'), 300);
        document.body.append(f);
      </script>`,
    }],
  })]);
  await expect.poll(() => toasts(page)).toEqual(['loaded']);
});

// A Tavo plugin: its main script and chat panels run in one page, as in
// Tavo's chat page, and share globals.
function onePagePlugin(extra) {
  return plugin('t', {
    compat: 'tavo',
    onePage: true,
    methods: ['ui.toast'],
    main: `
      globalThis.__bus = { from: 'main' };
      tavo.plugin.on('input:beforeSend', (e) => { e.text = e.text + ' [' + globalThis.__bus.from + ']'; });
      tavo.plugin.onInputAction('go', () => tavo.utils.toast('went:' + globalThis.__bus.from));
    `,
    panels: [
      { id: 'a', placement: 'chat', src: 'ui/a.html', html: `<script>globalThis.__bus.from += '+a';</script>` },
      { id: 'b', placement: 'chat', src: 'ui/b.html', html: `<script>globalThis.__bus.from += '+b'; tavo.utils.toast(globalThis.__bus.from);</script>` },
    ],
    ...extra,
  });
}

test('a Tavo main script and its chat panels share one page', async ({ page }) => {
  await setup(page, [onePagePlugin()]);
  await expect.poll(() => toasts(page)).toEqual(['main+a+b']);
  expect(await page.locator('iframe[data-glaze-plugin="t"]').count()).toBe(1);
  await expect.poll(() => page.evaluate(() =>
    window.glazePlugins.intercept('send:before', { text: 'x' }).then((r) => r.text))).toBe('x [main+a+b]');
  expect(await page.evaluate(() => window.glazePlugins.runAction('t', 'action:composer:go'))).toEqual({ ok: true });
  await expect.poll(() => toasts(page)).toEqual(['main+a+b', 'went:main+a+b']);
});

test('the shared page is where the chat panels are', async ({ page }) => {
  // The chat page under a plugin layer runs neither.
  await setup(page, [onePagePlugin(), plugin('g', { main: `glaze.plugin.on('send:before', (e) => { e.text += ' [g]'; });` })], { layer: 'chat' });
  await expect.poll(() => page.evaluate(() => window.glazePlugins.hasSubscribers('send:before'))).toBe(true);
  expect(await page.locator('iframe[data-glaze-plugin="t"]').count()).toBe(0);
  // Each page runs the plugins the app names for it.
  expect(await page.evaluate(() =>
    window.glazePlugins.intercept('send:before', { text: 'x' }, ['g']).then((r) => r.text))).toBe('x [g]');
  expect(await page.evaluate(() =>
    window.glazePlugins.intercept('send:before', { text: 'x' }, ['t']).then((r) => r.text))).toBe('x');
});
