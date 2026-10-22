// The ExtBlocks page: scripts of the original ExtBlocks extension running in
// a plugin chat panel the app makes (ext_blocks_page.dart), so what they draw
// and keep stays, over a hidden mirror of the chat.
import { test, expect } from '@playwright/test';

const URL = '/test/webview_js/harness/plugins.html';
const ID = '_extblocks';

// The setup entry ext_blocks_page.dart builds, and the compat source it
// composes from the same three files.
async function setup(page, { network = false, storage = {} } = {}) {
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto(URL);
  await page.evaluate(async ({ id, network, storage }) => {
    const load = async (p) => (await fetch('/assets/chat_webview/' + p)).text();
    const sdk = await load('plugins/plugin_sdk.js');
    const xbCompat = await load('extblocks_compat.js');
    const glazeSdk = await load('glaze_sdk.js');
    const compat = (await load('plugins/compat/extblocks_page.js'))
      .replace('__XB_COMPAT__', () => JSON.stringify(xbCompat))
      .replace('/*__GLAZE_SDK__*/', () => glazeSdk);
    // The chat's bridge as the app answers it through `extblocks.bridge`.
    const base = window.flutter_inappwebview.callHandler;
    window.flutter_inappwebview.callHandler = async (name, request) => {
      if (request && request.method === 'extblocks.bridge') {
        window.__calls.push({ name, request });
        const call = request.params[0];
        if (call.method === 'generateText') return { ok: true, result: { ok: true, result: 'generated:' + call.params.prompt } };
        return { ok: true, result: { ok: true, result: null } };
      }
      return base(name, request);
    };
    window.glazePlugins.setup({
      sdk,
      compat: { extblocks: compat },
      plugins: [{
        pluginId: id,
        compat: 'extblocks',
        package: null,
        onePage: true,
        main: null,
        panels: [{ id: 'page', src: 'page.html', placement: 'chat', slot: 'end', html: '', order: 0 }],
        config: {},
        i18n: null,
        vars: { chat: {}, global: {} },
        storage,
        methods: ['extblocks.bridge'],
        events: [],
        network,
        localNetwork: false,
        messageActions: [],
        mediaOrigins: ['http://127.0.0.1:4177'],
      }],
    });
  }, { id: ID, network, storage });
  return errors;
}

const boot = setup;

function run(page, script, extra = {}) {
  return page.evaluate(({ id, script, extra }) => window.glazePlugins.runAction(id, 'action:extblocks:run', {
    script,
    context: { messages: [], sessionId: 's1', characterId: 'c1', extBlocks: { chat: [], name1: 'U', name2: 'Ann', messageId: 0 } },
    ...extra,
  }), { id: ID, script, extra });
}

function mirror(page, detail) {
  return page.evaluate(({ id, detail }) => window.glazePlugins.relayEmit(id, 'extblocks:mirror', detail), { id: ID, detail });
}

test('a script returns its value and what it draws stays on the page', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 700 });
  const errors = await boot(page);
  await expect.poll(() => run(page, `
    var b = document.createElement('div');
    b.id = 'fab';
    b.setAttribute('style', 'position:fixed!important;left:300px;top:500px;width:52px;height:52px;background:#fff');
    b.onclick = function () { window.__taps = (window.__taps || 0) + 1; localStorage.setItem('taps', String(window.__taps)); };
    // On <html>, next to <body>, as SillyTavern scripts often hang them.
    document.documentElement.appendChild(b);
    return 'drawn by ' + context.name2;
  `)).toEqual({ ok: true, value: 'drawn by Ann' });

  // The button outlives the run and takes taps; the rest goes to the chat.
  const holes = () => page.evaluate(() => window.__calls.filter((c) => c.name === 'pluginHoles').map((c) => c.request));
  await expect.poll(async () => (await holes()).at(-1)).toEqual([[294, 494, 64, 64]]);
  await page.mouse.click(320, 520);
  await expect.poll(() => page.evaluate(() => window.__calls.filter((c) => c.request.method === 'storage.set').length)).toBe(1);
  await page.mouse.click(100, 300);
  expect(await page.evaluate(() => window.__underClicks || 0)).toBe(1);

  // A second run sees the first one's globals: one page, as in the original.
  expect(await run(page, `return String(!!document.getElementById('fab')) + window.__taps;`))
    .toEqual({ ok: true, value: 'true1' });
  expect(errors).toEqual([]);
});

