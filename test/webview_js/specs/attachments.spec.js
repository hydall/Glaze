// The attachment block a message carries: one picture keeps the free-size
// block it has always had, several become a tile grid.
//
// The harness page renders one message body and deliberately loads no app CSS,
// so this spec brings in the real `styles.css` and the real `image_embed.js`
// and asserts on what the browser resolved — a stack of full-width pictures
// instead of a grid is exactly the regression these tests exist to catch.
import { test, expect } from '@playwright/test';
import { openHarness } from './harness.js';

/** A 1×1 GIF, so nothing depends on a network fetch or a real file. */
const PIXEL =
  'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

const ICON = { eye: '<svg></svg>', hidden: '<svg></svg>' };

/** Renders an attachment block of `count` images and returns what it built. */
async function attach(page, count, { hidden = false } = {}) {
  return page.evaluate(
    async ([n, isHidden, src, icon]) => {
      const { createImageAttachments } = await import(
        '/assets/chat_webview/renderer/image_embed.js'
      );
      const container = document.getElementById('chat-container');
      container.innerHTML = '';
      const wrap = createImageAttachments(
        Array.from({ length: n }, () => src),
        isHidden,
        icon,
      );
      if (!wrap) return null;
      // The grid is width-constrained against the bubble, so give it one.
      const body = document.createElement('div');
      body.style.width = '600px';
      body.appendChild(wrap);
      container.appendChild(body);
      const style = getComputedStyle(wrap);
      const images = Array.from(wrap.querySelectorAll('img'));
      return {
        className: wrap.className,
        images: images.length,
        toggles: wrap.querySelectorAll('.image-ctx-toggle').length,
        display: style.display,
        columns: style.gridTemplateColumns,
        rows: style.gridTemplateRows,
        boxes: images.map((img) => {
          const rect = img.getBoundingClientRect();
          return { width: Math.round(rect.width), height: Math.round(rect.height) };
        }),
      };
    },
    [count, hidden, PIXEL, ICON],
  );
}

test.beforeEach(async ({ page }) => {
  await openHarness(page);
  await page.addStyleTag({ url: '/assets/chat_webview/styles.css' });
});

test('a single attachment keeps the free-size block', async ({ page }) => {
  const built = await attach(page, 1);

  expect(built.images).toBe(1);
  expect(built.className).toContain('count-1');
  expect(built.className, 'one image is not a grid').not.toContain('multi');
  expect(built.display).toBe('inline-block');
});

test('two attachments sit side by side, not one under the other', async ({ page }) => {
  const built = await attach(page, 2);

  expect(built.images).toBe(2);
  expect(built.display).toBe('grid');
  // Two equal columns — the whole point of the grid.
  const columns = built.columns.split(' ');
  expect(columns).toHaveLength(2);
  expect(columns[0]).toBe(columns[1]);
  // Same row: equal heights, and the second tile starts to the right of the
  // first rather than below it.
  expect(built.boxes[0].height).toBe(built.boxes[1].height);
  expect(built.boxes[0].width).toBeGreaterThan(0);
});

test('three attachments lay out as one tall tile plus two stacked', async ({ page }) => {
  const built = await attach(page, 3);

  expect(built.images).toBe(3);
  expect(built.display).toBe('grid');
  expect(built.rows.split(' ')).toHaveLength(2);
  // The first spans both rows, so it is about twice as tall as the others.
  expect(built.boxes[0].height).toBeGreaterThan(built.boxes[1].height);
  expect(built.boxes[1].height).toBe(built.boxes[2].height);
});

test('four attachments form a 2x2 grid of equal tiles', async ({ page }) => {
  const built = await attach(page, 4);

  expect(built.images).toBe(4);
  expect(built.display).toBe('grid');
  expect(built.columns.split(' ')).toHaveLength(2);
  expect(built.rows.split(' ')).toHaveLength(2);
  const [a, b, c, d] = built.boxes;
  expect(b).toEqual(a);
  expect(c).toEqual(a);
  expect(d).toEqual(a);
});

test('more attachments than the grid can lay out are dropped', async ({ page }) => {
  const built = await attach(page, 7);

  expect(built.images).toBe(4);
  expect(built.className).toContain('count-4');
});

test('the whole block carries one eye toggle, whatever the count', async ({ page }) => {
  expect((await attach(page, 1)).toggles).toBe(1);
  expect((await attach(page, 4)).toggles).toBe(1);

  const dimmed = await attach(page, 4, { hidden: true });
  expect(dimmed.className).toContain('image-hidden');
});

test('an empty attachment list builds nothing at all', async ({ page }) => {
  expect(await attach(page, 0)).toBeNull();
});

test('a click on any tile hands that tile to the app', async ({ page }) => {
  await attach(page, 4);
  const clicked = await page.evaluate(() => {
    const images = document.querySelectorAll('.msg-image-attachment img');
    images[2].click();
    const call = window.harness.flutterCalls.at(-1);
    return { method: call && call.method, src: call && call.args[0] };
  });

  expect(clicked.method).toBe('onImageClick');
  expect(clicked.src).toContain('data:image/gif;base64,');
});
