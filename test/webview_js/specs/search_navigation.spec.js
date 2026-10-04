// Walking the search hits with the prev/next arrows, in a virtualised list.
//
// The bug this holds down was reported as "the up/down buttons and the search
// don't let you get to the message" — the arrows moved the counter but the
// reader stayed where they were, or landed a screen away from the hit, or on a
// blank stretch of chat.
//
// It is a geometry failure, which is why these drive the real page. A hit in a
// message the list has not mounted has no measurable height: everything the
// height cache holds for it is an estimate, and the old jump computed its
// landing by summing those estimates. In a chat of uneven messages that is
// wrong by hundreds of pixels a row. Then the observers replaced the estimates
// with measurements, the top spacer was rewritten under a scroll position that
// did not move with it, and whatever the jump had reached slid away again.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

// Messages of very uneven length, and only some of them carry the needle. The
// unevenness is the point: it is what makes an estimated height wrong.
async function boot(page) {
  await page.setViewportSize({ width: 420, height: 720 });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__chat = (count) =>
      JSON.stringify(
        Array.from({ length: count }, (_, i) => {
          const long = 'lorem ipsum dolor sit amet consectetur '.repeat(2 + (i % 9) * 4);
          // Every seventh message holds one needle, in the middle of its body.
          const body = i % 7 === 3
            ? `${long} needle-${i} ${long}`
            : `Message ${i}. ${long}`;
          return {
            id: 'm' + i,
            role: i % 2 ? 'user' : 'assistant',
            text: body,
            timestamp: 1767225600000,
            isUser: i % 2 === 1,
            isAssistant: i % 2 === 0,
            isSystem: false,
            displayName: i % 2 ? 'You' : 'Alice',
            isError: false,
            isHidden: false,
            isGenerating: false,
            isPostGenRunning: false,
          };
        }),
      );
  });
}

async function openChat(page, count) {
  await page.evaluate((n) => window.bridge.setMessages(window.__chat(n)), count);
  await page.waitForTimeout(600);
}

/** Where the active hit sits relative to the viewport, or null if nowhere. */
const activeMatchBox = (page) =>
  page.evaluate(() => {
    const container = window.bridge.virtualList.container;
    const view = container.getBoundingClientRect();
    for (const host of document.querySelectorAll('.message-content')) {
      if (!host.shadowRoot) continue;
      const active = host.shadowRoot.querySelector(
        '.search-highlight-text.active-search-match',
      );
      if (!active) continue;
      const r = active.getBoundingClientRect();
      if (r.height === 0) continue;
      const section = host.closest('.message-section');
      return {
        top: r.top - view.top,
        bottom: r.bottom - view.top,
        viewHeight: view.height,
        text: active.textContent,
        messageId: section && (section.dataset.messageId || section.dataset.vlId),
      };
    }
    return null;
  });

/** How many message rows the reader can actually see. */
const onScreenCount = (page) =>
  page.evaluate(() => {
    const container = window.bridge.virtualList.container;
    const view = container.getBoundingClientRect();
    return [...document.querySelectorAll('#chat-container .message-section')].filter(
      (el) => {
        const r = el.getBoundingClientRect();
        return r.height > 0 && r.bottom > view.top && r.top < view.bottom;
      },
    ).length;
  });

const search = async (page, index) => {
  await page.evaluate((i) => window.bridge.setSearch('needle', i, true), index);
  // The jump settles over ~600ms (mounting, then correcting as real heights
  // arrive); the alignment is only final after that.
  await page.waitForTimeout(1100);
};

test('the first hit of a long chat is scrolled to, not merely highlighted', async ({
  page,
}) => {
  await boot(page);
  await openChat(page, 90);

  // Hit 0 lives in m3, ~87 messages above where the chat opens. Nothing about
  // that message has ever been measured.
  await search(page, 0);

  const box = await activeMatchBox(page);
  expect(box).not.toBeNull();
  expect(box.text).toContain('needle');
  expect(box.top).toBeGreaterThan(0);
  expect(box.bottom).toBeLessThan(box.viewHeight);
  expect(await onScreenCount(page)).toBeGreaterThan(0);
});

test('every arrow press lands on its own hit', async ({ page }) => {
  await boot(page);
  await openChat(page, 90);

  const seen = [];
  for (const index of [0, 1, 2, 3, 4]) {
    await search(page, index);
    const box = await activeMatchBox(page);
    expect(box, `hit ${index} is off screen`).not.toBeNull();
    expect(box.top).toBeGreaterThan(0);
    expect(box.bottom).toBeLessThan(box.viewHeight);
    seen.push(box.messageId);
  }
  // The corpus puts one needle in every seventh message, so consecutive hits
  // are in different messages: each press moved on rather than re-landing on
  // the one before it.
  expect(new Set(seen).size).toBe(seen.length);
});

