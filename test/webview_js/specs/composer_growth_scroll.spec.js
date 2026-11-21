// What the chat does when the composer grows under a long message.
//
// Flutter pushes the composer's height inside the bottom inset, and by default
// also as the inset's "non-scrolling" part. A push in which only that part
// moved re-pads the list but leaves it where it is: the composer grows over
// the messages instead of shoving them up line by line as the reader types.
// The keyboard still moves the list, and with the setting on (Flutter passes 0
// as the non-scrolling part) the composer does too.
import { test, expect } from '@playwright/test';

const COMPOSER = 130;
const GROWN = 190;
const KEYBOARD = 380;

async function openChatAtBottom(page, hold) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(([composer, h]) => {
    const msgs = [];
    for (let i = 0; i < 30; i++) {
      msgs.push({
        id: `m${i}`, role: 'assistant', text: `message ${i}\n\nwith a second paragraph`,
        timestamp: 1767225600000, isUser: false, isAssistant: true,
        isSystem: false, isError: false, isHidden: false, isTyping: false,
        isGenerating: false, isPostGenRunning: false,
      });
    }
    window.bridge.setMessages(JSON.stringify(msgs));
    const full = document.getElementById('chat-container').clientHeight;
    window.bridge.setBottomPadding(composer, full, h ? composer : 0);
  }, [COMPOSER, hold]);
  await page.waitForTimeout(500);
}

// Flutter always pushes the WebView box height alongside the inset.
const push = (page, px, hold) =>
  page.evaluate(([p, h]) => {
    const full = document.getElementById('chat-container').clientHeight;
    window.bridge.setBottomPadding(p, full, h);
  }, [px, hold]);

const metrics = (page) =>
  page.evaluate(() => {
    const c = document.getElementById('chat-container');
    return {
      scrollTop: Math.round(c.scrollTop),
      padBottom: Math.round(parseFloat(c.style.paddingBottom) || 0),
    };
  });

test('a growing composer leaves the list where it is by default', async ({ page }) => {
  await openChatAtBottom(page, true);
  const before = await metrics(page);
  expect(before.scrollTop).toBeGreaterThan(0);

  await push(page, GROWN, GROWN);
  await page.waitForTimeout(600);

  const after = await metrics(page);
  expect(after.padBottom).toBe(GROWN);
  expect(after.scrollTop).toBe(before.scrollTop);
});

test('the keyboard still moves the list while the composer is held', async ({ page }) => {
  await openChatAtBottom(page, true);
  const before = await metrics(page);

  await push(page, COMPOSER + KEYBOARD, COMPOSER);
  await page.waitForTimeout(900);

  const after = await metrics(page);
  expect(after.scrollTop - before.scrollTop).toBe(KEYBOARD);
});

test('with the follow turned on, the list rises with the composer', async ({ page }) => {
  await openChatAtBottom(page, false);
  const before = await metrics(page);

  await push(page, GROWN, 0);
  await page.waitForTimeout(900);

  const after = await metrics(page);
  expect(after.scrollTop - before.scrollTop).toBe(GROWN - COMPOSER);
});
