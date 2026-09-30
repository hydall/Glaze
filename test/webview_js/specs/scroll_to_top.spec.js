// The scroll-to-top button rides the same scroll tracker as the header. It has
// to arm only when the reader scrolls up away from the first message: opening a
// chat jumps to the bottom, and that programmatic jump must not put the button
// on screen before the reader has moved. These drive the real bridge, because
// the behaviour is entirely about which scrolls count as the reader's.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  // Capture the JS→Flutter callbacks the bridge emits. Installed before the
  // page's modules run so nothing is missed.
  await page.addInitScript(() => {
    window.__flutterCalls = [];
    window.flutter_inappwebview = {
      callHandler(name, ...args) {
        window.__flutterCalls.push({ name, args });
        return null;
      },
    };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    const msgs = [];
    for (let i = 0; i < 30; i++) {
      msgs.push({
        id: 'm' + i,
        role: i % 2 ? 'user' : 'assistant',
        text: 'message number ' + i + ' ' + 'lorem ipsum '.repeat(20),
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
  });
  await page.waitForTimeout(500);
}

const lastTopVisibility = (page) =>
  page.evaluate(() => {
    const calls = window.__flutterCalls.filter(
      (c) => c.name === 'onScrollToTopVisibility',
    );
    return calls.length ? calls[calls.length - 1].args[0] : null;
  });

// A reader's scroll: the wheel event is what marks the following move as
// theirs (see USER_SCROLL_INPUT_WINDOW_MS in chat_bridge_controller.js), so a
// bare scrollTop write would be suppressed as a layout correction.
async function userScrollTo(page, top) {
  await page.evaluate((t) => {
    const c = window.bridge.virtualList.container;
    c.dispatchEvent(
      new WheelEvent('wheel', {
        deltaY: -120,
        bubbles: true,
        cancelable: true,
      }),
    );
    c.scrollTop = t;
  }, top);
  await page.waitForTimeout(150);
}

test('opening a long chat does not show the button before the reader scrolls', async ({
  page,
}) => {
  await boot(page);
  const atBottom = await page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    return c.scrollTop > 100;
  });
  expect(atBottom, 'the chat should open away from the top').toBe(true);
  expect(await lastTopVisibility(page)).toBe(false);
});

test('scrolling up arms the button, returning to the top hides it', async ({
  page,
}) => {
  await boot(page);

  await userScrollTo(page, 500);
  expect(await lastTopVisibility(page)).toBe(true);

  await page.evaluate(() => {
    window.bridge.virtualList.container.scrollTop = 0;
  });
  await page.waitForTimeout(150);
  expect(await lastTopVisibility(page)).toBe(false);
});

test('scrollToTop jumps to the first message and retires the button', async ({
  page,
}) => {
  await boot(page);

  await userScrollTo(page, 500);
  expect(await lastTopVisibility(page)).toBe(true);

  await page.evaluate(() => window.bridge.scrollToTop());
  await page.waitForTimeout(150);
  const atTop = await page.evaluate(
    () => window.bridge.virtualList.container.scrollTop,
  );
  expect(atTop).toBe(0);
  expect(await lastTopVisibility(page)).toBe(false);
});
