// The chat page must never scroll itself: #chat-container is the only scroller.
//
// Flutter mirrors its glass chrome (header, input pill, buttons) into the page
// as `position: fixed` backdrop-filter strips. Those strips are positioned in
// WebView-local coordinates, so the moment the page scrolls or the embedder
// pans its viewport, the whole page — strips included — slides out from under
// the Flutter chrome and trails it through every keyboard and drawer
// animation. Locking the document is what keeps the two layers agreeing.
//
// The same lock is what routes a caret/selection reveal to the container: with
// nowhere else to scroll, the browser has to scroll #chat-container, which is
// where `scroll-padding` keeps the reveal clear of the chrome.
import { test, expect } from '@playwright/test';

const COMPOSER = 130;

async function openChat(page) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate((composer) => {
    const long = Array.from({ length: 60 }, (_, i) => `line ${i} of the reply`).join('\n');
    const msgs = [];
    for (let i = 0; i < 12; i++) {
      msgs.push({
        id: `m${i}`, role: 'assistant', text: i === 11 ? long : `short ${i}`,
        timestamp: 1767225600000, isUser: false, isAssistant: true,
        isSystem: false, isError: false, isHidden: false, isTyping: false,
        isGenerating: false, isPostGenRunning: false,
      });
    }
    window.bridge.setMessages(JSON.stringify(msgs));
    window.bridge.setBottomPadding(composer, 0);
  }, COMPOSER);
  await page.waitForTimeout(400);
}

test('the document is locked so only the chat container scrolls', async ({ page }) => {
  await openChat(page);

  const lock = await page.evaluate(() => {
    const html = getComputedStyle(document.documentElement);
    const body = getComputedStyle(document.body);
    return {
      htmlPosition: html.position,
      htmlOverflow: html.overflowY,
      bodyPosition: body.position,
      bodyOverflow: body.overflowY,
    };
  });

  expect(lock.htmlPosition).toBe('fixed');
  expect(lock.bodyPosition).toBe('fixed');
  expect(lock.htmlOverflow).toBe('hidden');
  expect(lock.bodyOverflow).toBe('hidden');
  // The container is a normal scroller inside the locked page.
  expect(
    await page.evaluate(
      () => getComputedStyle(document.getElementById('chat-container')).overflowY,
    ),
  ).toBe('auto');
});

test('a caret reveal scrolls the container and leaves the document at zero', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => window.bridge.startEdit('m11'));
  await page.waitForTimeout(300);

  // Park the caret inside the band the composer covers, the way scrolling to
  // the bottom and hitting edit does.
  await page.evaluate((composer) => {
    const c = document.getElementById('chat-container');
    const ta = document.querySelector('[data-message-id="m11"] .edit-textarea');
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
    const want = c.getBoundingClientRect().bottom - composer + 40;
    c.scrollTop += ta.getBoundingClientRect().bottom - want;
  }, COMPOSER);
  await page.waitForTimeout(150);

  await page.keyboard.type('a');
  await page.waitForTimeout(250);

  const { docTop, containerTop } = await page.evaluate(() => ({
    docTop: document.scrollingElement.scrollTop,
    containerTop: document.getElementById('chat-container').scrollTop,
  }));
  // The reveal went to the container; the page never moved.
  expect(docTop).toBe(0);
  expect(containerTop).toBeGreaterThan(0);
});

test('a document scroll is undone and handed to the container', async ({ page }) => {
  await openChat(page);

  // Force a document scroll the CSS lock would normally prevent, so the
  // bridge's guard is the thing under test rather than the stylesheet.
  await page.evaluate(() => {
    document.documentElement.style.cssText =
      'position: static; overflow: visible; width: 100%; height: auto;';
    document.body.style.cssText =
      'position: static; overflow: visible; width: 100%; height: 5000px;';
  });
  await page.waitForTimeout(50);

  const before = await page.evaluate(() => {
    const c = document.getElementById('chat-container');
    c.scrollTop = 0;
    return c.scrollTop;
  });
  await page.evaluate(() => window.scrollTo(0, 180));
  await page.waitForTimeout(100);

  const after = await page.evaluate(() => ({
    docTop: document.scrollingElement.scrollTop,
    containerTop: document.getElementById('chat-container').scrollTop,
  }));

  // The page is put back; the movement lands on the container instead.
  expect(after.docTop).toBe(0);
  expect(after.containerTop).toBeGreaterThan(before);
});
