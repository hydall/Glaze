// The reasoning box is per-variation: a reply from a reasoning model has one,
// a reply from a non-reasoning model does not, and swiping between them has to
// show whichever the active variation actually carries.
//
// The bug this file guards is the box never coming back. Regenerating with a
// non-reasoning model removes it — correctly, the new variation has no
// thinking — but the reasoning text is still in the database under the old
// swipe, so swiping back must rebuild the block. `updateMessageContent` used to
// only ever rewrite an element it assumed was still there.
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

/// A reply that came from a reasoning model.
async function replyWithReasoning(page) {
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(
          window.__M('a1', 'assistant', 'She set the lamp down.', {
            reasoning: 'The room is cold, so she would want the light near.',
            swipeIndex: 0,
            swipeTotal: 1,
          }),
        ),
      ]),
    );
  });
  await page.waitForTimeout(80);
}

const update = async (page, text, extra) => {
  await page.evaluate(
    ([text, extra]) =>
      window.bridge.updateMessage(window.__M('a1', 'assistant', text, extra)),
    [text, extra],
  );
  await page.waitForTimeout(80);
};

const hasReasoning = (page) =>
  page.evaluate(() => !!document.querySelector('.msg-reasoning'));

const reasoningText = (page) =>
  page.evaluate(() => {
    const host = document.querySelector(
      '.msg-reasoning-inner .message-content',
    );
    if (!host) return null;
    const root = host.shadowRoot ?? host;
    return root.textContent.trim();
  });

test('a reasoning reply renders its box', async ({ page }) => {
  await boot(page);
  await replyWithReasoning(page);

  expect(await hasReasoning(page)).toBe(true);
  expect(await reasoningText(page)).toContain('The room is cold');
});

test('regenerating with a non-reasoning model drops the box', async ({
  page,
}) => {
  await boot(page);
  await replyWithReasoning(page);

  // Regen opens a fresh variation: blank text, typing, and no reasoning key at
  // all (the Dart mapper omits it when null).
  await update(page, '', { isTyping: true, swipeIndex: 1, swipeTotal: 2 });
  await update(page, 'She left it on the table.', {
    isTyping: false,
    swipeIndex: 1,
    swipeTotal: 2,
  });

  expect(await hasReasoning(page)).toBe(false);
});

test('swiping back to the reasoning variation rebuilds the box', async ({
  page,
}) => {
  await boot(page);
  await replyWithReasoning(page);
  await update(page, '', { isTyping: true, swipeIndex: 1, swipeTotal: 2 });
  await update(page, 'She left it on the table.', {
    isTyping: false,
    swipeIndex: 1,
    swipeTotal: 2,
  });

  // Swipe back. The reasoning is still in the database under swipe 0, so the
  // block has to be re-created — there is nothing left to rewrite.
  await update(page, 'She set the lamp down.', {
    reasoning: 'The room is cold, so she would want the light near.',
    swipeIndex: 0,
    swipeTotal: 2,
    swipeDirection: 'right',
  });

  expect(await hasReasoning(page)).toBe(true);
  expect(await reasoningText(page)).toContain('The room is cold');
});

test('the rebuilt box sits above the reply, not after it', async ({ page }) => {
  await boot(page);
  await replyWithReasoning(page);
  await update(page, 'plain', { isTyping: false, swipeIndex: 1, swipeTotal: 2 });
  await update(page, 'She set the lamp down.', {
    reasoning: 'Thinking again.',
    swipeIndex: 0,
    swipeTotal: 2,
  });

  const order = await page.evaluate(() => {
    const stack = document.querySelector('.msg-content-stack');
    return [...stack.children].map((child) =>
      child.classList.contains('msg-reasoning')
        ? 'reasoning'
        : child.classList.contains('msg-transition-wrapper')
          ? 'body'
          : 'other',
    );
  });

  expect(order.indexOf('reasoning')).toBeGreaterThanOrEqual(0);
  expect(order.indexOf('reasoning')).toBeLessThan(order.indexOf('body'));
});
