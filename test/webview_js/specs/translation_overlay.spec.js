// Display-only translation.
//
// The translation is painted over the bubble and nothing else: the section's
// rawText / sourceText — what the editor opens, what copy reads, what every
// tap reports back to Flutter — must keep the original, and a swipe or edit
// under a translation must drop it rather than show a translation of text the
// bubble no longer holds.
import { test, expect } from '@playwright/test';

const message = (overrides = {}) => ({
  id: 'c1', role: 'char', text: 'Hello there',
  timestamp: 1767225600000, isUser: false, isAssistant: true,
  isSystem: false, isError: false, isHidden: false, isTyping: false,
  isGenerating: false, isPostGenRunning: false, isLast: true,
  ...overrides,
});

async function openChat(page, { batterySaver = true, translationEnabled = true } = {}) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(({ msg, batterySaver, translationEnabled }) => {
    window.__sent = [];
    window.bridge._sendToFlutter = (name, args) => window.__sent.push([name, args]);
    window.bridge.setMessageSettings(JSON.stringify({ batterySaver, translationEnabled }));
    window.bridge.setMessages(JSON.stringify([msg]));
  }, { msg: message(), batterySaver, translationEnabled });
  await page.waitForTimeout(300);
}

const read = (page) =>
  page.evaluate(() => {
    const section = document.querySelector('[data-message-id="c1"]');
    const host = section?.querySelector('.msg-body > .message-content');
    const typing = section?.querySelector('.msg-body > .typing-container');
    const btn = section?.querySelector('.msg-translate-btn');
    return {
      shown: host?.shadowRoot?.querySelector('.glaze-message')?.textContent.trim() ?? null,
      typing: typing ? typing.querySelector('.typing-text')?.textContent : null,
      rawText: section?.dataset.rawText,
      translated: section?.classList.contains('translated'),
      translating: section?.classList.contains('translating'),
      buttonVisible: btn ? getComputedStyle(btn).display !== 'none' : false,
    };
  });

const tapTranslate = (page) =>
  page.evaluate(() => {
    document.querySelector('[data-message-id="c1"] .msg-translate-btn').click();
    return window.__sent.at(-1);
  });

test('the button is hidden until translation is switched on', async ({ page }) => {
  await openChat(page, { translationEnabled: false });
  expect((await read(page)).buttonVisible).toBe(false);
  await page.evaluate(() =>
    window.bridge.setMessageSettings(JSON.stringify({ translationEnabled: true })));
  expect((await read(page)).buttonVisible).toBe(true);
});

test('pending, translated and original states keep the stored text', async ({ page }) => {
  await openChat(page);

  const [name, args] = await tapTranslate(page);
  expect(name).toBe('onTranslateMessage');
  expect(JSON.parse(args[0])).toEqual({ id: 'c1', action: 'translate', text: 'Hello there' });

  const accepted = await page.evaluate(() => window.bridge.setTranslationPending(
    JSON.stringify({ id: 'c1', original: 'Hello there', label: 'Перевожу...' })));
  expect(accepted).toBe(true);
  let state = await read(page);
  expect(state.translating).toBe(true);
  expect(state.typing).toBe('Перевожу...');
  expect(state.buttonVisible).toBe(true);
  expect(JSON.parse((await tapTranslate(page))[1][0]).action).toBe('cancel');

  await page.evaluate(() => window.bridge.setTranslation(
    JSON.stringify({ id: 'c1', original: 'Hello there', text: 'Привет' })));
  state = await read(page);
  expect(state.shown).toBe('Привет');
  expect(state.translated).toBe(true);
  expect(state.rawText).toBe('Hello there');
  expect(JSON.parse((await tapTranslate(page))[1][0]).action).toBe('original');

  // The editor opens on the stored text, never the translation.
  const editorValue = await page.evaluate(() => {
    window.bridge.startEdit('c1');
    const value = document.querySelector('[data-message-id="c1"] .edit-textarea').value;
    window.bridge.stopEdit('c1');
    return value;
  });
  expect(editorValue).toBe('Hello there');
  // A cancelled edit puts the translation back.
  expect((await read(page)).shown).toBe('Привет');

  await page.evaluate(() => window.bridge.clearTranslation('c1'));
  state = await read(page);
  expect(state.shown).toBe('Hello there');
  expect(state.translated).toBe(false);
});

