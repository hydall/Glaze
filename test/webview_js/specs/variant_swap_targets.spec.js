// Switching a variation moves the whole variation. The reasoning box and the
// in-game clock are siblings of `.msg-body` inside `.msg-content-stack`, so a
// transform applied to the body alone slid the reply out from under them and
// the message visibly tore in half — the reasoning stayed pinned over a
// bubble that was already leaving. A finger that started on the reasoning box
// dragged the reply underneath it, too.
//
// The footer must stay put: its switcher and actions button have to remain
// where the user's thumb expects them while the content moves.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

async function boot(page) {
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
}

/// A reply carrying every element the swipe is supposed to move, plus two
/// variations so the switch is legal.
async function richReply(page) {
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(
          window.__M('a1', 'assistant', 'She set the lamp down.', {
            reasoning: 'The room is cold, so the light belongs near her.',
            gameTime: 'Day 3, 21:40',
            swipeIndex: 0,
            swipeTotal: 2,
            isLast: true,
          }),
        ),
      ]),
    );
  });
  await page.waitForTimeout(80);
}

/// The inline transform/opacity of each element in the stack, by role.
const stackStyles = (page) =>
  page.evaluate(() => {
    const section = document.querySelector('[data-message-id="a1"]');
    const read = (selector) => {
      const el = section.querySelector(selector);
      if (!el) return null;
      return {
        transform: el.style.transform,
        opacity: el.style.opacity,
        height: el.style.height,
        overflow: el.style.overflow,
      };
    };
    return {
      reasoning: read('.msg-reasoning'),
      gameTime: read('.msg-game-time'),
      body: read('.msg-body'),
      footer: read('.msg-footer'),
    };
  });

test('the stack has all three moving parts plus a static footer', async ({
  page,
}) => {
  await boot(page);
  await richReply(page);

  const styles = await stackStyles(page);
  expect(styles.reasoning).not.toBeNull();
  expect(styles.gameTime).not.toBeNull();
  expect(styles.body).not.toBeNull();
  expect(styles.footer).not.toBeNull();
});

test('a variant swap slides the reasoning and the clock with the reply', async ({
  page,
}) => {
  await boot(page);
  await richReply(page);

  // Read the styles inside the 130 ms exit window, while the animation holds
  // them. The switch request itself is stubbed out — this is about the DOM.
  const styles = await page.evaluate(async () => {
    window.bridge._swipeHandler.animateVariantSwap('a1', 'next', () => {});
    await new Promise((r) => setTimeout(r, 40));
    const section = document.querySelector('[data-message-id="a1"]');
    const read = (selector) => {
      const el = section.querySelector(selector);
      if (!el) return null;
      return { transform: el.style.transform, opacity: el.style.opacity };
    };
    return {
      reasoning: read('.msg-reasoning'),
      gameTime: read('.msg-game-time'),
      body: read('.msg-body'),
      footer: read('.msg-footer'),
    };
  });

  for (const part of ['reasoning', 'gameTime', 'body']) {
    expect(styles[part].opacity, `${part} should fade with the swap`).toBe('0');
    expect(
      styles[part].transform,
      `${part} should slide with the swap`,
    ).toContain('translateX');
  }

  // The controls stay where the thumb left them.
  expect(styles.footer.opacity).toBe('');
  expect(styles.footer.transform).toBe('');
});

test('each moving part gets its own height lock, so the page cannot jump', async ({
  page,
}) => {
  await boot(page);
  await richReply(page);

  const heights = await page.evaluate(async () => {
    window.bridge._swipeHandler.animateVariantSwap('a1', 'next', () => {});
    await new Promise((r) => setTimeout(r, 40));
    const section = document.querySelector('[data-message-id="a1"]');
    return ['.msg-reasoning', '.msg-game-time', '.msg-body'].map((selector) => {
      const el = section.querySelector(selector);
      return { height: el.style.height, overflow: el.style.overflow };
    });
  });

  for (const { height, overflow } of heights) {
    expect(height).toMatch(/^\d+(\.\d+)?px$/);
    expect(overflow).toBe('hidden');
  }
});

test('the swap leaves every part with clean inline styles', async ({ page }) => {
  await boot(page);
  await richReply(page);

  await page.evaluate(() => {
    window.bridge._swipeHandler.animateVariantSwap('a1', 'next', () => {});
  });
  // 130 ms exit + a 300 ms fallback finish + 240 ms settle, with headroom.
  await page.waitForTimeout(900);

  const styles = await stackStyles(page);
  for (const part of ['reasoning', 'gameTime', 'body']) {
    expect(styles[part].transform, `${part} transform`).toBe('');
  }
});

test('a second swap aborts the first instead of fighting it', async ({
  page,
}) => {
  await boot(page);
  await richReply(page);

  // Two swaps inside the exit window: both requests must reach Dart, in order,
  // and the DOM must end up neutral rather than stuck faded out.
  const sent = await page.evaluate(async () => {
    const order = [];
    window.bridge._swipeHandler.animateVariantSwap('a1', 'next', () =>
      order.push('first'),
    );
    await new Promise((r) => setTimeout(r, 30));
    window.bridge._swipeHandler.animateVariantSwap('a1', 'prev', () =>
      order.push('second'),
    );
    await new Promise((r) => setTimeout(r, 900));
    return order;
  });

  expect(sent).toEqual(['first', 'second']);

  const styles = await stackStyles(page);
  for (const part of ['reasoning', 'gameTime', 'body']) {
    expect(styles[part].transform, `${part} transform`).toBe('');
    expect(styles[part].height, `${part} height lock`).toBe('');
    expect(styles[part].overflow, `${part} overflow`).toBe('');
  }
});
