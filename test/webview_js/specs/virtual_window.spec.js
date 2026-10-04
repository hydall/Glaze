// The render window of the virtualised message list.
//
// Every case here is one chat that went blank and stayed blank — the bug the
// user hit as "the chat stops rendering; I have to open another chat and come
// back". Coming back worked because it is a fresh `setMessages`, which rebuilds
// the window from scratch; nothing short of that recovered.
//
// The failure is always the same shape: the rows that are mounted end up
// entirely above or below the viewport. The IntersectionObserver cannot report
// on them (they are further away than its 1000px margin), so `visibleIndices`
// empties, `updateWindow` has nothing to grow the window from, and the list
// sits there rendering nothing. These drive the real page in a real browser
// because the failure is a geometry one — a source-level assertion cannot see
// it.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  await page.setViewportSize({ width: 400, height: 700 });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, role, text) => ({
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
    });
    // Bodies of uneven length, so the height cache carries real estimates
    // rather than one uniform row height.
    window.__slice = (from, to) =>
      JSON.stringify(
        Array.from({ length: to - from }, (_, k) => {
          const i = from + k;
          return window.__M(
            'm' + i,
            i % 2 ? 'user' : 'assistant',
            `Message ${i}. ` + 'lorem ipsum dolor sit amet '.repeat(3 + (i % 7)),
          );
        }),
      );
  });
}

/** How many message rows the reader can actually see. */
const onScreenCount = (page) =>
  page.evaluate(() => {
    const container = window.bridge.virtualList.container;
    const view = container.getBoundingClientRect();
    return [...document.querySelectorAll('#chat-container .message-section')].filter(
      (el) => {
        const r = el.getBoundingClientRect();
        return r.height > 0 && r.bottom > view.top && r.top < view.bottom;
      },
    ).length;
  });

async function openChat(page, from, to) {
  await page.evaluate(([f, t]) => window.bridge.setMessages(window.__slice(f, t)), [from, to]);
  await page.waitForTimeout(600);
}

test('a jump that lands between the observer margin and the scroll buffer still renders', async ({
  page,
}) => {
  await boot(page);
  await openChat(page, 0, 60);
  expect(await onScreenCount(page)).toBeGreaterThan(0);

  // The dead zone: far enough from the mounted rows that nothing intersects
  // (the observer's margin is 1000px), close enough that the scroll handler's
  // 2000px "big jump" recovery does not fire either.
  await page.evaluate(() => {
    window.bridge.virtualList.container.scrollTop = 1200;
  });
  await page.waitForTimeout(400);

  expect(await onScreenCount(page)).toBeGreaterThan(0);
});

test('a chat left blank does not stay blank once the reader scrolls', async ({ page }) => {
  await boot(page);
  await openChat(page, 0, 60);

  await page.evaluate(() => {
    window.bridge.virtualList.container.scrollTop = 1200;
  });
  await page.waitForTimeout(300);
  // Small nudges — the size of a finger settling, not a fling.
  for (const delta of [40, -40, 60]) {
    await page.evaluate((d) => {
      window.bridge.virtualList.container.scrollTop += d;
    }, delta);
    await page.waitForTimeout(200);
  }

  expect(await onScreenCount(page)).toBeGreaterThan(0);
});

test('deleting a message does not blank the chat', async ({ page }) => {
  await boot(page);
  await openChat(page, 0, 60);
  await page.evaluate(() => {
    window.bridge.virtualList.container.scrollTop = 1200;
  });
  await page.waitForTimeout(400);

  await page.evaluate(() => window.bridge.removeMessage('m10'));
  await page.waitForTimeout(600);

  expect(await onScreenCount(page)).toBeGreaterThan(0);
});

test('an append while the reader is scrolled up does not blank the chat', async ({
  page,
}) => {
  await boot(page);
  await openChat(page, 0, 60);
  await page.evaluate(() => {
    window.bridge.virtualList.container.scrollTop = 1200;
  });
  await page.waitForTimeout(400);

  await page.evaluate(() => window.bridge.appendMessages(window.__slice(60, 62)));
  await page.waitForTimeout(600);

  expect(await onScreenCount(page)).toBeGreaterThan(0);
});

test('a fling straight to the top of a long chat renders the top', async ({ page }) => {
  await boot(page);
  await openChat(page, 0, 120);

  await page.evaluate(() => {
    window.bridge.virtualList.container.scrollTop = 0;
  });
  await page.waitForTimeout(500);

  expect(await onScreenCount(page)).toBeGreaterThan(0);
  expect(await page.evaluate(() => window.bridge.virtualList.renderStart)).toBe(0);
});

test('deleting keeps the observer index sets in step with the list', async ({ page }) => {
  await boot(page);
  await openChat(page, 0, 40);
  await page.waitForTimeout(300);

  // Every index the observer reported is an index into `items`. A delete
  // renumbers `items`, so a set left un-shifted points the next updateWindow()
  // at somebody else's row — and past the end of the list once enough rows go.
  await page.evaluate(() => {
    for (let i = 30; i < 40; i++) window.bridge.removeMessage('m' + i);
  });
  await page.waitForTimeout(1200);

  const { count, maxVisible } = await page.evaluate(() => {
    const vl = window.bridge.virtualList;
    return {
      count: vl.items.length,
      maxVisible: vl.visibleIndices.size ? Math.max(...vl.visibleIndices) : -1,
    };
  });
  expect(maxVisible).toBeLessThan(count);
  expect(await onScreenCount(page)).toBeGreaterThan(0);
});

test('emptying the chat does not leave the loading screen up', async ({ page }) => {
  await boot(page);
  await openChat(page, 0, 3);
  expect(await page.evaluate(() => !!document.getElementById('loading-screen'))).toBe(false);

  // What deleting the last message sends: clearAll raises the loading screen
  // for the re-render that follows it, and the re-render is an empty batch.
  await page.evaluate(() => {
    window.bridge.clearAll();
    window.bridge.setMessages('[]');
  });
  await page.waitForTimeout(500);

  expect(await page.evaluate(() => !!document.getElementById('loading-screen'))).toBe(false);
  expect(await onScreenCount(page)).toBe(0);
});
