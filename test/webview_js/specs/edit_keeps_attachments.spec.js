// Editing a message that carries image attachments.
//
// `startEdit` swaps the message body for a textarea, and the body is rebuilt
// from the section's `rawText` when the edit ends. The attachment block is not
// in `rawText` — `updateMessageContent` only carries it across a rebuild when
// it finds it in the body. Clearing the whole body on edit lost the pictures
// until the chat was re-rendered from Flutter (reopening it, restarting).
import { test, expect } from '@playwright/test';

/** A 1×1 GIF, so nothing depends on a network fetch or a real file. */
const PIXEL =
  'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

async function openChat(page) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate((src) => {
    window.bridge.setMessages(JSON.stringify([{
      id: 'u1', role: 'user', text: 'look at this',
      timestamp: 1767225600000, isUser: true, isAssistant: false,
      isSystem: false, isError: false, isHidden: false, isTyping: false,
      isGenerating: false, isPostGenRunning: false,
      imagePath: src, imagePaths: [src, src],
    }]));
  }, PIXEL);
  await page.waitForTimeout(400);
}

const attachmentImages = (page) =>
  page.evaluate(() => document.querySelectorAll(
    '[data-message-id="u1"] .msg-body > .msg-image-attachment img',
  ).length);

test('attachments survive a cancelled edit', async ({ page }) => {
  await openChat(page);
  expect(await attachmentImages(page)).toBe(2);

  await page.evaluate(() => window.bridge.startEdit('u1'));
  await page.evaluate(() => window.bridge.stopEdit('u1'));

  expect(await attachmentImages(page)).toBe(2);
});

test('attachments survive a saved edit, whichever lands first', async ({ page }) => {
  await openChat(page);

  // Flutter's update before stopEdit — the update is batched, so flush it.
  await page.evaluate(() => {
    window.bridge.startEdit('u1');
    window.bridge.updateMessage(JSON.stringify({ id: 'u1', text: 'edited once' }));
    window.bridge.flush();
    window.bridge.stopEdit('u1');
  });
  expect(await attachmentImages(page)).toBe(2);

  // stopEdit before the update.
  await page.evaluate(() => {
    window.bridge.startEdit('u1');
    window.bridge.stopEdit('u1');
    window.bridge.updateMessage(JSON.stringify({ id: 'u1', text: 'edited twice' }));
    window.bridge.flush();
  });
  expect(await attachmentImages(page)).toBe(2);
});

test('attachments are hidden while the textarea is open', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.startEdit('u1'));

  const state = await page.evaluate(() => {
    const body = document.querySelector('[data-message-id="u1"] .msg-body');
    return {
      firstIsTextarea: body.firstElementChild?.classList.contains('edit-textarea'),
      attachmentDisplay: getComputedStyle(
        body.querySelector('.msg-image-attachment'),
      ).display,
    };
  });
  expect(state.firstIsTextarea).toBe(true);
  expect(state.attachmentDisplay).toBe('none');
});
