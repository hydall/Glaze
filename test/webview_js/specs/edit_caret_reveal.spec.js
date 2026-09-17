// The caret of an edited message, against the chrome Flutter draws on top of
// the page.
//
// The chat WebView is full-screen and never resizes when the keyboard opens
// (the scaffold runs with `resizeToAvoidBottomInset: false`), so the page's
// scrollport runs to the bottom of the screen even while the input bar and the
// keyboard cover its lower half. `padding-bottom` reserves that band at the END
// of the list, which keeps the newest message off the input bar — but a caret
// reached mid-list is a different matter: as far as the browser is concerned it
// is inside the scrollport and therefore visible, so its caret reveal leaves it
// exactly where it is. Scroll the chat down, hit edit, and you type behind the
// composer.
//
// `scroll-padding-bottom` is what tells the browser that band is covered.
import { test, expect } from '@playwright/test';

/** Stands in for the Flutter chrome covering the bottom of the page. */
const COMPOSER = 130;

async function openEditedChat(page) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate((composer) => {
    const long = Array.from({ length: 40 }, (_, i) => `line ${i} of the reply`).join('\n');
    const msgs = [];
    for (let i = 0; i < 8; i++) {
      msgs.push({
        id: `m${i}`, role: 'assistant', text: i === 3 ? long : `short ${i}`,
        timestamp: 1767225600000, isUser: false, isAssistant: true,
        isSystem: false, isError: false, isHidden: false, isTyping: false,
        isGenerating: false, isPostGenRunning: false,
      });
    }
    window.bridge.setMessages(JSON.stringify(msgs));
    window.bridge.setBottomPadding(composer, 0);
  }, COMPOSER);
  await page.waitForTimeout(400);
  await page.evaluate(() => window.bridge.startEdit('m3'));
  // startEdit finishes with a smooth scroll that runs for about half a second.
  await page.waitForTimeout(900);
}

/** Where the caret's line sits, and where the chrome starts.
 *
 * The caret on the last line ends at the textarea's CONTENT box, so the
 * element's own bottom padding and border come off — measuring the border box
 * would report the caret a dozen pixels lower than it is drawn. */
const geometry = (page) =>
  page.evaluate((composer) => {
    const c = document.getElementById('chat-container').getBoundingClientRect();
    const ta = document.querySelector('[data-message-id="m3"] .edit-textarea');
    const style = getComputedStyle(ta);
    const inner =
      parseFloat(style.paddingBottom) + parseFloat(style.borderBottomWidth);
    return {
      caretLine: Math.round(ta.getBoundingClientRect().bottom - inner),
      allowedBottom: Math.round(c.bottom - composer),
    };
  }, COMPOSER);

test('a caret behind the composer is revealed above it', async ({ page }) => {
  await openEditedChat(page);

  // Put the caret at the end and park that line inside the covered band, the
  // way scrolling to the bottom and hitting edit does.
  await page.evaluate((composer) => {
    const c = document.getElementById('chat-container');
    const ta = document.querySelector('[data-message-id="m3"] .edit-textarea');
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
    const want = c.getBoundingClientRect().bottom - composer + 40;
    c.scrollTop += ta.getBoundingClientRect().bottom - want;
  }, COMPOSER);
  await page.waitForTimeout(150);

  const parked = await geometry(page);
  expect(parked.caretLine, 'the caret has to start out covered').toBeGreaterThan(
    parked.allowedBottom,
  );

  await page.keyboard.type('a');
  await page.waitForTimeout(250);

  // Without scroll-padding the browser counts the caret as visible and this
  // number does not move at all.
  const revealed = await geometry(page);
  expect(revealed.caretLine).toBeLessThanOrEqual(revealed.allowedBottom);
});

test('the container carries scroll padding for both edges', async ({ page }) => {
  await openEditedChat(page);
  await page.evaluate(() => window.bridge.setTopPadding(72));
  const pads = await page.evaluate(() => {
    const s = getComputedStyle(document.getElementById('chat-container'));
    return {
      top: parseFloat(s.scrollPaddingTop),
      bottom: parseFloat(s.scrollPaddingBottom),
      paddingBottom: parseFloat(s.paddingBottom),
    };
  });
  // Each one clears its chrome, plus the gutter that keeps the caret off its
  // edge. The header's is pushed separately from the input bar's.
  expect(pads.top).toBeGreaterThan(72);
  expect(pads.bottom).toBeGreaterThan(pads.paddingBottom);
});
