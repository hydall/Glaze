// The in-game clock is stamped onto a message *after* the turn, so it usually
// arrives through `updateMessage` on an already-rendered section. When that
// section carries a reasoning panel, the panel nests its own
// `.msg-transition-wrapper`; an unscoped descendant query found that one first,
// and `insertBefore` threw "the node is not a child of this node" — so the
// clock never appeared on any reasoning message. The clock belongs between the
// reasoning panel and the reply body.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
  const failures = [];
  page.on('pageerror', (error) => failures.push(String(error)));
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, role, text, extra = {}) =>
      JSON.stringify({
        id,
        role,
        text,
        timestamp: 1767225600000,
        isUser: role === 'user',
        isAssistant: role !== 'user',
        isSystem: false,
        displayName: role === 'user' ? 'You' : 'Alice',
        isError: false,
        isHidden: false,
        isGenerating: false,
        isPostGenRunning: false,
        ...extra,
      });
  });
  page.__failures = failures;
  return page;
}

test('a clock stamped on a reasoning reply lands between reasoning and body', async ({
  page,
}) => {
  await boot(page);
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(
          window.__M('a1', 'assistant', 'She set the lamp down.', {
            reasoning: 'The room is cold, so the light belongs near her.',
            swipeIndex: 0,
            swipeTotal: 1,
          }),
        ),
      ]),
    );
  });
  await page.waitForTimeout(80);

  // The ledger stamps the clock after the turn — no clock at first render.
  await page.evaluate(() =>
    window.bridge.updateMessage(
      window.__M('a1', 'assistant', 'She set the lamp down.', {
        reasoning: 'The room is cold, so the light belongs near her.',
        gameTime: 'Day 3, 21:40',
        swipeIndex: 0,
        swipeTotal: 1,
      }),
    ),
  );
  await page.waitForTimeout(200);

  const shape = await page.evaluate(() => {
    const section = document.querySelector('[data-message-id="a1"]');
    const stack = section.querySelector('.msg-content-stack');
    const clock = section.querySelector('.msg-game-time');
    return {
      hasClock: !!clock,
      text: clock?.textContent ?? null,
      order: [...stack.children].map((child) =>
        child.classList.contains('msg-reasoning')
          ? 'reasoning'
          : child.classList.contains('msg-game-time')
            ? 'clock'
            : child.classList.contains('msg-transition-wrapper')
              ? 'body'
              : 'other',
      ),
    };
  });

  expect(shape.hasClock, 'the clock never rendered').toBe(true);
  expect(shape.text).toContain('Day 3, 21:40');
  expect(shape.order.indexOf('reasoning')).toBeLessThan(shape.order.indexOf('clock'));
  expect(shape.order.indexOf('clock')).toBeLessThan(shape.order.indexOf('body'));
  expect(page.__failures, 'uncaught page error').toEqual([]);
});

test('a clock still lands before the body on a plain reply', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(window.__M('a1', 'assistant', 'She set the lamp down.')),
      ]),
    );
  });
  await page.waitForTimeout(80);

  await page.evaluate(() =>
    window.bridge.updateMessage(
      window.__M('a1', 'assistant', 'She set the lamp down.', {
        gameTime: 'Day 1, 08:00',
      }),
    ),
  );
  await page.waitForTimeout(200);

  const order = await page.evaluate(() => {
    const stack = document.querySelector('[data-message-id="a1"] .msg-content-stack');
    return [...stack.children].map((child) =>
      child.classList.contains('msg-game-time')
        ? 'clock'
        : child.classList.contains('msg-transition-wrapper')
          ? 'body'
          : 'other',
    );
  });
  expect(order.indexOf('clock')).toBeGreaterThanOrEqual(0);
  expect(order.indexOf('clock')).toBeLessThan(order.indexOf('body'));
  expect(page.__failures, 'uncaught page error').toEqual([]);
});
