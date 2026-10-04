// The elapsed clock under the typing bubble. Two things conspired to keep it
// off screen for the first second of every generation in battery saver:
//
//   1. `start()` only installed a setInterval, and setInterval does not fire
//      until a whole period has passed — 1000ms in battery saver.
//   2. The clock is started by the send window, and the bubble it belongs to is
//      appended later in that same dispatch (see ChatWebViewSyncDispatcher), so
//      even an immediate paint has nothing on screen to write on.
//   3. The badge was built through `_createGenStat`, which drops a clock
//      reading '0s' — a finished message with no recorded time has none — and
//      '0s' is precisely what a clock reads on the tick that creates it.
//
// These run in a real browser against the real bridge because all three are
// timing and DOM-identity failures: nothing about the state pushed from Flutter
// is wrong, only when and whether the page paints it.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, role, text, extra = {}) =>
      JSON.stringify({
        id,
        role,
        text,
        timestamp: 1767225600000,
        isUser: role === 'user',
        isAssistant: role !== 'user',
        isSystem: false,
        displayName: role === 'user' ? 'You' : 'Alice',
        isError: false,
        isHidden: false,
        isGenerating: false,
        isPostGenRunning: false,
        ...extra,
      });
  });
}

/// The order Flutter actually dispatches in: the generation flags go first and
/// the typing bubble is appended after, so the clock starts against an empty
/// chat and has to find its bubble afterwards.
async function sendWindowThenBubble(page, { batterySaver }) {
  await page.evaluate((batterySaver) => {
    window.bridge.batterySaver = batterySaver;
    window.bridge.setMessages(
      JSON.stringify([JSON.parse(window.__M('a1', 'assistant', 'greeting'))]),
    );
    window.bridge.setSendPending(true);
    window.bridge.appendMessage(
      window.__M('__streaming__', 'assistant', '', { isTyping: true }),
    );
  }, batterySaver);
}

const clockText = (page) =>
  page.evaluate(() => {
    const el = document.querySelector(
      '[data-message-id="__streaming__"] .gen-time-badge',
    );
    return el ? el.textContent.trim() : null;
  });

const hasClock = (page) =>
  page.evaluate(
    () =>
      !!document.querySelector(
        '[data-message-id="__streaming__"] .gen-time-badge',
      ),
  );

const genStatCount = (page) =>
  page.evaluate(
    () =>
      document.querySelectorAll('[data-message-id="__streaming__"] .gen-stat')
        .length,
  );

test('battery saver paints the clock without waiting out its full second', async ({
  page,
}) => {
  await boot(page);
  await sendWindowThenBubble(page, { batterySaver: true });

  // Well inside the 1000ms battery-saver interval. Before this change the
  // first tick was the only thing that could create the badge, so the reader
  // watched a placeholder with no clock on it for the whole second.
  await page.waitForTimeout(350);
  expect(await clockText(page)).toBe('0s');
});

test('the full-rate clock lands one badge on the bubble too', async ({
  page,
}) => {
  await boot(page);
  await sendWindowThenBubble(page, { batterySaver: false });

  // Outside battery saver the badge is animated, so its text is a stack of
  // rolling digits and not worth asserting on — what matters here is that the
  // same path builds exactly one clock on a bubble that appears after it.
  await page.waitForTimeout(350);
  expect(await genStatCount(page)).toBe(1);
  expect(await hasClock(page)).toBe(true);
});

test('the first paint leaves exactly one gen-stat behind', async ({ page }) => {
  await boot(page);
  await sendWindowThenBubble(page, { batterySaver: true });

  // Past the first real interval: a '0s' paint that built nothing would have
  // appended an empty gen-stat here and a second, populated one a tick later.
  await page.waitForTimeout(1400);
  expect(await genStatCount(page)).toBe(1);
  expect(await clockText(page)).toBe('1s');
});

test('priming stops as soon as the bubble is found', async ({ page }) => {
  await boot(page);
  await sendWindowThenBubble(page, { batterySaver: true });

  await page.waitForTimeout(350);
  const priming = await page.evaluate(
    () => window.bridge._genTimer._prime !== null,
  );
  expect(priming).toBe(false);
});

test('a clock already running is not restarted by the generation edge', async ({
  page,
}) => {
  await boot(page);
  await sendWindowThenBubble(page, { batterySaver: false });
  await page.waitForTimeout(400);
  const startedBefore = await page.evaluate(
    () => window.bridge._genTimer._start,
  );

  // The send window hands off to the generation proper. Both edges reconcile
  // through _syncGenerationTimer, and the bubble is the same one — so the
  // clock has to keep the count the reader has been watching.
  await page.evaluate(() => {
    window.bridge.setGenerating(true);
    window.bridge.setSendPending(false);
  });
  await page.waitForTimeout(250);

  const startedAfter = await page.evaluate(
    () => window.bridge._genTimer._start,
  );
  expect(startedAfter).toBe(startedBefore);
});

// A regenerate, continue or post-clean run does not stream into the
// `__streaming__` placeholder — it streams into a message that is already on
// screen under its own id. The clock has to find that bubble, and keep it: the
// only thing marking it as this run's bubble is the typing indicator, and the
// first token replaces that with the reply.
async function regenerate(page) {
  await page.evaluate(() => {
    window.bridge.batterySaver = true;
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(window.__M('a1', 'assistant', 'the reply being replaced')),
      ]),
    );
    window.bridge.setGenerating(true);
    window.bridge.updateMessage(
      window.__M('a1', 'assistant', '', { isTyping: true, isGenerating: true }),
    );
  });
}

const regenClock = (page) =>
  page.evaluate(() => {
    const el = document.querySelector('[data-message-id="a1"] .gen-time-badge');
    return el ? el.textContent.trim() : null;
  });

test('a regenerated bubble gets the clock too', async ({ page }) => {
  await boot(page);
  await regenerate(page);

  await page.waitForTimeout(350);
  expect(await regenClock(page)).toBe('0s');
});

test('the clock keeps counting once the reply starts arriving', async ({
  page,
}) => {
  await boot(page);
  await regenerate(page);
  await page.waitForTimeout(350);

  // The first token replaces the typing indicator with the reply. Re-deriving
  // the bubble from that indicator on every tick lost it here, and the clock
  // froze for the rest of the run.
  await page.evaluate(() => {
    window.bridge.updateMessage(
      window.__M('a1', 'assistant', 'a fresh', {
        isTyping: true,
        isGenerating: true,
      }),
    );
  });
  await page.waitForTimeout(1400);
  expect(await regenClock(page)).toBe('1s');

  await page.waitForTimeout(1000);
  expect(await regenClock(page)).toBe('2s');
});

test('the clock releases its bubble when the run ends', async ({ page }) => {
  await boot(page);
  await regenerate(page);
  await page.waitForTimeout(350);
  expect(await page.evaluate(() => window.bridge._genTimer._boundId)).toBe('a1');

  await page.evaluate(() => window.bridge.setGenerating(false));
  expect(await page.evaluate(() => window.bridge._genTimer._boundId)).toBeNull();
});
