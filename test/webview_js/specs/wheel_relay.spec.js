// A mouse-wheel notch on Windows reaches the page through the relay — see
// assets/chat_webview/bridge/scroll_relay.js — and has to scroll the way one
// does in a browser: the whole distance, spread over a few frames, notches in a
// row adding up, and nothing saved up past the end of the chat. These drive the
// real bridge in the real page.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const CURSOR = { x: 300, y: 300 };

async function openChat(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
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
  });
  await page.waitForTimeout(500);
  // Text laid out in a fallback face reflows when the real one arrives, and
  // every row changes height with it.
  await page.evaluate(() => document.fonts.ready);
  // Start at the very end, as an opened chat does.
  await page.evaluate(() => {
    const c = document.getElementById('chat-container');
    c.scrollTop = c.scrollHeight;
  });
  // And let the list come to rest, in height as well as position: a row
  // measured late grows the list and the anchor correction moves the
  // position with it, and a start read before that is not the start the
  // scrolls below add to.
  const layout = () =>
    page.evaluate(() => {
      const c = document.getElementById('chat-container');
      return c.scrollTop + ':' + c.scrollHeight;
    });
  await expect.poll(async () => {
    const a = await layout();
    await page.waitForTimeout(300);
    return a === (await layout());
  }, { timeout: 8000 }).toBe(true);
}

const scrollTop = (page) =>
  page.evaluate(() => document.getElementById('chat-container').scrollTop);

// Where the chat stands, counted from its end: scrollTop − scrollHeight, zero
// at the end and more negative the further up the chat is, by exactly as much
// as it scrolled. Not scrollTop itself: the virtual list renders a row the
// first time it comes into view, and one that measures taller than its
// estimate grows the list above the viewport while the browser keeps what is
// on screen where it is — scrollTop and scrollHeight both jump by the
// difference (74 px in one run of 'notches in a row add up' on a busy
// machine), and a scrollTop read before and after the scroll is off by that
// much although the chat moved exactly as far as it should. The distance
// from the end moves only when the chat does. In-page samplers below take
// the same reading inline.
const where = (page) =>
  page.evaluate(() => {
    const c = document.getElementById('chat-container');
    return c.scrollTop - c.scrollHeight;
  });

const wheel = (page, dy) =>
  page.evaluate(
    ([d, at]) => window.bridge.wheelScroll(0, d, at.x, at.y),
    [dy, CURSOR],
  );

// Waits until the chat has come to rest — the relay owes nothing more and the
// position held still for 150 ms — and returns where it stands. The end of
// the animation is waited for, not timed: a busy runner holds frames back,
// and a reading taken after a fixed wait or a fixed number of frames is
// taken mid-way.
async function rested(page) {
  let at;
  await expect.poll(async () => {
    const before = await where(page);
    await page.waitForTimeout(150);
    const idle = await page.evaluate(() => {
      const r = window.bridge._scrollRelay;
      return r.pendingWheel.dx === 0 && r.pendingWheel.dy === 0 &&
        r.pendingPan.dx === 0 && r.pendingPan.dy === 0 &&
        r.flingVelocity.vx === 0 && r.flingVelocity.vy === 0;
    });
    at = await where(page);
    return idle && at === before;
  }, { timeout: 5000 }).toBe(true);
  return at;
}

// Within two pixels of where the scroll should have taken the chat: the
// virtual list may nudge the position by one as a row re-measures.
const expectAt = (at, target) =>
  expect(Math.abs(at - target), `came to rest at ${at}, expected ${target}`)
    .toBeLessThan(2);

