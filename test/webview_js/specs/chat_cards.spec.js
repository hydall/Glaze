// The scroll buttons, the cards under the header and the session-switch
// spinner, drawn by the chat page (chrome/scroll.js, chrome/cards.js,
// chrome/busy.js). They used to be Flutter widgets laid over the WebView,
// above everything the page draws; these check that the page draws them,
// takes their taps, and keeps the presentation state that is its own.
//
// The chrome lives in a closed shadow root, so nothing here can query it: the
// specs read where things are from the layout report it sends Flutter, and
// press them with real (trusted) mouse clicks.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const VIEW = { width: 400, height: 760 };

const STATE = {
  theme: { accent: [196, 42, 74, 1], fillHeader: [30, 30, 30, 0.8], fillSurface: [25, 25, 26, 0.8],
    surface: [20, 18, 24, 1], blurSigma: 0 },
  layout: { safeTop: 24, safeBottom: 16, inset: 16, viewportH: VIEW.height, gutter: 0, fades: false,
    drawer: { show: false, height: 300, progress: 0 } },
  header: { show: true, title: 'Seraphina', session: 'Session #3', avatar: { initial: 'S' },
    search: { kind: 'mobile', open: false, hint: 'Search' } },
  composer: { show: true, mode: 'compose', placeholder: 'Message...', pins: [],
    send: { icon: { cp: 62754 }, tap: true, slot: false } },
};

const row = (i, extra) => ({
  k: `book/e${i}`, rail: [74, 222, 128, 1], bg: [74, 222, 128, 0.06], title: `Entry ${i}`,
  trail: '~12 tok', sub: [{ t: 'Book', c: [202, 196, 208, 0.85] }],
  details: [{ t: `Entry ${i} reached the prompt`, c: [74, 222, 128, 1], b: true }, { t: 'Keyword match' }],
  badges: [[{ t: 'sword', c: [74, 222, 128, 1] }]], ...extra,
});

const COVERAGE = {
  hidden: false, expanded: false, title: 'In the prompt',
  pills: [{ icon: { cp: 61890 }, value: '3', total: '9', color: [202, 196, 208, 1] }],
};

const EXPANDED = {
  ...COVERAGE, expanded: true, tabs: [], tab: 0, label: 'Lorebooks',
  actions: [{ id: 'refresh', icon: { cp: 58644 }, tip: 'Refresh', size: 18 }],
  body: { kind: 'lorebook', stats: [{ value: '3', label: 'active', color: [74, 222, 128, 1] }],
    filters: ['Activated', 'Cut off', 'Not triggered', 'All'], filter: 0, empty: 'Nothing here',
    rows: [row(1), row(2), row(3)] },
};

