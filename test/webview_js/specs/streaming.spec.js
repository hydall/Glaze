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
    // Baseline: the string formatter cannot keep this. Stage 1 of the
    // rendering plan (parse, then format text nodes) is what makes it pass.
    test.fail();
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
  // Baseline: the string formatter cannot keep this. Stage 1 of the
  // rendering plan (parse, then format text nodes) is what makes it pass.
  test.fail();
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
  // Baseline: the string formatter cannot keep this. Stage 1 of the
  // rendering plan (parse, then format text nodes) is what makes it pass.
  test.fail();
  for (const body of ['<div clas', '<tab', 'обычный текст <', '<style>.a{col']) {
    await render(page, body, { isTyping: true });
    const visible = await text(page);
    expect(visible).not.toContain('<div clas');
    expect(visible).not.toContain('<style>');
    await expectCleanRender(page);
  }
});
