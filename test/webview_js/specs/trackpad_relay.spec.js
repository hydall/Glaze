// Touchpad pans on Windows reach the page through the relay — see
// assets/chat_webview/bridge/scroll_relay.js. The embedder hands them over once
// a frame with the pad's sample jitter in them, and nothing after the fingers
// leave, so the page evens the stream out and carries a flick on the way a
// Flutter list does. These drive the real bridge in the real page.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const CURSOR = { x: 300, y: 300 };

async function openChat(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    const msgs = [];
    for (let i = 0; i < 60; i++) {
      msgs.push({
        id: 'm' + i,
        role: i % 2 ? 'user' : 'assistant',
        text: 'message number ' + i + ' ' + 'lorem ipsum '.repeat(40),
        timestamp: 1767225600000,
        isUser: i % 2 === 1,
        isAssistant: i % 2 === 0,
        isSystem: false,
        isError: false,
        isHidden: false,
        isGenerating: false,
        isPostGenRunning: false,
      });
    }
    window.bridge.setMessages(JSON.stringify(msgs));
    window.bridge.setBottomPadding(130, 0);
  });
  await page.waitForTimeout(500);
  // Text laid out in a fallback face reflows when the real one arrives, and
  // every row changes height with it.
  await page.evaluate(() => document.fonts.ready);
  // Start at the very end, as an opened chat does.
  await page.evaluate(() => {
    const c = document.getElementById('chat-container');
    c.scrollTop = c.scrollHeight;
  });
  // And let the list come to rest, in height as well as position: a row
  // measured late grows the list and the anchor correction moves the
  // position with it, and a start read before that is not the start the
  // scrolls below add to.
  const layout = () =>
    page.evaluate(() => {
      const c = document.getElementById('chat-container');
      return c.scrollTop + ':' + c.scrollHeight;
    });
  await expect.poll(async () => {
    const a = await layout();
    await page.waitForTimeout(300);
    return a === (await layout());
  }, { timeout: 8000 }).toBe(true);
}

// Where the chat stands, counted from its end: scrollTop − scrollHeight, zero
// at the end and more negative the further up the chat is, by exactly as much
// as it scrolled. Not scrollTop itself: the virtual list renders a row the
// first time it comes into view, and one that measures taller than its
// estimate grows the list above the viewport while the browser keeps what is
// on screen where it is — scrollTop and scrollHeight both jump by the
// difference, and a scrollTop read before and after the scroll is off by that
// much although the chat moved exactly as far as it should (see
// wheel_relay.spec.js). The distance from the end moves only when the chat
// does. In-page samplers below take the same reading inline.
const where = (page) =>
  page.evaluate(() => {
    const c = document.getElementById('chat-container');
    return c.scrollTop - c.scrollHeight;
  });

// Waits until the chat has come to rest — the relay owes nothing more, no
// flick is in flight, and the position held still for 150 ms — and returns
// where it stands. The end of the motion is waited for, not timed: a busy
// runner holds frames back, and a reading taken after a fixed wait is taken
// mid-way.
async function rested(page) {
  let at;
  await expect.poll(async () => {
    const before = await where(page);
    await page.waitForTimeout(150);
    const idle = await page.evaluate(() => {
      const r = window.bridge._scrollRelay;
      return r.pendingWheel.dx === 0 && r.pendingWheel.dy === 0 &&
        r.pendingPan.dx === 0 && r.pendingPan.dy === 0 &&
        r.flingVelocity.vx === 0 && r.flingVelocity.vy === 0;
    });
    at = await where(page);
    return idle && at === before;
  }, { timeout: 5000 }).toBe(true);
  return at;
}

// Within two pixels of where the scroll should have taken the chat: the
// virtual list may nudge the position by one as a row re-measures.
const expectAt = (at, target) =>
  expect(Math.abs(at - target), `came to rest at ${at}, expected ${target}`)
    .toBeLessThan(2);

