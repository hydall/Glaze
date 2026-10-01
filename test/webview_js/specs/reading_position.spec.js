// What the reader is looking at must not move when something above it is
// re-measured.
//
// A reply is streamed and then reflows: the body finalises, a reasoning box
// collapses, an image block appears, an `<img>` finishes loading. Each of those
// changes a row's height after it has been mounted, and the rows below it are
// re-laid-out while `scrollTop` stays where it was — so in a chat of long
// messages the text under the reader slides down the screen, one screenful per
// event, while the scrollbar does not move. The reporter saw it as the chat
// "jumping" when a post finished and again when its picture arrived.
//
// These drive the real page because the failure is a geometry one: the cache is
// updated correctly, only the reader's offset is not. They read `scrollTop` and
// the anchor's on-screen position, neither of which a source assertion can see.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  await page.setViewportSize({ width: 400, height: 700 });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, role, text, extra = {}) => ({
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
    window.__fill = (n) => {
      const msgs = [];
      for (let i = 0; i < n; i++) {
        msgs.push(window.__M(
          'm' + i,
          i % 2 ? 'user' : 'assistant',
          'Message ' + i + '. ' + 'lorem ipsum dolor sit amet '.repeat(4),
        ));
      }
      window.bridge.setMessages(JSON.stringify(msgs));
    };
  });
}

/** The topmost mounted row crossing the viewport top, and where it sits. */
const anchor = (page) =>
  page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    const view = c.getBoundingClientRect();
    const rows = [...document.querySelectorAll('#chat-container .message-section')];
    const el = rows.find((r) => r.getBoundingClientRect().bottom > view.top + 1);
    if (!el) return null;
    // The last mounted row that ends above the viewport — the one a late
    // reflow is most likely to be for (an earlier message growing).
    const above = rows.filter((r) => r.getBoundingClientRect().bottom <= view.top + 1);
    return {
      id: el.dataset.messageId,
      offset: el.getBoundingClientRect().top - view.top,
      aboveId: above.length ? above[above.length - 1].dataset.messageId : null,
      scrollTop: c.scrollTop,
    };
  });

async function openMidChat(page, count, scrollTop) {
  await boot(page);
  await page.evaluate((n) => window.__fill(n), count);
  await page.waitForTimeout(600);
  await page.evaluate((top) => {
    window.bridge.virtualList.container.scrollTop = top;
  }, scrollTop);
  await page.waitForTimeout(400);
}

test('a row that grows above the reader does not move the text under them', async ({
  page,
}) => {
  await openMidChat(page, 60, 1500);
  const before = await anchor(page);
  expect(before, 'no mounted row was in view').not.toBeNull();
  expect(before.aboveId, 'the fixture needs a row above the viewport').not.toBeNull();

  // The row above the reader gets much taller, as an image block landing in an
  // earlier message does.
  await page.evaluate((id) => {
    window.bridge.updateMessage(JSON.stringify(window.__M(
      id,
      'assistant',
      'HUGE ' + 'lorem ipsum dolor sit amet '.repeat(120),
    )));
  }, before.aboveId);
  await page.waitForTimeout(800);

  const after = await anchor(page);
  expect(after.id, 'the anchor row changed').toBe(before.id);
  expect(
    Math.abs(after.offset - before.offset),
    'the text under the reader slid with the row above it',
  ).toBeLessThan(4);
  expect(after.scrollTop, 'scrollTop was not offset to hold the reading position')
    .toBeGreaterThan(before.scrollTop);
});

test('a row that shrinks above the reader does not move the text under them', async ({
  page,
}) => {
  await openMidChat(page, 60, 1500);

  // Grow the row above first, then shrink it back: the shrink must offset the
  // other way, not leave the reader where the growth put them.
  const before = await anchor(page);
  await page.evaluate((id) => {
    window.bridge.updateMessage(JSON.stringify(window.__M(
      id,
      'assistant',
      'HUGE ' + 'lorem ipsum dolor sit amet '.repeat(120),
    )));
  }, before.aboveId);
  await page.waitForTimeout(600);
  const grown = await anchor(page);

  await page.evaluate((id) => {
    window.bridge.updateMessage(JSON.stringify(window.__M(id, 'assistant', 'short')));
  }, before.aboveId);
  await page.waitForTimeout(800);

  const after = await anchor(page);
  expect(after.id).toBe(before.id);
  expect(Math.abs(after.offset - before.offset)).toBeLessThan(4);
  expect(after.scrollTop, 'the shrink did not give the offset back')
    .toBeLessThan(grown.scrollTop);
});

test('a bottom-pinned reader still follows a row that grows above them', async ({ page }) => {
  await openMidChat(page, 30, 0);
  // Park at the very end, then grow a row well above the viewport. The follow,
  // not the reading-position offset, owns the scroll while pinned at the
  // bottom: the reader must slide back down to the newest message.
  await page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    c.scrollTop = c.scrollHeight;
  });
  await page.waitForTimeout(300);
  await page.evaluate(() => {
    const target = window.bridge.virtualList.itemMap.get('m20');
    window.bridge.updateMessage(JSON.stringify(window.__M(
      target.id,
      'assistant',
      'mid ' + 'lorem ipsum dolor sit amet '.repeat(60),
    )));
  });
  await page.waitForTimeout(800);

  const atBottom = await page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    return Math.abs(c.scrollTop + c.clientHeight - c.scrollHeight) <= 2;
  });
  expect(atBottom, 'a pinned reader was left off the bottom').toBe(true);
});
