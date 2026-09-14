// The elapsed clock on an `[IMG:GEN]` placeholder, across a retry.
//
// The formatter memoizes its output keyed on the message text
// (`Formatter.format`), and a pending block's HTML carries a wall-clock
// `data-start`. A retry re-renders the *same* text, so the cached HTML — and
// the timestamp baked into it — comes back, and the clock would carry on from
// the first attempt instead of starting over.
//
// This runs in a real browser because the whole question is DOM identity and
// time: nothing about the state Flutter pushes is wrong, only what the page
// does with a placeholder it has rendered once before.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, text) =>
      JSON.stringify({
        id,
        role: 'assistant',
        text,
        timestamp: 1767225600000,
        isUser: false,
        isAssistant: true,
        isSystem: false,
        displayName: 'Alice',
        isError: false,
        isHidden: false,
        isGenerating: false,
        isPostGenRunning: false,
      });
    window.__set = (text) =>
      window.bridge.setMessages(
        JSON.stringify([JSON.parse(window.__M('m1', text))]),
      );
  });
}

const PENDING = 'Here you go: [IMG:GEN:a cat on a windowsill]';

/// The clock reading, in seconds, or null when there is no placeholder.
const elapsed = (page) =>
  page.evaluate(() => {
    const host = document.querySelector('.message-content');
    const root = host && host.shadowRoot;
    if (!root) return null;
    const block = root.querySelector('.imggen-loading');
    if (!block) return null;
    const timer = (block.shadowRoot || block).querySelector(
      '.imggen-loading-timer',
    );
    if (!timer) return null;
    return parseFloat(timer.textContent);
  });

/// What the placeholder's own markup claims, which is what the cache carries.
const stampAge = (page) =>
  page.evaluate(() => {
    const host = document.querySelector('.message-content');
    const root = host && host.shadowRoot;
    const block = root && root.querySelector('.imggen-loading');
    if (!block) return null;
    const timer = (block.shadowRoot || block).querySelector(
      '.imggen-loading-timer',
    );
    if (!timer || !timer.dataset.start) return null;
    return (Date.now() - parseInt(timer.dataset.start, 10)) / 1000;
  });

test('a retried generation starts its clock over', async ({ page }) => {
  await boot(page);

  // The image stage is live, so the block is generating rather than queued.
  await page.evaluate(() => window.bridge.setImageGenerating(true));
  await page.evaluate((text) => window.__set(text), PENDING);

  // Let the first attempt run visibly.
  await page.waitForTimeout(1500);
  expect(await elapsed(page)).toBeGreaterThan(1);

  // The attempt fails: the block leaves the pending state...
  await page.evaluate(() => window.__set('Here you go: it failed'));
  await page.waitForTimeout(200);
  expect(await elapsed(page)).toBeNull();

  // ...and the retry puts the same text back, which is what hits the cache.
  await page.evaluate((text) => window.__set(text), PENDING);
  await page.waitForTimeout(250);

  const afterRetry = await elapsed(page);
  expect(afterRetry).not.toBeNull();
  expect(afterRetry).toBeLessThan(1);
  // And the stamp itself is fresh, not the first attempt's.
  expect(await stampAge(page)).toBeLessThan(1);
});

test('a re-render mid-generation does not restart the clock', async ({
  page,
}) => {
  await boot(page);
  await page.evaluate(() => window.bridge.setImageGenerating(true));
  await page.evaluate((text) => window.__set(text), PENDING);
  await page.waitForTimeout(1500);

  const before = await elapsed(page);
  expect(before).toBeGreaterThan(1);

  // Something else in the chat changes, so the message list is pushed again
  // with this message untouched. The reader is still waiting on the same
  // picture and the clock has to keep counting it.
  await page.evaluate((text) => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(window.__M('m1', text)),
        JSON.parse(window.__M('m2', 'and something after it')),
      ]),
    );
  }, PENDING);
  await page.waitForTimeout(250);

  const after = await elapsed(page);
  expect(after).not.toBeNull();
  expect(after).toBeGreaterThanOrEqual(before);
});
