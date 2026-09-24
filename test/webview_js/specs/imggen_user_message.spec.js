// Image tags in a *user* message.
//
// A user can type `[IMG:GEN:…]` as an example or a note. Glaze only ever
// generates from an assistant message, so a user message's tag must render as
// the text that was written — never as an image placeholder. A placeholder
// there can never resolve, shows as "Generating image…" whenever any other
// generation is live, and carries a stop button that cancels that unrelated
// generation (the bug this covers).
import { test, expect } from '@playwright/test';
import { openHarness, render, text } from './harness.js';

const PENDING =
  'ooc: send a prompt like this and it generates an image. [IMG:GEN:a cat on a windowsill]';

async function placeholders(page) {
  return page.evaluate(() => {
    const host = document.querySelector('#chat-container .message-content');
    const root = host && host.shadowRoot;
    return root ? root.querySelectorAll('.imggen-loading').length : -1;
  });
}

test.beforeEach(async ({ page }) => {
  await openHarness(page);
});

test('a user message keeps its image tag as text', async ({ page }) => {
  await page.evaluate(() => {
    window.bridge.isGeneratingImage = true;
  });
  await render(page, PENDING, { isUser: true });

  expect(await placeholders(page)).toBe(0);
  expect(await text(page)).toContain('[IMG:GEN:a cat on a windowsill]');
  expect(await text(page)).not.toContain('Image queued');
  expect(await text(page)).not.toContain('Generating image');
});

test('an assistant message still renders the placeholder', async ({ page }) => {
  await page.evaluate(() => {
    window.bridge.isGeneratingImage = true;
  });
  await render(page, PENDING, { isUser: false });

  expect(await placeholders(page)).toBe(1);
});
