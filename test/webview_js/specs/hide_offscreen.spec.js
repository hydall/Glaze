// Hiding messages that are scrolled out of the virtual window.
//
// `updateMessage` looked its row up in the document only. A virtualised list
// mounts the twenty-odd rows around the viewport and keeps every other row's
// element detached in `itemMap`, so hiding a selection that reached past the
// window patched the rows on screen and skipped the rest: scrolling up showed
// those messages still visible, in a chat that had hidden them.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

const message = (i, extra = {}) => ({
  id: 'm' + i,
  role: i % 2 ? 'user' : 'assistant',
  text: `Message ${i}. ` + 'lorem ipsum dolor sit amet '.repeat(3 + (i % 7)),
  timestamp: 1767225600000,
  isUser: i % 2 === 1,
  isAssistant: i % 2 === 0,
  isSystem: false,
  displayName: i % 2 ? 'You' : 'Alice',
  isError: false,
  isHidden: false,
  isGenerating: false,
  isPostGenRunning: false,
  ...extra,
});

async function boot(page) {
  await page.setViewportSize({ width: 420, height: 720 });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(
    (msgs) => window.bridge.setMessages(JSON.stringify(msgs)),
    Array.from({ length: 80 }, (_, i) => message(i)),
  );
  await page.waitForTimeout(600);
}

const classesOf = (page, id) =>
  page.evaluate((messageId) => {
    const item = window.bridge.virtualList.itemMap.get(messageId);
    return item ? [...item.el.classList] : null;
  }, id);

test('hiding a message outside the render window marks its row', async ({ page }) => {
  await boot(page);
  // m2 sits at the top of a chat that opened at the bottom: not mounted.
  expect(
    await page.evaluate(
      () => !!document.querySelector('#chat-container [data-message-id="m2"]'),
    ),
  ).toBe(false);

  await page.evaluate(
    (msgs) => {
      for (const m of msgs) window.bridge.updateMessage(JSON.stringify(m));
      window.bridge.flush();
    },
    [message(2, { isHidden: true }), message(78, { isHidden: true })],
  );

  expect(await classesOf(page, 'm2')).toContain('msg-hidden');
  expect(await classesOf(page, 'm78')).toContain('msg-hidden');

  // And it still reads as hidden once the reader scrolls up to it.
  await page.evaluate(() => window.bridge.virtualList.scrollToMessage('m2'));
  await page.waitForTimeout(900);
  const shown = await page.evaluate(() => {
    const el = document.querySelector('#chat-container [data-message-id="m2"]');
    return el ? [...el.classList] : null;
  });
  expect(shown).toContain('msg-hidden');
});
