// Quick taps on a message's variation switcher. Flutter answers every switch
// with an `updateMessage`, and the footer used to be rebuilt from scratch on
// each one: a tap pressed on an arrow and released on its replacement never
// became a click, so flipping through variations quickly dropped taps and the
// switcher looked frozen. The fake Dart below steps the index the way
// ChatSwipeController does (refusing at the ends) and answers after a delay.
//
// The counter between the arrows opens the variation picker sheet.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const TOTAL = 6;

async function boot(page, { flutterDelay = 30 } = {}) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(({ TOTAL, flutterDelay }) => {
    const msg = (idx) => ({
      id: 'a1', role: 'assistant', text: `Variant ${idx}`, timestamp: 1767225600000,
      isUser: false, isAssistant: true, isSystem: false, displayName: 'Alice',
      isError: false, isHidden: false, isGenerating: false, isPostGenRunning: false,
      swipeIndex: idx, swipeTotal: TOTAL, isLast: true, messageIndex: 1,
    });
    window.__dart = { idx: 0, calls: [] };
    window.bridge.setMessages(JSON.stringify([
      { ...msg(0), id: 'u0', role: 'user', isUser: true, isAssistant: false, text: 'hi', swipeIndex: undefined, swipeTotal: undefined, isLast: false, messageIndex: 0 },
      msg(0),
    ]));
    window.bridge._sendToFlutter = (name, args) => {
      window.__dart.calls.push(name);
      if (name !== 'onSwipe') return;
      const { direction } = JSON.parse(args[0]);
      const next = window.__dart.idx + (direction === 'right' ? 1 : -1);
      if (next < 0 || next >= TOTAL) return; // Dart refuses, nothing comes back
      window.__dart.idx = next;
      setTimeout(() => window.bridge.updateMessage(JSON.stringify(msg(next))), flutterDelay);
    };
  }, { TOTAL, flutterDelay });
  await page.waitForTimeout(100);
}

async function tap(page, selector) {
  const box = await page.locator(selector).first().boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(25);
  await page.mouse.up();
}

const state = (page) => page.evaluate(() => {
  const s = document.querySelector('[data-message-id="a1"]');
  const body = s.querySelector('.msg-body');
  return {
    dart: window.__dart.idx,
    count: s.querySelector('.msg-switcher[data-kind="swipe"] .msg-switcher-count')?.textContent,
    text: s.dataset.rawText,
    opacity: body.style.opacity,
    height: body.style.height,
    transform: body.style.transform,
  };
});

for (const [gap, flutterDelay] of [[20, 30], [120, 30], [200, 30], [120, 150]]) {
  test(`rapid next taps every ${gap}ms all land (dart ${flutterDelay}ms)`, async ({ page }) => {
    await boot(page, { flutterDelay });
    for (let i = 0; i < 4; i++) {
      await tap(page, '[data-message-id="a1"] .msg-switcher-btn.next');
      await page.waitForTimeout(gap);
    }
    await page.waitForTimeout(800);
    const s = await state(page);
    expect(s.dart).toBe(4);
    expect(s.count).toBe('5/6');
    expect(s.text).toBe('Variant 4');
    expect(s.opacity === '' || s.opacity === '1').toBe(true);
    expect(s.height).toBe('');
    expect(s.transform).toBe('');
  });
}

test('hammering past the last variation leaves the bubble visible', async ({ page }) => {
  await boot(page);
  for (let i = 0; i < 10; i++) {
    await tap(page, '[data-message-id="a1"] .msg-switcher-btn.next');
    await page.waitForTimeout(70);
  }
  await page.waitForTimeout(800);
  const s = await state(page);
  expect(s.dart).toBe(5);
  expect(s.count).toBe('6/6');
  expect(s.text).toBe('Variant 5');
  expect(s.opacity === '' || s.opacity === '1').toBe(true);
  expect(s.height).toBe('');
});

test('an update landing while the arrow is held does not swallow the tap', async ({ page }) => {
  await boot(page);
  const box = await page.locator('[data-message-id="a1"] .msg-switcher-btn.next').boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  // Flutter re-sends the message mid-press (a badge, a clock, the previous
  // switch landing) — the footer is synced from it.
  await page.evaluate(() => {
    window.bridge.updateMessage(JSON.stringify({
      id: 'a1', text: 'Variant 0', swipeIndex: 0, swipeTotal: 6, isLast: true, tokens: 42,
    }));
    window.bridge.flush();
  });
  await page.mouse.up();
  await page.waitForTimeout(600);
  const s = await state(page);
  expect(s.dart).toBe(1);
  expect(s.count).toBe('2/6');
});

test('tapping the counter asks Flutter for the variation picker', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => {
    const send = window.bridge._sendToFlutter;
    window.__opened = [];
    window.bridge._sendToFlutter = (name, args) => {
      if (name === 'onOpenVariants') window.__opened.push(args);
      return send(name, args);
    };
  });
  await page.locator('[data-message-id="a1"] .msg-switcher-count').click();
  expect(await page.evaluate(() => window.__opened)).toEqual([['a1', 'swipe']]);
  // The counter is not an arrow: nothing switched.
  await page.waitForTimeout(300);
  expect((await state(page)).dart).toBe(0);
});

test('the counter stays the same element while variations change', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => {
    window.__count = document.querySelector('[data-message-id="a1"] .msg-switcher-count');
  });
  await tap(page, '[data-message-id="a1"] .msg-switcher-btn.next');
  await page.waitForTimeout(600);
  const same = await page.evaluate(() =>
    window.__count === document.querySelector('[data-message-id="a1"] .msg-switcher-count')
    && window.__count.textContent);
  expect(same).toBe('2/6');
});
