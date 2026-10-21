// The theme editor's live preview — assets/chat_webview/theme_preview.html.
// It has to be the chat page's own rendering: the same message markup, the
// theme's variables and template, and the chrome, all from what Flutter sends.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/theme_preview.html';

const NOW = new Date(2026, 2, 24, 10, 8).getTime();

const MESSAGES = [
  { id: 'p1', role: 'assistant', text: '*Rei looks up.* "You made it."', timestamp: NOW,
    displayName: 'Rei', avatarColor: '#C42A4A', messageIndex: 0 },
  { id: 'p2', role: 'user', text: '"Sorry, the train was late."', timestamp: NOW + 60000,
    displayName: 'You', messageIndex: 1 },
  { id: 'p3', role: 'assistant', text: 'She slides a cup over. "**Careful**."', timestamp: NOW + 120000,
    displayName: 'Rei', messageIndex: 2, swipeIndex: 0, swipeTotal: 3, genTime: '4.2s', tokens: 128,
    isLast: true },
];

async function open(page) {
  const failures = [];
  page.on('pageerror', (error) => failures.push(String(error)));
  await page.addInitScript(() => {
    window.flutter_inappwebview = { callHandler: () => Promise.resolve(null) };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.__glazePreview);
  page.__failures = failures;
}

const apply = (page, msg) => page.evaluate((m) => window.__glazePreview.apply(JSON.stringify(m)), msg);

test('the sample messages are drawn by the chat renderer, in the layout the theme picks', async ({ page }) => {
  await open(page);
  expect(await apply(page, {
    theme: { 'chat-layout': 'bubble', 'user-bubble-bg': 'rgb(10, 20, 30)' },
    messages: MESSAGES,
  })).toBe(true);
  const sections = page.locator('#chat-container .message-section');
  await expect(sections).toHaveCount(3);
  await expect(sections.nth(0)).toHaveClass(/layout-bubble/);
  await expect(sections.nth(1)).toHaveClass(/\buser\b/);
  await expect(page.locator('#chat-container .date-separator')).toHaveCount(1);
  const userBg = await page.evaluate(() =>
    getComputedStyle(document.querySelector('.message-section.user .msg-body')).backgroundColor);
  expect(userBg).toBe('rgb(10, 20, 30)');

  await apply(page, { theme: { 'chat-layout': 'default' } });
  await expect(sections.nth(0)).toHaveClass(/layout-default/);
  expect(page.__failures).toEqual([]);
});

test('a theme template lays the messages out and reads the theme settings', async ({ page }) => {
  await open(page);
  await apply(page, {
    messages: MESSAGES,
    layout: {
      message: '<div class="card"><span class="who">{{name}}</span><span class="v" g-if="theme.badges">{{theme.tone}}</span><g-part name="content"></g-part></div>',
      css: '.card { border-left: var(--theme-edge) solid red; }',
      vars: { edge: '3px', tone: 'warm', 'bad;key': '1px', ok: 'url(x)' },
      flags: ['badges', 'tone-warm', 'no good'],
      values: { badges: true, tone: 'warm' },
    },
  });
  await expect(page.locator('.card')).toHaveCount(3);
  await expect(page.locator('.card .who').first()).toHaveText('Rei');
  await expect(page.locator('.card .v').first()).toHaveText('warm');
  const state = await page.evaluate(() => ({
    edge: getComputedStyle(document.querySelector('.card')).borderLeftWidth,
    ok: document.documentElement.style.getPropertyValue('--theme-ok'),
    bad: document.documentElement.style.getPropertyValue('--theme-bad;key'),
    classes: document.getElementById('chat-container').className,
  }));
  expect(state.edge).toBe('3px');
  // Values that could load or break out of a declaration are dropped.
  expect(state.ok).toBe('');
  expect(state.bad).toBe('');
  expect(state.classes).toContain('theme-badges');
  expect(state.classes).toContain('theme-tone-warm');
  expect(state.classes).not.toContain('no good');

  // Taking the settings away takes their variables and classes with them.
  await apply(page, { layout: null });
  const after = await page.evaluate(() => ({
    edge: document.documentElement.style.getPropertyValue('--theme-edge'),
    classes: document.getElementById('chat-container').className,
  }));
  expect(after.edge).toBe('');
  expect(after.classes).not.toContain('theme-badges');
  await expect(page.locator('.card')).toHaveCount(0);
  expect(page.__failures).toEqual([]);
});

test('a Tavo theme CSS finds the page aliases and the shadow-root content', async ({ page }) => {
  await open(page);
  await apply(page, {
    messages: MESSAGES,
    layout: {
      css: '.tavo-message-content { border: 2px solid rgb(1, 2, 3); }',
      contentCss: ':host(.char) .glaze-message p { color: rgb(4, 5, 6); }',
    },
  });
  const first = page.locator('#chat-container .message-section').nth(0);
  await expect(first).toHaveClass(/tavo-character-bubble/);
  await expect(first.locator('.msg-avatar')).toHaveClass(/tavo-character-avatar/);
  await expect(first.locator('.msg-name')).toHaveClass(/tavo-speaker-name/);
  await expect(first.locator('.message-content')).toHaveClass(/tavo-message-content/);
  const colors = await page.evaluate(() => {
    const host = document.querySelector('.message-section.char .message-content');
    const p = host.shadowRoot.querySelector('p');
    return [getComputedStyle(host).borderLeftColor, getComputedStyle(p).color];
  });
  expect(colors).toEqual(['rgb(1, 2, 3)', 'rgb(4, 5, 6)']);
  expect(page.__failures).toEqual([]);
});

test('the chrome is driven from the preview, with the header and composer on screen', async ({ page }) => {
  await open(page);
  await apply(page, {
    messages: MESSAGES,
    chrome: {
      theme: { accent: [196, 42, 74, 1] },
      layout: { safeTop: 0, safeBottom: 0, inset: 0, gutter: 0, fades: true,
        drawer: { show: false, height: 0, progress: 0 } },
      header: { show: true, title: 'Rei', session: 'Session #4', avatar: { initial: 'R' },
        search: { kind: 'mobile', open: false, hint: 'Search' } },
      composer: { show: true, mode: 'compose', placeholder: 'Message', readOnly: true, pins: [],
        send: { icon: { cp: 62754 }, tap: true, slot: false } },
    },
  });
  // The chrome sits in a closed shadow root; its host is the only element
  // the page cannot otherwise account for.
  const hosts = await page.evaluate(() =>
    Array.from(document.body.children).filter((el) => el.tagName.startsWith('GLAZE-')).length);
  expect(hosts).toBe(1);
  await apply(page, { insets: { top: 80, bottom: 90 } });
  const padding = await page.evaluate(() => {
    const s = getComputedStyle(document.getElementById('chat-container'));
    return [s.paddingTop, s.paddingBottom];
  });
  expect(padding).toEqual(['80px', '90px']);
  expect(page.__failures).toEqual([]);
});
