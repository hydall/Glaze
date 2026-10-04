// What the chat's bottom padding is for, when the keyboard is up.
//
// The chat WebView is full-screen and the scaffold runs with
// `resizeToAvoidBottomInset: false`, so on Android the keyboard OVERLAYS the
// page: the visual viewport shrinks, the container's layout height does not.
// The padding Flutter's inset turns into is what buys the scroll range that
// pushes the end of the list out from under the chrome — so it has to survive
// that, or the bottom of the list is simply unreachable.
//
// Where an embedder really does resize the WebView, the container's own height
// falls with it and the padding must come off instead, or the list ends in a
// screenful of empty space.
import { test, expect } from '@playwright/test';

const COMPOSER = 130;
const KEYBOARD = 380;

async function openEditedChat(page) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate((composer) => {
    const long = Array.from({ length: 50 }, (_, i) => `line ${i} of the reply`).join('\n');
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
  await page.evaluate(() => window.bridge.startEdit('m11'));
  await page.waitForTimeout(300);
}

/** Scrolls as far down as the chat allows and reports where the list ends. */
const endOfListAtMaxScroll = (page, keyboard) =>
  page.evaluate((k) => {
    const c = document.getElementById('chat-container');
    c.scrollTop = c.scrollHeight;
    const editor = document.querySelector('.edit-textarea');
    return {
      padBottom: Math.round(parseFloat(c.style.paddingBottom) || 0),
      keyboardTop: c.clientHeight - k,
      listEnd: Math.round(editor.getBoundingClientRect().bottom),
    };
  }, keyboard);

test('an overlaying keyboard leaves the end of the list reachable', async ({ page }) => {
  await openEditedChat(page);

  // The keyboard covers the page: the browser reports a shorter VISUAL
  // viewport while the container's layout height is untouched. Headless has no
  // keyboard, so the platform's half of that is stubbed — the page's own
  // measurements are left alone, which is the point of the test.
  await page.evaluate(([composer, k]) => {
    const c = document.getElementById('chat-container');
    Object.defineProperty(window, 'visualViewport', {
      configurable: true,
      value: {
        height: c.clientHeight - k,
        addEventListener() {},
        removeEventListener() {},
      },
    });
    window.bridge.setBottomPadding(composer + k, c.clientHeight);
  }, [COMPOSER, KEYBOARD]);
  await page.waitForTimeout(900);

  const { padBottom, keyboardTop, listEnd } = await endOfListAtMaxScroll(page, KEYBOARD);
  // The whole inset has to stay: nothing shrank, so nothing paid for it.
  expect(padBottom).toBe(COMPOSER + KEYBOARD);
  // Scrolled all the way down, the last line clears the keyboard.
  expect(listEnd).toBeLessThanOrEqual(keyboardTop);
});

test('an embedder that resizes the WebView does not get padded twice', async ({ page }) => {
  await openEditedChat(page);

  // Here the WebView really is made shorter by the keyboard, so the scrollport
  // shrank on its own and that part of the inset is already paid for.
  await page.evaluate(([composer, k]) => {
    const c = document.getElementById('chat-container');
    const full = c.clientHeight;
    c.style.height = full - k + 'px';
    window.bridge.setBottomPadding(composer + k, full);
  }, [COMPOSER, KEYBOARD]);
  await page.waitForTimeout(900);

  const padBottom = await page.evaluate(
    () => Math.round(parseFloat(document.getElementById('chat-container').style.paddingBottom) || 0),
  );
  expect(padBottom).toBe(COMPOSER);
});