/**
 * Feeds one pan per frame, the way Flutter's relay does, then keeps watching
 * until the chat has stood still for ten frames. Resolves with how far the
 * chat moved in each frame (`moves`, zeros at the end trimmed) and how long
 * each of those frames was, in milliseconds (`gaps`, the first one unknown
 * and reported as a normal frame).
 */
const drag = (page, deltas) =>
  page.evaluate(
    ([list, at]) => new Promise((resolve) => {
      const c = document.getElementById('chat-container');
      const where = () => c.scrollTop - c.scrollHeight;
      const moves = [];
      const gaps = [];
      let last = where();
      let lastAt = 0;
      let fed = 0;
      let still = 0;
      const frame = (t) => {
        const now = where();
        const move = now - last;
        last = now;
        moves.push(move);
        gaps.push(lastAt ? t - lastAt : 16);
        lastAt = t;
        still = move === 0 ? still + 1 : 0;
        if (fed < list.length) {
          window.bridge.trackpadScroll(0, list[fed++], at.x, at.y);
        } else if (still >= 10 || moves.length > 300) {
          while (moves.length && moves[moves.length - 1] === 0) moves.pop();
          gaps.length = moves.length;
          resolve({ moves, gaps });
          return;
        }
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
    }),
    [deltas, CURSOR],
  );

test('a jittery pan stream comes out even, and nothing of it is lost', async ({ page }) => {
  await openChat(page);

  // What the embedder hands over under a steady finger: two pixels one
  // frame, twelve the next.
  const deltas = [];
  for (let i = 0; i < 15; i++) deltas.push(-2, -12);
  // The filter lets out a share of what is owed that grows with the length
  // of the frame, so a frame that comes late — the suite's other workers
  // were busy — passes most of its pan straight through and the output
  // jitters with the input. That measures the runner, not the filter: a run
  // with a late frame in the window judged below is dragged again, from
  // wherever the chat now stands, a few times before giving up.
  let start;
  let moves;
  let late;
  for (let attempt = 0; attempt < 5; attempt++) {
    start = await where(page);
    const run = await drag(page, deltas);
    moves = run.moves;
    late = run.gaps.slice(8, 28).filter((gap) => gap > 25).length;
    if (late === 0) break;
  }

  // The whole distance arrives, late frames or not.
  const total = deltas.reduce((a, b) => a + b, 0);
  expect(Math.abs((await where(page)) - (start + total))).toBeLessThan(0.6);

  // Once the filter has settled, the frames move by much the same amount:
  // the spread of the output, relative to its mean, is well under the
  // input's (0.71) — a third of it on a quiet machine. The filter is a frame
  // long on purpose; a longer one evened this out further but trailed the
  // finger. A runner too busy to give one clean run cannot judge this, and
  // says so rather than failing on its own frame times.
  test.skip(late > 0, `${late} late frame(s) in the window on every attempt`);
  const spread = (list) => {
    const mean = list.reduce((a, b) => a + b, 0) / list.length;
    const variance = list.reduce((a, b) => a + (b - mean) ** 2, 0) / list.length;
    return Math.sqrt(variance) / Math.abs(mean);
  };
  const steady = moves.slice(8, 28);
  expect(spread(steady)).toBeLessThan(spread(deltas) * 0.6);
});

test('the chat stops with the fingers, not a few frames after them', async ({ page }) => {
  await openChat(page);
  const start = await where(page);

  // A steady drag that pauses: the frames after the last pan.
  const deltas = [];
  for (let i = 0; i < 20; i++) deltas.push(-6);
  const { moves } = await drag(page, deltas);

  // `drag` records a frame's move before feeding that frame's pan, so the
  // last pan is applied from index 21 on; what is still owed then goes out
  // within a couple of frames.
  const tail = moves.slice(21);
  expect(tail.length).toBeLessThanOrEqual(3);
  const total = deltas.reduce((a, b) => a + b, 0);
  expect(Math.abs((await where(page)) - (start + total))).toBeLessThan(2);
});

test('a flick keeps the chat gliding after the fingers leave, then dies away', async ({ page }) => {
  await openChat(page);
  const start = await where(page);

  await drag(page, [-40, -40, -40]);
  const lifted = await where(page);
  await page.evaluate(([at]) => window.bridge.trackpadScrollEnd(0, -2000, at.x, at.y), [CURSOR]);

  // Still moving a few frames later, and well past where the fingers left.
  await page.waitForTimeout(150);
  const gliding = await where(page);
  expect(gliding).toBeLessThan(lifted - 100);
  await page.waitForTimeout(150);
  expect(await where(page)).toBeLessThan(gliding);

  // Comes to rest: 2 px/ms dying with a 350 ms constant travels about 700 px
  // — less when the suite's other workers hold frames back, since a frame
  // more than 100 ms late is not made up for.
  const travelled = lifted - (await rested(page));
  expect(travelled).toBeGreaterThan(350);
  expect(travelled).toBeLessThan(900);
  expect(start - lifted).toBeGreaterThan(0);
});

test('touching the pad stops the glide where it is', async ({ page }) => {
  await openChat(page);
  await page.evaluate(([at]) => {
    window.bridge.trackpadScroll(0, -20, at.x, at.y);
    window.bridge.trackpadScrollEnd(0, -3000);
  }, [CURSOR]);
  await page.waitForTimeout(120);

  // Read in the same breath as the touch: the glide was still going a moment
  // before, and nothing of it is left after. Waiting for the chat to rest
  // alone would prove nothing — a glide that ignored the touch comes to rest
  // too, only some hundreds of pixels further on.
  const touch = await page.evaluate(() => {
    const r = window.bridge._scrollRelay;
    const c = document.getElementById('chat-container');
    const gliding = r.flingVelocity.vy !== 0;
    window.bridge.trackpadScrollStart();
    return {
      gliding,
      velocity: r.flingVelocity.vy,
      at: c.scrollTop - c.scrollHeight,
    };
  });
  expect(touch.gliding).toBe(true);
  expect(touch.velocity).toBe(0);

  // At most the last pan, if a busy runner still owed some of it, moves the
  // chat after the touch.
  const stopped = await rested(page);
  expect(Math.abs(stopped - touch.at)).toBeLessThanOrEqual(20);
  await page.waitForTimeout(250);
  expect(await where(page)).toBe(stopped);
});

test('a glide past the end of the chat is dropped, not saved for the way back', async ({ page }) => {
  await openChat(page);
  const end = await where(page);

  // Already at the end: a flick downwards has nowhere to go.
  await page.evaluate(([at]) => {
    window.bridge.trackpadScroll(0, 30, at.x, at.y);
    window.bridge.trackpadScrollEnd(0, 3000);
  }, [CURSOR]);
  expect(await rested(page)).toBe(end);

  await page.evaluate(([at]) => window.bridge.wheelScroll(0, -100, at.x, at.y), [CURSOR]);
  expectAt(await rested(page), end - 100);
});

test('reduced motion follows the finger at once and does not glide', async ({ page }) => {
  await openChat(page);
  // Emulated once the page is up, and checked: set before the load it can
  // reach the document late on a busy runner.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect.poll(() =>
    page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches),
  ).toBe(true);
  const start = await where(page);

  const after = await page.evaluate(([at]) => {
    window.bridge.trackpadScroll(0, -50, at.x, at.y);
    const c = document.getElementById('chat-container');
    return c.scrollTop - c.scrollHeight;
  }, [CURSOR]);
  expect(after).toBe(start - 50);

  await page.evaluate(() => window.bridge.trackpadScrollEnd(0, -3000));
  await page.waitForTimeout(300);
  expect(await where(page)).toBe(start - 50);
});
