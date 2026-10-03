// Scrolling up into a page of older messages must be one continuous scroll.
//
// The chat opens on its newest page; reaching the top asks Flutter for the
// previous one, which arrives as `prependMessages`. The new rows go in above
// the reader at *estimated* heights — the cache has never seen them — and a
// long roleplay reply is several times taller than any estimate. The list then
// held its window on the rows the reader was already looking at, so nothing
// above them was mounted: the reader scrolled on into a spacer, saw an empty
// chat, and the blank-viewport recovery rebuilt the window from those
// estimates. The rows it mounted came in thousands of pixels taller than the
// cache said, and the reader was thrown several messages away from where they
// had been — the "position jumps / messages repeat" report.
//
// These drive the real page with real wheel input, because the failure is in
// what the reader sees between two frames: which rows are on screen and how far
// they moved.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const TOTAL = 60;
const PAGE_SIZE = 20;

function message(i) {
  const role = i % 2 ? 'user' : 'assistant';
  return {
    id: 'm' + i,
    role,
    // ~6000 characters: well past the 2000-character band `_estimateHeight`
    // caps at 500px, so every prepended row is far taller than its estimate.
    text: 'Message ' + i + '. ' + 'lorem ipsum dolor sit amet consectetur adipiscing '.repeat(120),
    timestamp: 1767225600000,
    isUser: role === 'user',
    isAssistant: role !== 'user',
    isSystem: false,
    displayName: role === 'user' ? 'You' : 'Alice',
    isError: false,
    isHidden: false,
    isGenerating: false,
    isPostGenRunning: false,
  };
}

const range = (from, to) => Array.from({ length: to - from }, (_, k) => message(from + k));

/** Every mounted row, where it sits on screen, and whether any is in view. */
const probe = (page) =>
  page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    const view = c.getBoundingClientRect();
    const rows = [...c.querySelectorAll(':scope > .message-section')];
    const tops = {};
    const ids = [];
    let inView = 0;
    for (const r of rows) {
      const b = r.getBoundingClientRect();
      tops[r.dataset.messageId] = Math.round(b.top - view.top);
      ids.push(r.dataset.messageId);
      if (b.bottom > view.top && b.top < view.bottom) inView++;
    }
    return { scrollTop: c.scrollTop, tops, ids, blank: inView === 0 };
  });

// Chromium holds the reader's place natively while rows mount above them;
// WebKit does not, and there the list offsets `scrollTop` itself. The harness
// runs Chromium, so the WebKit path is reproduced by switching the native
// anchoring off and telling the list so.
const ENGINES = [
  { name: 'native scroll anchoring', native: true },
  { name: 'no native scroll anchoring', native: false },
];

// Load-more fires anywhere in the top 500px, so the page usually lands while
// the reader is still a little way down — where the browser anchors natively
// and has already moved `scrollTop` by the time the prepend reads it back.
const PREPEND_AT = [0, 400];

for (const engine of ENGINES) for (const prependAt of PREPEND_AT) {
  test(`scrolling up through a prepended page never blanks or jumps (${engine.name}, load at ${prependAt}px)`, async ({ page }) => {
    await page.setViewportSize({ width: 395, height: 880 });
    // Capture the JS→Flutter callbacks, for the header the scroll drives.
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
    if (!engine.native) {
      await page.evaluate(() => {
        const vl = window.bridge.virtualList;
        vl.container.style.overflowAnchor = 'none';
        vl._nativeScrollAnchoring = false;
      });
    }

    // The chat opens on its newest page and the reader climbs to its top.
    await page.evaluate((json) => window.bridge.setMessages(json), JSON.stringify(range(TOTAL - PAGE_SIZE, TOTAL)));
    await page.waitForTimeout(600);
    await page.evaluate((top) => {
      window.bridge.virtualList.container.scrollTop = top;
    }, prependAt);
    await page.waitForTimeout(300);
    const before = await probe(page);

    // Flutter answers the load-more with the previous page.
    await page.evaluate(
      (json) => window.bridge.prependMessages(json),
      JSON.stringify(range(TOTAL - 2 * PAGE_SIZE, TOTAL - PAGE_SIZE)),
    );
    await page.waitForTimeout(400);

    await page.mouse.move(190, 440);
    let prev = await probe(page);
    expect(prev.blank, 'the prepend itself left the chat blank').toBe(false);
    // The page arrived above the reader: what they were looking at stays put.
    const held = Object.keys(before.tops).filter((id) => id in prev.tops);
    expect(held.length, 'the rows the reader was on were unmounted by the prepend').toBeGreaterThan(0);
    for (const id of held) {
      expect(
        Math.abs(prev.tops[id] - before.tops[id]),
        `${id} moved when a page was prepended above it`,
      ).toBeLessThan(4);
    }

    const callsBefore = await page.evaluate(() => window.__flutterCalls.length);
    const problems = [];
    let step = null;
    for (let i = 0; i < 40; i++) {
      await page.mouse.wheel(0, -400);
      await page.waitForTimeout(120);
      const cur = await probe(page);
      if (cur.blank) problems.push(`step ${i}: nothing on screen`);
      const dupes = cur.ids.filter((id, k) => cur.ids.indexOf(id) !== k);
      if (dupes.length) problems.push(`step ${i}: mounted twice: ${dupes.join(',')}`);
      const shared = Object.keys(cur.tops).filter((id) => id in prev.tops);
      if (!shared.length) {
        problems.push(`step ${i}: no row survived the frame (scrollTop ${prev.scrollTop} -> ${cur.scrollTop})`);
      } else {
        const moved = cur.tops[shared[0]] - prev.tops[shared[0]];
        // The first real step tells us how far one wheel notch scrolls here.
        if (step === null && moved > 0) step = moved;
        if (step !== null && cur.scrollTop > 0 && Math.abs(moved - step) > 2) {
          problems.push(`step ${i}: ${shared[0]} moved ${moved}px for a ${step}px scroll`);
        }
      }
      prev = cur;
    }
    expect(step, 'the wheel never scrolled the list').not.toBeNull();
    expect(problems).toEqual([]);
    // Every move was upward, so nothing on the way may have hidden the header:
    // rows growing above the reader move scrollTop, not the reader.
    const hides = await page.evaluate(
      (from) => window.__flutterCalls
        .slice(from)
        .filter((c) => c.name === 'onHeaderScroll' && c.args.flat().includes(true)).length,
      callsBefore,
    );
    expect(hides, 'the header hid while the reader only scrolled up').toBe(0);
  });
}
