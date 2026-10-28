// A fenced code block renders with a header: the language on the left and a
// copy button on the right. The button lives in the message shadow root, so
// the click has to be found through the composed path, and the copy goes
// through Flutter (`onSelectionAction`), like the selection bar's.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

const BODY = 'Here:\n\n```python\nprint("<b>hi</b>")\nx = 1\n```\n\nAnd plain:\n\n```\nno lang\n```';

async function boot(page) {
  const failures = [];
  page.on('pageerror', (error) => failures.push(String(error)));
  await page.addInitScript(() => {
    window.__flutterCalls = [];
    window.flutter_inappwebview = {
      callHandler(name, ...args) {
        window.__flutterCalls.push({ name, args });
        return null;
      },
    };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate((text) => {
    window.bridge.setMessages(JSON.stringify([{
      id: 'a1',
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
      swipeIndex: 0,
      swipeTotal: 1,
    }]));
  }, BODY);
  await page.waitForTimeout(80);
  page.__failures = failures;
}

test('every fenced block gets a header with a copy button', async ({ page }) => {
  await boot(page);
  const blocks = await page.evaluate(() => {
    const root = document.querySelector('[data-message-id="a1"] .message-content').shadowRoot;
    return [...root.querySelectorAll('.code-block-wrapper')].map((w) => ({
      lang: w.querySelector('.code-block-header .code-lang')?.textContent,
      hasButton: !!w.querySelector('.code-block-header .code-copy-btn'),
    }));
  });
  expect(blocks).toEqual([
    { lang: 'python', hasButton: true },
    { lang: '', hasButton: true },
  ]);
  expect(page.__failures).toEqual([]);
});

test('the copy button sends the block code, as written, to Flutter', async ({ page }) => {
  await boot(page);
  const button = page.locator('[data-message-id="a1"] .code-copy-btn').first();
  await button.click();
  const calls = await page.evaluate(() =>
    window.__flutterCalls.filter((c) => c.name === 'onSelectionAction'),
  );
  expect(calls).toHaveLength(1);
  expect(JSON.parse(calls[0].args[0])).toEqual({
    action: 'copy',
    text: 'print("<b>hi</b>")\nx = 1\n',
  });
  await expect(button).toHaveAttribute('data-copied', '1');
  expect(page.__failures).toEqual([]);
});
