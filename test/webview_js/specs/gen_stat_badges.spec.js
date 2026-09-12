// The gen-stat row — elapsed clock and `Nt` token count — is level-reconciled
// out of whatever Flutter last pushed. The bug this file guards is an
// asymmetry: the streaming window strips `.token-count-inline` out of a
// gen-stat that *survives* (the clock keeps the row alive), and the update
// that brought the finished message back only ever retexted an element it
// assumed was still there. So after a Continue or a Regenerate the badge was
// gone for good — until the chat was re-rendered from scratch.
//
// These run in a real browser against the real renderer because the failure is
// a DOM-identity one: nothing about the message map is wrong, only what is
// left of the row that should display it.
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

/// A finished reply carrying both stats — the state a bubble sits in before
/// the user asks for more of it.
async function finishedReply(page, { genTime = '4.0s', tokens = 120 } = {}) {
  await page.evaluate(
    ([genTime, tokens]) => {
      window.bridge.setMessages(
        JSON.stringify([
          JSON.parse(window.__M('a1', 'assistant', 'She set the lamp down.', {
            genTime,
            tokens,
          })),
        ]),
      );
    },
    [genTime, tokens],
  );
  await page.waitForTimeout(60);
}

const update = async (page, extra) => {
  await page.evaluate(
    (extra) =>
      window.bridge.updateMessage(
        window.__M('a1', 'assistant', extra.text ?? 'She set the lamp down.', extra),
      ),
    extra,
  );
  await page.waitForTimeout(80);
};

/// Every token count the page is actually showing, one entry per meta row.
const tokenBadges = (page) =>
  page.evaluate(() =>
    [...document.querySelectorAll('.token-count-inline')].map((el) =>
      el.textContent.trim(),
    ),
  );

/// Waits for every elapsed-time badge to settle on `expected`, then returns
/// how many there were.
///
/// The badge is a RollingNumber, so its `textContent` is not the value: each
/// character is a column carrying a hidden `.digit-measure` ("0") next to the
/// visible `.digit`, and a column being animated out lingers in the DOM. The
/// value has to be composed from the visible glyphs instead.
async function settledTimeBadges(page, expected) {
  await page.waitForFunction((expected) => {
    const read = (badge) => {
      const columns = [...badge.querySelectorAll('.rolling-column')];
      if (columns.length === 0) return badge.textContent.trim();
      return columns
        .map((col) => {
          const glyph =
            col.querySelector('.symbol') ?? col.querySelector('.digit');
          return glyph ? glyph.textContent : '';
        })
        .join('');
    };
    const badges = [...document.querySelectorAll('.gen-time-badge')];
    return badges.length > 0 && badges.every((el) => read(el) === expected);
  }, expected);
  return page.evaluate(
    () => document.querySelectorAll('.gen-time-badge').length,
  );
}

test('a finished reply shows its token count', async ({ page }) => {
  await boot(page);
  await finishedReply(page);

  const badges = await tokenBadges(page);
  expect(badges.length).toBeGreaterThan(0);
  for (const badge of badges) expect(badge).toBe('120t');
});

test('the token count is dropped while the reply streams', async ({ page }) => {
  await boot(page);
  await finishedReply(page);

  // A Continue or Regenerate flags the target bubble as typing for the whole
  // streaming window; a stale count from the previous run must not sit there.
  await update(page, { isTyping: true, genTime: '4.0s', tokens: 120 });

  expect(await tokenBadges(page)).toEqual([]);
});

test('the token count comes back when the continuation lands', async ({
  page,
}) => {
  await boot(page);
  await finishedReply(page);
  await update(page, { isTyping: true, genTime: '4.0s', tokens: 120 });

  // The merged message: both runs' stats, and no longer typing.
  await update(page, {
    text: 'She set the lamp down.\n\nThen the door opened.',
    isTyping: false,
    genTime: '6.5s',
    tokens: 150,
  });

  const badges = await tokenBadges(page);
  expect(badges.length).toBeGreaterThan(0);
  for (const badge of badges) expect(badge).toBe('150t');
});

test('the elapsed time keeps updating across the same window', async ({
  page,
}) => {
  await boot(page);
  await finishedReply(page);
  await update(page, { isTyping: true, genTime: '4.0s', tokens: 120 });
  await update(page, { isTyping: false, genTime: '6.5s', tokens: 150 });

  expect(await settledTimeBadges(page, '6.5s')).toBeGreaterThan(0);
});

test('the clock leads the row it is rebuilt into', async ({ page }) => {
  await boot(page);
  // A reply with a count but no measurable time: the row exists without a
  // clock, so a later time has to be inserted ahead of the count rather than
  // appended after it.
  await finishedReply(page, { genTime: '0s', tokens: 120 });
  await update(page, { isTyping: false, genTime: '3.0s', tokens: 120 });

  const order = await page.evaluate(() =>
    [...document.querySelectorAll('.gen-stat')]
      .filter((stat) => stat.querySelector('.gen-time-badge'))
      .map((stat) =>
        [...stat.children].map((child) =>
          child.classList.contains('token-count-inline')
            ? 'tokens'
            : child.classList.contains('gen-time-wrapper')
              ? 'time'
              : 'icon',
        ),
      ),
  );

  expect(order.length).toBeGreaterThan(0);
  for (const row of order) {
    expect(row.indexOf('time')).toBeLessThan(row.indexOf('tokens'));
  }
});
