// A wheel notch or a touchpad pan over the composer scrolls the composer's own
// field, not the chat under it. The field draws in the chrome's closed shadow
// root (chrome/index.js), where the relay's document hit test cannot look, so
// the relay offers every step to the chrome first — see
// assets/chat_webview/bridge/scroll_relay.js. These drive the real bridge and
// the real chrome in the real page.
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
  // Far more than the field's five lines: it scrolls.
  text: { v: Array.from({ length: 40 }, (_, i) => 'line ' + i).join('\n'), rev: 1 },
};

async function open(page) {
  await page.addInitScript(() => {
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler: (...args) => { window.__calls.push(args); return Promise.resolve(null); },
    };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge && !!window.__glazeChrome);
  await page.evaluate((state) => {
    const keys = window.__glazeChrome.handshake();
    window.__glazeChrome.apply(keys.split(':')[0], JSON.stringify(state));
    const msgs = [];
    for (let i = 0; i < 40; i++) {
      msgs.push({
        id: 'm' + i,
        role: i % 2 ? 'user' : 'assistant',
        text: 'message number ' + i + ' ' + 'lorem ipsum '.repeat(40),
        timestamp: 1767225600000,
        isUser: i % 2 === 1,
        isAssistant: i % 2 === 0,
        isSystem: false,
        isError: false,
        isHidden: false,
        isGenerating: false,
        isPostGenRunning: false,
      });
    }
    window.bridge.setMessages(JSON.stringify(msgs));
    window.bridge.setBottomPadding(130, 0);
  }, STATE);
  await page.waitForTimeout(500);
  await page.evaluate(() => document.fonts.ready);
  // Rest the chat somewhere in the middle, so a step either way would show.
  await page.evaluate(() => {
    const c = document.getElementById('chat-container');
    c.scrollTop = Math.floor(c.scrollHeight / 2);
  });
  await page.waitForTimeout(300);
}

/* The composer field's box — [x, y, w, h] — from the layout the chrome reports
 * to Flutter. */
async function composerRect(page) {
  const rect = await page.evaluate(() => {
    const reports = window.__calls
      .filter((c) => c[0] === 'onChromeIntent')
      .map((c) => { try { return JSON.parse(c[2]); } catch (_) { return null; } })
      .filter((m) => m && m.t === 'layout' && m.d && m.d.composer);
    return reports.length ? reports[reports.length - 1].d.composer : null;
  });
  expect(rect, 'the chrome reported the composer box').toBeTruthy();
  return rect;
}

const chatTop = (page) =>
  page.evaluate(() => document.getElementById('chat-container').scrollTop);

test('a wheel notch over the composer scrolls the field, not the chat', async ({ page }) => {
  await open(page);
  const r = await composerRect(page);
  const x = r[0] + r[2] / 2;
  const y = r[1] + r[3] / 2;

  // Before: the field is at its top, so it can scroll down but not up.
  expect(await page.evaluate(([x, y]) => window.__glazeChrome.canScrollAt(x, y, 0, 1), [x, y])).toBe(true);
  expect(await page.evaluate(([x, y]) => window.__glazeChrome.canScrollAt(x, y, 0, -1), [x, y])).toBe(false);

  const chatBefore = await chatTop(page);
  await page.evaluate(([x, y]) => window.bridge.wheelScroll(0, 100, x, y), [x, y]);
  await page.waitForTimeout(500);

  // The field moved — it can scroll back up now — and the chat did not.
  expect(await page.evaluate(([x, y]) => window.__glazeChrome.canScrollAt(x, y, 0, -1), [x, y])).toBe(true);
  expect(await chatTop(page)).toBe(chatBefore);
});

test('a pan over the composer scrolls the field too', async ({ page }) => {
  await open(page);
  const r = await composerRect(page);
  const x = r[0] + r[2] / 2;
  const y = r[1] + r[3] / 2;
  const chatBefore = await chatTop(page);

  await page.evaluate(([x, y]) => {
    window.bridge.trackpadScrollStart();
    window.bridge.trackpadScroll(0, 30, x, y);
    window.bridge.trackpadScroll(0, 30, x, y);
    window.bridge.trackpadScrollEnd(0, 0);
  }, [x, y]);
  await page.waitForTimeout(400);

  expect(await page.evaluate(([x, y]) => window.__glazeChrome.canScrollAt(x, y, 0, -1), [x, y])).toBe(true);
  expect(await chatTop(page)).toBe(chatBefore);
});

test('a notch over the chat still scrolls the chat', async ({ page }) => {
  await open(page);
  const chatBefore = await chatTop(page);
  // Well above the composer, over the messages.
  await page.evaluate(() => window.bridge.wheelScroll(0, 100, 300, 300));
  await page.waitForTimeout(500);
  expect(await chatTop(page)).toBeGreaterThan(chatBefore);
});

test('past the field\'s end the step stops there: the chat behind stays put', async ({ page }) => {
  await open(page);
  const r = await composerRect(page);
  const x = r[0] + r[2] / 2;
  const y = r[1] + r[3] / 2;
  // Scroll the field all the way down first.
  await page.evaluate(([x, y]) => {
    for (let i = 0; i < 50; i++) window.__glazeChrome.scrollAt(x, y, 0, 100);
  }, [x, y]);
  expect(await page.evaluate(([x, y]) => window.__glazeChrome.canScrollAt(x, y, 0, 1), [x, y])).toBe(false);
  expect(await page.evaluate(([x, y]) => window.__glazeChrome.ownsScrollAt(x, y), [x, y])).toBe(true);

  const chatBefore = await chatTop(page);
  await page.evaluate(([x, y]) => window.bridge.wheelScroll(0, 100, x, y), [x, y]);
  await page.waitForTimeout(500);
  expect(await chatTop(page)).toBe(chatBefore);
  // And nothing of that notch is kept for the way back up.
  expect(await page.evaluate(() => window.bridge._scrollRelay.pendingWheel.dy)).toBe(0);
});

test("at the field's top a notch up goes nowhere either", async ({ page }) => {
  await open(page);
  const r = await composerRect(page);
  const x = r[0] + r[2] / 2;
  const y = r[1] + r[3] / 2;
  const chatBefore = await chatTop(page);
  // The field opens at its top: a notch up has nowhere to go, and the chat
  // behind it is not where it goes.
  await page.evaluate(([x, y]) => window.bridge.wheelScroll(0, -100, x, y), [x, y]);
  await page.waitForTimeout(500);
  expect(await chatTop(page)).toBe(chatBefore);
});
