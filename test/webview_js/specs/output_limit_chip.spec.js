// A reply cut off by the output-token cap carries `outputLimitHit` in its
// message map. The renderer draws a warning chip under the body for it, and
// the live update path has to add and drop that chip as the visible variation
// changes (a swipe, a continuation that finished the reply).
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  const failures = [];
  page.on('pageerror', (error) => failures.push(String(error)));
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, text, extra = {}) =>
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
        swipeIndex: 0,
        swipeTotal: 1,
        ...extra,
      });
  });
  page.__failures = failures;
  return page;
}

function shape(page) {
  return page.evaluate(() => {
    const stack = document.querySelector('[data-message-id="a1"] .msg-content-stack');
    const order = [...stack.children].map((child) =>
      child.classList.contains('msg-output-limit')
        ? 'limit'
        : child.classList.contains('msg-footer')
          ? 'footer'
          : child.classList.contains('msg-transition-wrapper')
            ? 'body'
            : child.className,
    );
    const chip = stack.querySelector('.msg-output-limit');
    return { order, hasIcon: !!chip?.querySelector('svg'), text: chip?.textContent ?? null };
  });
}

test('a cut-off reply renders the warning between body and footer', async ({ page }) => {
  await boot(page);
  await page.evaluate(() =>
    window.bridge.setMessages(
      JSON.stringify([JSON.parse(window.__M('a1', 'She opened her mouth to', { outputLimitHit: true }))]),
    ),
  );
  await page.waitForTimeout(80);

  const s = await shape(page);
  expect(s.order).toEqual(['body', 'limit', 'footer']);
  expect(s.hasIcon).toBe(true);
  expect(s.text).toContain('Max output tokens');
  expect(page.__failures).toEqual([]);
});

test('updates add and drop the warning with the variation', async ({ page }) => {
  await boot(page);
  await page.evaluate(() =>
    window.bridge.setMessages(JSON.stringify([JSON.parse(window.__M('a1', 'Done.'))])),
  );
  await page.waitForTimeout(80);
  expect((await shape(page)).order).toEqual(['body', 'footer']);

  await page.evaluate(() =>
    window.bridge.updateMessage(window.__M('a1', 'She opened her mouth to', { outputLimitHit: true })),
  );
  await page.waitForTimeout(200);
  expect((await shape(page)).order).toEqual(['body', 'limit', 'footer']);

  // A second update with the flag must not stack a second chip.
  await page.evaluate(() =>
    window.bridge.updateMessage(window.__M('a1', 'She opened her mouth to', { outputLimitHit: true })),
  );
  await page.waitForTimeout(200);
  expect((await shape(page)).order).toEqual(['body', 'limit', 'footer']);

  await page.evaluate(() =>
    window.bridge.updateMessage(window.__M('a1', 'She opened her mouth to speak.')),
  );
  await page.waitForTimeout(200);
  expect((await shape(page)).order).toEqual(['body', 'footer']);
  expect(page.__failures).toEqual([]);
});

test('tapping the warning asks Flutter for the explanation sheet', async ({ page }) => {
  await page.addInitScript(() => {
    window.__flutterCalls = [];
    window.flutter_inappwebview = {
      callHandler(name, ...args) {
        window.__flutterCalls.push({ name, args });
        return null;
      },
    };
  });
  await boot(page);
  await page.evaluate(() =>
    window.bridge.setMessages(JSON.stringify([JSON.parse(window.__M('a1', 'Cut', { outputLimitHit: true }))])),
  );
  await page.waitForTimeout(80);
  await page.click('[data-message-id="a1"] .msg-output-limit');
  const calls = await page.evaluate(() =>
    window.__flutterCalls.filter((c) => c.name === 'onOutputLimitClick'),
  );
  expect(calls).toEqual([{ name: 'onOutputLimitClick', args: ['a1'] }]);
  expect(page.__failures).toEqual([]);
});
