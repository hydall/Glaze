// Editing a message while a background update lands on it.
//
// `updateMessage` patches one row in place (a LEDGER clock, a memory badge, a
// re-counted token total). It re-runs `updateMessageContent`, which clears
// `.msg-body` and rebuilds it — and while the row is `.editing` the body holds
// the user's `.edit-textarea`, so the rebuild destroyed the editor mid-edit and
// left the section classed `editing` with nothing to type into. Flutter, none
// the wiser, kept the composer read-only and regenerate hidden.
//
// The datasets the update writes are what `stopEdit` re-renders from, so the
// saved text still has to land once the edit ends.
import { test, expect } from '@playwright/test';

async function openChat(page) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.bridge.setMessages(JSON.stringify([{
      id: 'c1', role: 'char', text: 'original reply',
      timestamp: 1767225600000, isUser: false, isAssistant: true,
      isSystem: false, isError: false, isHidden: false, isTyping: false,
      isGenerating: false, isPostGenRunning: false, isLast: true,
    }]));
  });
  await page.waitForTimeout(400);
}

const readState = (page) =>
  page.evaluate(() => {
    const section = document.querySelector('[data-message-id="c1"]');
    const body = section?.querySelector('.msg-body');
    return {
      editing: section?.classList.contains('editing'),
      firstIsTextarea:
        body?.firstElementChild?.classList.contains('edit-textarea') ?? false,
      textareaValue: section?.querySelector('.edit-textarea')?.value ?? null,
    };
  });

test('a background update leaves the open editor and its text alone', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.startEdit('c1'));

  // A clock/token/badge-only update: text is carried too, as the mapper sends
  // the display form on every delta.
  await page.evaluate(() => {
    window.bridge.updateMessage(JSON.stringify({ id: 'c1', time: '12:00', text: 'original reply' }));
    window.bridge.flush();
  });

  const state = await readState(page);
  expect(state.editing).toBe(true);
  expect(state.firstIsTextarea).toBe(true);
  expect(state.textareaValue).toBe('original reply');
});

test('the saved text still lands after a mid-edit background update', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => {
    window.bridge.startEdit('c1');
    window.bridge.updateMessage(JSON.stringify({ id: 'c1', text: 'edited text' }));
    window.bridge.flush();
    window.bridge.stopEdit('c1');
  });

  const state = await readState(page);
  expect(state.editing).toBe(false);
  expect(state.firstIsTextarea).toBe(false);

  const text = await page.evaluate(() => {
    const host = document.querySelector('[data-message-id="c1"] .message-content');
    return host?.shadowRoot?.querySelector('.glaze-message')?.textContent ?? '';
  });
  expect(text).toContain('edited text');
});