test('walking backwards lands just as precisely', async ({ page }) => {
  await boot(page);
  await openChat(page, 90);

  await search(page, 6);
  for (const index of [5, 4, 3]) {
    await search(page, index);
    const box = await activeMatchBox(page);
    expect(box, `hit ${index} is off screen`).not.toBeNull();
    expect(box.top).toBeGreaterThan(0);
    expect(box.bottom).toBeLessThan(box.viewHeight);
  }
});

test('the hit stays put while the row settles', async ({ page }) => {
  await boot(page);
  await openChat(page, 90);

  await search(page, 2);
  const landed = await activeMatchBox(page);
  // Long after the jump: nothing — a late height correction, the observers
  // rewriting the spacers — may drag the match back out of view.
  await page.waitForTimeout(1200);
  const later = await activeMatchBox(page);
  expect(later).not.toBeNull();
  expect(Math.abs(later.top - landed.top)).toBeLessThan(24);
});

test('moving the active hit does not re-render the whole chat', async ({ page }) => {
  await boot(page);
  await openChat(page, 90);
  await search(page, 0);

  // The full pass re-formats and rewrites the shadow body of every message in
  // the chat. Doing that per arrow press is what made the arrows feel dead on
  // a long chat: the presses arrive faster than the passes finish.
  const formatCalls = await page.evaluate(async () => {
    const renderer = window.bridge.renderer;
    const formatter = renderer.formatter;
    const real = formatter.format.bind(formatter);
    let calls = 0;
    formatter.format = (...args) => { calls++; return real(...args); };
    window.bridge.setSearch('needle', 1, true);
    formatter.format = real;
    return calls;
  });
  expect(formatCalls).toBe(0);

  await page.waitForTimeout(1100);
  const box = await activeMatchBox(page);
  expect(box).not.toBeNull();
  expect(box.top).toBeGreaterThan(0);
  expect(box.bottom).toBeLessThan(box.viewHeight);
});

test('the reader can scroll away from a jump that is still settling', async ({
  page,
}) => {
  await boot(page);
  await openChat(page, 90);

  await page.evaluate(() => window.bridge.setSearch('needle', 4, true));
  await page.waitForTimeout(120);
  // A wheel notch mid-settle: the corrections must stand down rather than
  // dragging the view back under the reader.
  await page.evaluate(() => {
    const container = window.bridge.virtualList.container;
    container.dispatchEvent(new WheelEvent('wheel', { deltaY: 240, bubbles: true }));
    container.scrollTop += 600;
  });
  const afterUser = await page.evaluate(() => window.bridge.virtualList.container.scrollTop);
  await page.waitForTimeout(900);
  const settled = await page.evaluate(() => window.bridge.virtualList.container.scrollTop);
  expect(Math.abs(settled - afterUser)).toBeLessThan(200);
  expect(await onScreenCount(page)).toBeGreaterThan(0);
});

test('hits inside one long message are reached one by one', async ({ page }) => {
  await boot(page);
  // One message tall enough to be several screens, carrying three hits pages
  // apart. Centring the *message* would leave all three off screen: the jump
  // has to aim at the hit itself.
  await page.evaluate(() => {
    const filler = 'lorem ipsum dolor sit amet consectetur adipiscing elit. '.repeat(120);
    const body = `${filler} needle one ${filler} needle two ${filler} needle three ${filler}`;
    window.bridge.setMessages(
      JSON.stringify([
        {
          id: 'tall',
          role: 'assistant',
          text: body,
          timestamp: 1767225600000,
          isUser: false,
          isAssistant: true,
          isSystem: false,
          displayName: 'Alice',
          isError: false,
          isHidden: false,
          isGenerating: false,
          isPostGenRunning: false,
        },
      ]),
    );
  });
  await page.waitForTimeout(600);

  const tops = [];
  for (const index of [0, 1, 2]) {
    await search(page, index);
    const box = await activeMatchBox(page);
    expect(box, `hit ${index} is off screen`).not.toBeNull();
    expect(box.top).toBeGreaterThan(0);
    expect(box.bottom).toBeLessThan(box.viewHeight);
    tops.push(await page.evaluate(() => window.bridge.virtualList.container.scrollTop));
  }
  // Each hit is further down the same message than the one before it.
  expect(tops[1]).toBeGreaterThan(tops[0]);
  expect(tops[2]).toBeGreaterThan(tops[1]);
});

test('a jump to a hit never leaves the chat blank', async ({ page }) => {
  await boot(page);
  await openChat(page, 120);

  for (const index of [8, 0, 11, 3]) {
    await search(page, index);
    expect(await onScreenCount(page), `blank after hit ${index}`).toBeGreaterThan(0);
  }
});
