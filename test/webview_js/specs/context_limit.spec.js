// The CONTEXT LIMIT rule marks where the prompt's history begins: the chat
// above it is history the model no longer sees.
//
// Flutter pushes one message id (the oldest message the last prompt build kept)
// and the page draws the rule inside that message. The failures these protect
// against are a rule that multiplies as the boundary moves, one that survives
// the chat it was drawn for, and one that a re-render silently drops.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, role, text) =>
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
      });
  });
}

/// Renders `m1..m4`, alternating roles, as one full batch.
async function render(page) {
  await page.evaluate(() => {
    const ids = ['m1', 'm2', 'm3', 'm4'];
    window.bridge.setMessages(
      JSON.stringify(
        ids.map((id, i) =>
          JSON.parse(window.__M(id, i % 2 === 0 ? 'user' : 'assistant', id)),
        ),
      ),
    );
  });
}

/// Ids of the messages currently wearing the rule — a list, because the bug
/// worth catching is two of them at once.
const marked = (page) =>
  page.evaluate(() =>
    [...document.querySelectorAll('.context-limit-marker')].map(
      (el) => el.closest('.message-section')?.dataset.messageId ?? null,
    ),
  );

test('the rule is drawn inside the message the prompt starts at', async ({
  page,
}) => {
  await boot(page);
  await render(page);
  await page.evaluate(() => window.bridge.setContextWindowStart('m2'));

  expect(await marked(page)).toEqual(['m2']);
  // First child, so it reads as a rule above the message rather than a badge
  // somewhere inside it.
  expect(
    await page.evaluate(
      () =>
        document.querySelector('.message-section[data-message-id="m2"]')
          .firstElementChild.className,
    ),
  ).toBe('context-limit-marker');
});

test('moving the boundary leaves exactly one rule behind', async ({ page }) => {
  await boot(page);
  await render(page);
  await page.evaluate(() => window.bridge.setContextWindowStart('m2'));
  await page.evaluate(() => window.bridge.setContextWindowStart('m3'));

  expect(await marked(page)).toEqual(['m3']);
});

test('an empty boundary retires the rule', async ({ page }) => {
  await boot(page);
  await render(page);
  await page.evaluate(() => window.bridge.setContextWindowStart('m2'));
  await page.evaluate(() => window.bridge.setContextWindowStart(''));

  expect(await marked(page)).toEqual([]);
});

test('a re-render redraws the rule without another push', async ({ page }) => {
  await boot(page);
  await render(page);
  await page.evaluate(() => window.bridge.setContextWindowStart('m3'));

  // What a preset switch does: the same messages, rendered again.
  await render(page);

  expect(await marked(page)).toEqual(['m3']);
});

test('a boundary this chat has no message for draws nothing', async ({
  page,
}) => {
  await boot(page);
  await render(page);
  await page.evaluate(() => window.bridge.setContextWindowStart('gone'));

  expect(await marked(page)).toEqual([]);

  // And the next real boundary still lands.
  await page.evaluate(() => window.bridge.setContextWindowStart('m4'));
  expect(await marked(page)).toEqual(['m4']);
});