async function open(page) {
  await page.setViewportSize(VIEW);
  await page.addInitScript(() => {
    window.__calls = [];
    window.flutter_inappwebview = {
      callHandler: (...args) => { window.__calls.push(args); return Promise.resolve(null); },
    };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.__glazeChrome);
  const keys = await page.evaluate(() => window.__glazeChrome.handshake());
  const [keyIn, keyOut] = keys.split(':');
  const apply = (msg) => page.evaluate(([k, m]) => window.__glazeChrome.apply(k, JSON.stringify(m)), [keyIn, msg]);
  await apply(STATE);
  await page.waitForTimeout(100);
  const intents = () => page.evaluate((k) => window.__calls
    .filter((c) => c[0] === 'onChromeIntent' && c[1] === k)
    .map((c) => JSON.parse(c[2])), keyOut);
  const sent = async (type) => (await intents()).filter((i) => i.t === type);
  const layout = async () => {
    const all = (await intents()).filter((i) => i.t === 'layout');
    return all.length ? all[all.length - 1].d : {};
  };
  return { apply, sent, layout };
}

const center = (r) => ({ x: r[0] + r[2] / 2, y: r[1] + r[3] / 2 });

test('the scroll buttons sit above the composer and send their taps', async ({ page }) => {
  const { apply, sent, layout } = await open(page);
  await apply({ scroll: { down: true, up: true } });
  await page.waitForTimeout(250);

  const { composerHeight } = await layout();
  expect(composerHeight).toBeGreaterThan(0);
  // 16px in from the right edge, 16px above the composer (which rides the
  // 16px inset), and the up button one button and a gap above it.
  const x = VIEW.width - 16 - 22;
  const downY = VIEW.height - 16 - composerHeight - 16 - 22;
  await page.mouse.click(x, downY);
  await page.mouse.click(x, downY - 52);
  expect((await sent('scrollDown')).length).toBe(1);
  expect((await sent('scrollUp')).length).toBe(1);

  // Hidden, they take no taps.
  await apply({ scroll: { down: false, up: false } });
  await page.waitForTimeout(250);
  await page.mouse.click(x, downY);
  expect((await sent('scrollDown')).length).toBe(1);
});

test('the busy spinner takes the taps until the switch lands', async ({ page }) => {
  const { apply, sent, layout } = await open(page);
  await apply({ scroll: { down: true, up: false }, busy: true });
  await page.waitForTimeout(250);
  const { composerHeight } = await layout();
  const x = VIEW.width - 16 - 22;
  const y = VIEW.height - 16 - composerHeight - 16 - 22;
  await page.mouse.click(x, y);
  expect((await sent('scrollDown')).length).toBe(0);

  await apply({ busy: false });
  await page.waitForTimeout(50);
  await page.mouse.click(x, y);
  expect((await sent('scrollDown')).length).toBe(1);
});

test('the coverage card reports its collapsed height and toggles on tap', async ({ page }) => {
  const { apply, sent, layout } = await open(page);
  await apply({ coverage: COVERAGE });
  await page.waitForTimeout(150);

  const collapsed = await layout();
  expect(collapsed.coverageHeight).toBeGreaterThan(30);
  // Under the header: status bar, the header's 10px inset and 56px, an 8px gap.
  expect(collapsed.coverage[1]).toBe(24 + 10 + 56 + 8);
  expect(collapsed.coverage[3]).toBe(collapsed.coverageHeight);

  await page.mouse.click(...Object.values(center(collapsed.coverage)));
  expect((await sent('coverageToggle')).length).toBe(1);

  // Opened, the card grows but the height the message list keeps clear of
  // stays the collapsed one, so opening it never moves the list.
  await apply({ coverage: EXPANDED });
  await page.waitForTimeout(150);
  const expanded = await layout();
  expect(expanded.coverage[3]).toBeGreaterThan(collapsed.coverage[3] + 40);
  expect(expanded.coverageHeight).toBe(collapsed.coverageHeight);
});

test('a coverage row opens in the page, and stays open across updates', async ({ page }) => {
  const { apply, sent, layout } = await open(page);
  await apply({ coverage: EXPANDED });
  await page.waitForTimeout(150);
  const before = (await layout()).coverage;

  // The last row sits at the bottom of the card, above its 12px padding.
  await page.mouse.click(before[0] + 60, before[1] + before[3] - 12 - 14);
  await page.waitForTimeout(150);
  const opened = (await layout()).coverage;
  expect(opened[3]).toBeGreaterThan(before[3] + 20);
  // Opening a row is the page's own business: nothing went to Flutter.
  expect((await sent('coverageToggle')).length).toBe(0);

  // Flutter sends the card again (a new turn's numbers): the row stays open.
  await apply({ coverage: { ...EXPANDED, pills: [{ ...EXPANDED.pills[0], value: '4' }] } });
  await page.waitForTimeout(150);
  expect((await layout()).coverage[3]).toBe(opened[3]);
});

test('the card hides with the header', async ({ page }) => {
  const { apply, layout } = await open(page);
  await apply({ coverage: COVERAGE });
  await page.waitForTimeout(150);
  await apply({ coverage: { ...COVERAGE, hidden: true }, header: { hidden: true } });
  await page.waitForTimeout(500);
  const r = (await layout()).coverage;
  expect(r[1] + r[3]).toBeLessThanOrEqual(0);
});

test('a status card draws under the coverage card and sends its action', async ({ page }) => {
  const { apply, sent, layout } = await open(page);
  await apply({
    coverage: COVERAGE,
    statusPostGen: { label: 'Ledger running...', icon: { cp: 57706 }, accent: [196, 42, 74, 1], spinner: true,
      action: { id: 'statusPostGen', icon: { cp: 57706 }, tip: 'Hide status', size: 16 } },
  });
  await page.waitForTimeout(150);
  const report = await layout();
  const [card] = report.status;
  expect(card.slot).toBe('statusPostGen');
  // Stacked under the coverage card, 8px apart.
  expect(card.r[1]).toBe(report.coverage[1] + report.coverage[3] + 8);

  await page.mouse.click(...Object.values(center(card.action)));
  expect(await sent('statusAction')).toEqual([{ t: 'statusAction', d: { id: 'statusPostGen' } }]);

  await apply({ statusPostGen: null });
  await page.waitForTimeout(100);
  expect((await layout()).status).toBeUndefined();
});
