// A finger dragged over the message being edited scrolls the chat exactly as
// it does over any other message: by the browser's own touch scroll.
//
// The edit textarea grows to fit its text and never scrolls itself, so the
// drag has to chain to #chat-container. It used to be stopped at the textarea
// (`overscroll-behavior: contain`) and re-driven by hand from touchmove, with a
// home-made glide on release. On a phone that hand-driven scroll and the
// browser's own both moved the chat — the browser takes the gesture whenever
// the first touchmove goes uncancelled — and the glide, fed by jittery touch
// timestamps, threw the chat back and forth. Over any other message the chat
// scrolled fine.
import { test, expect } from '@playwright/test';

test.use({ hasTouch: true, isMobile: true, viewport: { width: 400, height: 800 } });

async function openEditedChat(page) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    const long = Array.from({ length: 60 }, (_, i) => `line ${i} of the reply`).join('\n');
    const msgs = [];
    for (let i = 0; i < 10; i++) {
      msgs.push({
        id: `m${i}`, role: 'assistant', text: i === 5 ? long : `short ${i}\n\n` + 'filler '.repeat(80),
        timestamp: 1767225600000, isUser: false, isAssistant: true,
        isSystem: false, isError: false, isHidden: false, isTyping: false,
        isGenerating: false, isPostGenRunning: false,
      });
    }
    window.bridge.setMessages(JSON.stringify(msgs));
  });
  await page.waitForTimeout(400);
  await page.evaluate(() => window.bridge.startEdit('m5'));
  await page.waitForTimeout(300);
  // Put the edited message in the middle of the screen, with room both ways.
  await page.evaluate(() => {
    const ta = document.querySelector('[data-message-id="m5"] .edit-textarea');
    const c = document.getElementById('chat-container');
    c.scrollTop += ta.getBoundingClientRect().top - 200;
  });
  await page.waitForTimeout(300);
}

/** Drags a finger over (x, y) by dy pixels (negative = finger up) and returns
 * how far the chat moved, after any glide has died away. */
async function drag(page, x, y, dy) {
  const before = await page.evaluate(() => document.getElementById('chat-container').scrollTop);
  const cdp = await page.context().newCDPSession(page);
  const steps = 20;
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', {
      type: 'touchMove', touchPoints: [{ x, y: y + (dy * i) / steps }],
    });
    await page.waitForTimeout(16);
  }
  // Hold still before lifting so no fling is left over.
  await page.waitForTimeout(150);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await page.waitForTimeout(600);
  const after = await page.evaluate(() => document.getElementById('chat-container').scrollTop);
  return after - before;
}

for (const dir of [-1, 1]) {
  test(`dragging the edited message ${dir < 0 ? 'up' : 'down'} scrolls the chat with the finger`, async ({ page }) => {
    await openEditedChat(page);
    const box = await page.locator('[data-message-id="m5"] .edit-textarea').boundingBox();
    const x = box.x + box.width / 2;
    const y = dir < 0 ? 600 : 250;
    const moved = await drag(page, x, Math.min(y, box.y + box.height - 20), dir * 200);
    // Finger up → content up → scrollTop grows by the drag, no more, no less.
    expect(Math.abs(moved + dir * 200)).toBeLessThan(25);
  });
}

test('the edited message drags the chat the same distance as any other message', async ({ page }) => {
  await openEditedChat(page);
  const box = await page.locator('[data-message-id="m5"] .edit-textarea').boundingBox();
  const overEdit = await drag(page, box.x + box.width / 2, 500, -200);
  await page.evaluate(() => {
    const c = document.getElementById('chat-container');
    c.scrollTop -= 200;
  });
  await page.waitForTimeout(200);
  const otherBox = await page.locator('[data-message-id="m4"] .msg-body').boundingBox();
  const overOther = await drag(page, otherBox.x + otherBox.width / 2, Math.max(otherBox.y + 20, 300), -200);
  expect(Math.abs(overEdit)).toBeGreaterThan(150);
  expect(Math.abs(overEdit - overOther)).toBeLessThan(25);
});
