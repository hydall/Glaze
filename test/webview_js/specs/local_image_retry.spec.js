// A locally served picture that loses one fetch re-requests itself instead of
// keeping the browser's broken-image glyph until something re-renders it.
//
// The generated message image has always had this; the spec below pins the
// contract the avatars, attachments and ext-block cards now share — a bounded
// re-request with a cache-busting query string, and nothing touched for a
// remote picture whose URL cannot be re-resolved.
import { test, expect } from '@playwright/test';
import { openHarness } from './harness.js';

/** A 1×1 GIF, so a successful retry has something real to decode. */
const PIXEL = Buffer.from(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
  'base64',
);

const LOCAL =
  'http://127.0.0.1:59999/__glaze_file__?path=%2Fdata%2Fgenerated%2Fx.jpg';

/**
 * Inserts one picture and wires the retry before the browser starts fetching
 * it, so an instant failure cannot beat the listener.
 */
async function insert(page, src, { datasetSrc = true } = {}) {
  await page.evaluate(
    async ([url, withDataset]) => {
      const { retryFailedLocalImages } = await import(
        '/assets/chat_webview/renderer/local_image_retry.js'
      );
      const container = document.getElementById('chat-container');
      container.innerHTML = '';
      const img = document.createElement('img');
      if (withDataset) img.dataset.src = url;
      container.appendChild(img);
      retryFailedLocalImages(container);
      img.src = url;
    },
    [src, datasetSrc],
  );
}

test.beforeEach(async ({ page }) => {
  await openHarness(page);
});

test('a local image that fails once is re-requested and then loads', async ({ page }) => {
  let hits = 0;
  await page.route('**/__glaze_file__*', async (route) => {
    hits += 1;
    if (hits === 1) {
      await route.fulfill({ status: 404, body: '' });
    } else {
      await route.fulfill({
        status: 200,
        contentType: 'image/gif',
        body: PIXEL,
      });
    }
  });

  await insert(page, LOCAL);

  await page.waitForFunction(() => {
    const img = document.querySelector('#chat-container img');
    return !!(img && img.complete && img.naturalWidth > 0);
  });

  const src = await page.evaluate(
    () => document.querySelector('#chat-container img').src,
  );
  expect(src).toContain('__glaze_retry=');
  expect(hits).toBeGreaterThanOrEqual(2);
});

test('the retry is bounded, not an endless loop', async ({ page }) => {
  let hits = 0;
  await page.route('**/__glaze_file__*', async (route) => {
    hits += 1;
    await route.fulfill({ status: 404, body: '' });
  });

  await insert(page, LOCAL);
  // Initial fetch + the two delayed attempts (350ms, then 700ms later).
  await page.waitForTimeout(2000);

  expect(hits).toBeGreaterThanOrEqual(2);
  expect(hits).toBeLessThanOrEqual(3);
});

test('a remote image is not retried', async ({ page }) => {
  let hits = 0;
  await page.route('**/example.com/**', async (route) => {
    hits += 1;
    await route.fulfill({ status: 404, body: '' });
  });

  await insert(page, 'https://example.com/picture.jpg', { datasetSrc: false });
  await page.waitForTimeout(1200);

  const src = await page.evaluate(
    () => document.querySelector('#chat-container img').src,
  );
  expect(src).not.toContain('__glaze_retry=');
  expect(hits).toBe(1);
});