test('a script reads the chat from a hidden mirror in SillyTavern\'s markup', async ({ page }) => {
  await boot(page);
  await mirror(page, {
    reset: true,
    order: ['m1', 'm2'],
    upsert: [
      { id: 'm1', index: 0, isUser: true, name: 'U', html: 'hi' },
      { id: 'm2', index: 1, isUser: false, name: 'Ann', html:
        `<polaroid><img data-iig-instruction='{"prompt":"cat"}' src="http://127.0.0.1:4177/x.png" onerror="window.__ran=1">` +
        `<div data-pol-short="1">тихий вечер</div><script>window.__ran=2<\/script></polaroid>` },
    ],
  });
  const read = `
    var mes = document.querySelectorAll('#chat .mes[mesid]');
    var img = document.querySelector('#chat .mes[mesid="1"] .mes_text img[data-iig-instruction]');
    return [mes.length, mes[1].getAttribute('is_user'), mes[1].getAttribute('ch_name'),
      img.src, img.hasAttribute('onerror'), document.querySelector('[data-pol-short]').textContent,
      String(window.__ran), getComputedStyle(document.getElementById('chat')).display].join('|');
  `;
  await expect.poll(() => run(page, read)).toEqual({
    ok: true,
    value: '2|false|Ann|http://127.0.0.1:4177/x.png|false|тихий вечер|undefined|none',
  });

  // Updates move and drop messages without rebuilding the rest.
  await mirror(page, { order: ['m2'], upsert: [] });
  expect(await run(page, `return document.querySelectorAll('#chat .mes').length + ':' + document.querySelector('#chat .mes').getAttribute('mesid');`))
    .toEqual({ ok: true, value: '1:0' });
});

test('glaze calls reach the chat bridge; not while the page restores', async ({ page }) => {
  await boot(page);
  const script = `return await context.generateRaw('hello');`;
  await expect.poll(() => run(page, script)).toEqual({ ok: true, value: 'generated:hello' });
  const forwarded = await page.evaluate(() => window.__calls.filter((c) => c.request.method === 'extblocks.bridge').map((c) => c.request));
  expect(forwarded).toHaveLength(1);
  expect(forwarded[0].pluginId).toBe(ID);
  expect(forwarded[0].params[0]).toMatchObject({ method: 'generateText', params: { prompt: 'hello' } });

  const restored = await run(page, script, { restore: true });
  expect(restored.ok).toBe(false);
  expect(restored.message).toContain('restores');
  // Back to normal once the restoring run is over.
  expect(await run(page, script)).toEqual({ ok: true, value: 'generated:hello' });
});

test('the page has the stored localStorage and no internet without external media', async ({ page }) => {
  await boot(page, { storage: { _pol_Ann: '[{"src":"a"}]' } });
  await expect.poll(() => run(page, `return localStorage.getItem('_pol_Ann');`))
    .toEqual({ ok: true, value: '[{"src":"a"}]' });
  const blocked = await run(page, `
    try { await fetch('https://example.com/'); return 'reached'; } catch (e) { return 'blocked'; }
  `);
  expect(blocked).toEqual({ ok: true, value: 'blocked' });
});

test('a script error comes back as the action\'s failure', async ({ page }) => {
  await boot(page);
  await expect.poll(() => run(page, `throw new Error('boom');`)).toMatchObject({ ok: false, reason: 'handler-error', message: 'boom' });
});
