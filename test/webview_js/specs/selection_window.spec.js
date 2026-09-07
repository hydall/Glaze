// Selecting messages in a virtualised list.
//
// Selection is held by id and reaches the whole chat — "select everything
// above" walks the list's own item order, not the DOM. What the reader *sees*
// used to be written to the document only, which in a virtualised list is the
// twenty-odd rows currently mounted. And the list re-mounts the element it
// built once rather than re-rendering it, so a row outside the window at the
// moment of the click never learned it had been selected: scrolling back to it
// showed an unselected message in a chat that did not even look like it was in
// selection mode.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  await page.setViewportSize({ width: 420, height: 720 });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__chat = (count) =>
      JSON.stringify(
        Array.from({ length: count }, (_, i) => ({
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
        })),
      );
  });
  await page.evaluate(() => window.bridge.setMessages(window.__chat(80)));
  await page.waitForTimeout(600);
}

/** The classes one message carries, whether or not it is mounted right now. */
const classesOf = (page, id) =>
  page.evaluate((messageId) => {
    const item = window.bridge.virtualList.itemMap.get(messageId);
    return item ? [...item.el.classList] : null;
  }, id);

test('selection mode reaches messages outside the render window', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => window.bridge.setSelectionMode(true));

  // m2 is near the top of an 80-message chat that opened at the bottom: far
  // outside the mounted window.
  expect(await classesOf(page, 'm2')).toContain('selection-mode');
  expect(await classesOf(page, 'm79')).toContain('selection-mode');
});

test('selecting a run marks the messages the reader cannot see yet', async ({
  page,
}) => {
  await boot(page);
  await page.evaluate(() => {
    window.bridge.setSelectionMode(true);
    window.bridge.renderer.selectionManager.selectOnly('m75');
    window.bridge.selectMessagesAbove();
  });

  // Everything above m75 is selected, including the rows the window never held.
  expect(await classesOf(page, 'm1')).toContain('selected');
  expect(await classesOf(page, 'm40')).toContain('selected');
  expect(await classesOf(page, 'm74')).toContain('selected');
  expect(await classesOf(page, 'm76')).not.toContain('selected');

  // And they still read as selected once the reader scrolls up to them.
  await page.evaluate(() => window.bridge.virtualList.scrollToMessage('m40'));
  await page.waitForTimeout(900);
  const shown = await page.evaluate(() => {
    const el = document.querySelector('#chat-container [data-message-id="m40"]');
    return el ? [...el.classList] : null;
  });
  expect(shown).toContain('selected');
  expect(shown).toContain('selection-mode');
});

test('leaving selection mode clears the whole chat, not just the window', async ({
  page,
}) => {
  await boot(page);
  await page.evaluate(() => {
    window.bridge.setSelectionMode(true);
    window.bridge.renderer.selectionManager.selectOnly('m75');
    window.bridge.selectMessagesAbove();
    window.bridge.setSelectionMode(false);
  });

  expect(await classesOf(page, 'm1')).not.toContain('selected');
  expect(await classesOf(page, 'm1')).not.toContain('selection-mode');
  expect(await classesOf(page, 'm40')).not.toContain('selected');
});
