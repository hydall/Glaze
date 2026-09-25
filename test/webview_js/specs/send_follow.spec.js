// Sending a message appends the user's bubble and the typing placeholder, and
// the list has to land on them. It used to land late and in steps: the append
// grew the content while the viewport stayed put, then a `setTimeout(…, 50)`
// follow and a second `scrollToBottom()` from the bridge each re-pinned, so the
// reader watched the new bubble sit below the fold and then snap up. These
// drive the real bridge because the failure is a timing one — nothing about the
// rows is wrong, only when the list agrees to move.
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
    window.__fill = () => {
      const msgs = [];
      for (let i = 0; i < 30; i++) {
        msgs.push(JSON.parse(window.__M(
          'm' + i,
          i % 2 ? 'user' : 'assistant',
          'message number ' + i + ' ' + 'lorem ipsum '.repeat(20),
        )));
      }
      window.bridge.setMessages(JSON.stringify(msgs));
    };
  });
}

/// Where the tail sits relative to the viewport.
const tailShape = (page) =>
  page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    return {
      atBottom: Math.abs(c.scrollTop + c.clientHeight - c.scrollHeight) <= 1,
      max: c.scrollHeight - c.clientHeight,
      scrollTop: c.scrollTop,
    };
  });

test('a send lands on the bubble in the same frame it is appended', async ({
  page,
}) => {
  await boot(page);
  await page.evaluate(() => window.__fill());
  await page.waitForTimeout(400);

  const shape = await page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    const bottom = () => c.scrollTop + c.clientHeight;
    const max = () => c.scrollHeight;
    const before = bottom();
    window.bridge.requestScrollToBottomOnAppend();
    window.bridge.appendMessages(JSON.stringify([
      JSON.parse(window.__M('u-new', 'user', 'the message I just sent')),
    ]));
    // No frame is awaited: the follow must have landed already, or it paints
    // the new bubble below the viewport and snaps it up on the next one.
    const afterUser = bottom();
    const maxAfterUser = max();
    window.bridge.appendMessage(
      window.__M('__streaming__', 'assistant', '', { isTyping: true }),
    );
    const afterPlaceholder = bottom();
    const maxAfterPlaceholder = max();
    const section = document.querySelector('[data-message-id="u-new"]');
    return {
      before,
      afterUser,
      maxAfterUser,
      afterPlaceholder,
      maxAfterPlaceholder,
      bubbleOnScreen: section.getBoundingClientRect().top < c.clientHeight,
    };
  });

  expect(shape.afterUser, 'the user bubble grew the content and was not followed')
    .toBeCloseTo(shape.maxAfterUser, 0);
  expect(shape.afterPlaceholder, 'the placeholder was not followed')
    .toBeCloseTo(shape.maxAfterPlaceholder, 0);
  expect(shape.afterPlaceholder).toBeGreaterThan(shape.before);
  expect(shape.bubbleOnScreen, 'the sent bubble sat below the fold').toBe(true);
});

test('a plain append does not yank a reader who scrolled up', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => window.__fill());
  await page.waitForTimeout(400);
  await page.evaluate(() => {
    window.bridge.virtualList.container.scrollTop = 800;
  });
  await page.waitForTimeout(300);

  const shape = await page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    const before = c.scrollTop;
    window.bridge.appendMessages(JSON.stringify([
      JSON.parse(window.__M('u-late', 'user', 'a message from elsewhere')),
    ]));
    return { before, after: c.scrollTop };
  });

  expect(shape.after).toBe(shape.before);
});
