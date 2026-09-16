// A reply arrives a chunk at a time, and every chunk is rendered. A card must
// look like a card from its first prefix — not like a wall of tags that turns
// into a card once the closing tag lands.
import { test, expect } from '@playwright/test';
import { card, prefixes, streamingCards } from '../corpus/cards.js';
import { openHarness, render, text, expectCleanRender } from './harness.js';

test.beforeEach(async ({ page }) => {
  await openHarness(page);
});

for (const id of streamingCards) {
  test(`${id} renders as markup at every prefix`, async ({ page }) => {
    const entry = card(id);
    for (const prefix of prefixes(entry.text)) {
      await render(page, prefix, { isTyping: true });
      const visible = await text(page);
      // The tell-tale of a half-parsed card: the reader sees the tag itself.
      // A lone `<` from prose is fine; `<div`, `<table`, `<span` are not.
      expect(visible, `prefix of ${entry.text.length} chars showed raw markup`)
        .not.toMatch(/<\/?[a-z][a-z0-9-]*[\s>]/i);
      await expectCleanRender(page);
    }
  });
}

test('a card is a real element before its closing tag arrives', async ({ page }) => {
  const body = '<div class="card"><b>Sandrone</b>\nещё печатает';
  await render(page, body, { isTyping: true });
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      card: root.querySelectorAll('div.card').length,
      bold: !!root.querySelector('div.card b'),
      visible: root.textContent,
    };
  });
  expect(shape.card, 'the browser closes the tag; the reader sees a card').toBe(1);
  expect(shape.bold).toBe(true);
  expect(shape.visible).not.toContain('<div');
});

test('a half-written tag never reaches the reader as text', async ({ page }) => {
  for (const body of ['<div clas', '<tab', 'обычный текст <', '<style>.a{col']) {
    await render(page, body, { isTyping: true });
    const visible = await text(page);
    expect(visible).not.toContain('<div clas');
    expect(visible).not.toContain('<style>');
    await expectCleanRender(page);
  }
});

test('streaming updates reuse the message shadow host', async ({ page }) => {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__streamMessage = (text) => JSON.stringify({
      id: 'a1',
      role: 'assistant',
      text,
      timestamp: 1767225600000,
      isUser: false,
      isAssistant: true,
      isSystem: false,
      isError: false,
      isHidden: false,
      isTyping: true,
      isGenerating: true,
      isPostGenRunning: false,
    });
    window.bridge.setMessages(JSON.stringify([]));
    window.bridge.appendMessage(window.__streamMessage('first'));
  });
  await page.waitForTimeout(50);
  await page.evaluate(() => {
    window.__streamHost = document.querySelector(
      '[data-message-id="a1"] .msg-body > .message-content',
    );
    window.bridge.updateMessage(window.__streamMessage('first and second'));
  });
  await page.waitForTimeout(50);

  const shape = await page.evaluate(() => {
    const host = document.querySelector(
      '[data-message-id="a1"] .msg-body > .message-content',
    );
    return {
      sameHost: host === window.__streamHost,
      text: host?.shadowRoot?.querySelector('.glaze-message')?.textContent,
    };
  });
  expect(shape.sameHost).toBe(true);
  expect(shape.text).toContain('first and second');
});

test('transient streaming prefixes do not fill the formatter cache', async ({ page }) => {
  await render(page, 'first prefix', { isTyping: true });
  expect(await page.evaluate(() => window.harness.formatter.cache.size)).toBe(0);

  await render(page, 'settled message');
  expect(await page.evaluate(() => window.harness.formatter.cache.size)).toBe(1);
});