test('a re-render keeps the translation; a swipe drops it', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => {
    window.bridge.setTranslationPending(JSON.stringify({ id: 'c1', original: 'Hello there', label: 'x' }));
    window.bridge.setTranslation(JSON.stringify({ id: 'c1', original: 'Hello there', text: 'Привет' }));
  });

  // A background update with the same text (clock, badge) keeps it.
  await page.evaluate(() => {
    window.bridge.updateMessage(JSON.stringify({ id: 'c1', text: 'Hello there', time: '12:00' }));
    window.bridge.flush();
  });
  expect((await read(page)).shown).toBe('Привет');

  await page.evaluate((msg) => window.bridge.setMessages(JSON.stringify([msg])), message());
  await page.waitForTimeout(100);
  expect((await read(page)).shown).toBe('Привет');

  await page.evaluate(() => {
    window.bridge.updateMessage(JSON.stringify({ id: 'c1', text: 'Another swipe' }));
    window.bridge.flush();
  });
  const state = await read(page);
  expect(state.shown).toBe('Another swipe');
  expect(state.translated).toBe(false);
});

test('a result for text the bubble no longer shows is refused', async ({ page }) => {
  await openChat(page);
  const pending = await page.evaluate(() => window.bridge.setTranslationPending(
    JSON.stringify({ id: 'c1', original: 'Stale text', label: 'x' })));
  expect(pending).toBe(false);
  await page.evaluate(() => window.bridge.setTranslation(
    JSON.stringify({ id: 'c1', original: 'Stale text', text: 'Устаревший' })));
  const state = await read(page);
  expect(state.shown).toBe('Hello there');
  expect(state.translated).toBe(false);
});

test('the translation cross-fades in', async ({ page }) => {
  await openChat(page, { batterySaver: false });
  await page.evaluate(() => window.bridge.setTranslation(
    JSON.stringify({ id: 'c1', original: 'Hello there', text: 'Привет' })));
  const fading = await page.evaluate(() =>
    document.querySelector('[data-message-id="c1"] .msg-body').classList.contains('translation-fade-out'));
  expect(fading).toBe(true);
  await page.waitForTimeout(500);
  const state = await read(page);
  expect(state.shown).toBe('Привет');
  const leftover = await page.evaluate(() => {
    const body = document.querySelector('[data-message-id="c1"] .msg-body');
    return body.classList.contains('translation-fade-out') || body.classList.contains('translation-fade-in');
  });
  expect(leftover).toBe(false);
});

test('a translation stored before the bubble renders paints when it arrives', async ({ page }) => {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.bridge.setMessageSettings(JSON.stringify({ batterySaver: true, translationEnabled: true }));
    // The auto-translation of an arriving message races the sync that appends
    // it: the result is kept now and painted once the section exists.
    window.bridge.setTranslation(JSON.stringify({ id: 'c1', original: 'Hello there', text: 'Привет' }));
    window.bridge.setMessages(JSON.stringify([{
      id: 'c1', role: 'char', text: 'Hello there',
      timestamp: 1767225600000, isUser: false, isAssistant: true,
      isSystem: false, isError: false, isHidden: false, isTyping: false,
      isGenerating: false, isPostGenRunning: false, isLast: true,
    }]));
  });
  await page.waitForTimeout(200);
  const state = await read(page);
  expect(state.shown).toBe('Привет');
  expect(state.rawText).toBe('Hello there');
});

test('turning translation off restores every original', async ({ page }) => {
  await openChat(page);
  await page.evaluate(() => {
    window.bridge.setTranslation(JSON.stringify({ id: 'c1', original: 'Hello there', text: 'Привет' }));
    window.bridge.setMessageSettings(JSON.stringify({ batterySaver: true, translationEnabled: false }));
  });
  const state = await read(page);
  expect(state.shown).toBe('Hello there');
  expect(state.buttonVisible).toBe(false);
});