test('a notch scrolls its whole distance over several frames, not in one jump', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  // Room to scroll up.
  expect(await scrollTop(page)).toBeGreaterThan(1000);
  const start = await where(page);

  // Nothing moves in the call itself: the whole notch is owed to the frames
  // that follow, and every position the chat passes through is recorded.
  const owed = await page.evaluate(([d, at]) => {
    const c = document.getElementById('chat-container');
    const where = () => c.scrollTop - c.scrollHeight;
    window.bridge.wheelScroll(0, d, at.x, at.y);
    const positions = [where()];
    window.__positions = positions;
    const until = performance.now() + 3000;
    const sample = () => {
      const p = where();
      if (p !== positions[positions.length - 1]) positions.push(p);
      if (performance.now() < until) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
    return { moved: where(), pending: window.bridge._scrollRelay.pendingWheel.dy };
  }, [-300, CURSOR]);
  expect(owed.moved).toBe(start);
  expect(owed.pending).toBe(-300);

  expectAt(await rested(page), start - 300);
  // Several stops on the way — a frame can be late and carry a bigger share,
  // but never the whole distance at once.
  const positions = await page.evaluate(() => window.__positions);
  const onTheWay = positions.filter((p) => p < start && p > start - 300);
  expect(onTheWay.length).toBeGreaterThanOrEqual(3);
});

test('notches in a row add up', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  const start = await where(page);

  await wheel(page, -100);
  await wheel(page, -100);
  await wheel(page, -100);

  expectAt(await rested(page), start - 300);
});

test('a notch past the end of the chat is dropped, not saved for the way back', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  const end = await where(page);

  // Already at the end: nothing to scroll, nothing to remember.
  await wheel(page, 500);
  expect(await rested(page)).toBe(end);

  await wheel(page, -100);
  expectAt(await rested(page), end - 100);
});

test('the trusted wheel is kept until the relay is on, then dropped', async ({ page }) => {
  await openChat(page);
  const start = await where(page);
  await page.mouse.move(CURSOR.x, CURSOR.y);

  // Without the relay the page scrolls its own wheel, as every other platform
  // does.
  await page.mouse.wheel(0, -100);
  expectAt(await rested(page), start - 100);

  // With it, the trusted event is the plugin's duplicate of a notch Flutter
  // already relayed.
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  await page.mouse.wheel(0, -100);
  await page.waitForTimeout(300);
  expect(Math.abs((await where(page)) - (start - 100))).toBeLessThan(0.6);
});

test('reduced motion scrolls a notch at once', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));
  // Emulated once the page is up, and checked: on a busy CI runner the
  // emulation set before the load reached the document late, and the notch
  // animated.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect.poll(() =>
    page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches),
  ).toBe(true);
  const start = await where(page);

  // Read in the same breath as the call: nothing is left for a later frame.
  const after = await page.evaluate(([d, at]) => {
    window.bridge.wheelScroll(0, d, at.x, at.y);
    const c = document.getElementById('chat-container');
    return c.scrollTop - c.scrollHeight;
  }, [-300, CURSOR]);

  expect(Math.abs(after - (start - 300))).toBeLessThan(0.6);
});

test('a chat set anew drops what the last one still owed', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));

  const pending = await page.evaluate(([d, at]) => {
    window.bridge.wheelScroll(0, d, at.x, at.y);
    window.bridge.setMessages('[]');
    return window.bridge._scrollRelay.pendingWheel.dy;
  }, [-300, CURSOR]);

  expect(pending).toBe(0);
});

test('a wheel listener inside a message sees the relayed notch', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.relayNativeWheel(true));

  // A point inside a message's shadow root that is on screen, wherever the
  // layout put it.
  const at = await page.evaluate(() => {
    const hosts = [...document.querySelectorAll('#chat-container *')]
      .filter((el) => el.shadowRoot);
    for (const host of hosts) {
      for (const inner of host.shadowRoot.querySelectorAll('*')) {
        const r = inner.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) continue;
        const x = r.left + r.width / 2;
        const y = r.top + r.height / 2;
        if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) continue;
        if (document.elementFromPoint(x, y) !== host) continue;
        const hit = host.shadowRoot.elementFromPoint(x, y);
        if (!hit || hit === host) continue;
        window.__innerWheels = 0;
        hit.addEventListener('wheel', () => window.__innerWheels++);
        return { x, y };
      }
    }
    return null;
  });
  expect(at).not.toBeNull();

  await page.evaluate((p) => window.bridge.wheelScroll(0, -100, p.x, p.y), at);
  await expect.poll(() => page.evaluate(() => window.__innerWheels)).toBeGreaterThan(0);
});
