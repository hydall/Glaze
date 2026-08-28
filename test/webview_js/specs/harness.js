// Shared spec setup: open the harness page and expose small helpers.
import { expect } from '@playwright/test';

export const HARNESS_URL = '/test/webview_js/harness/harness.html';

/** The sentinel the formatter wraps its internal placeholders in. */
export const SENTINEL = String.fromCharCode(1);

export async function openHarness(page) {
  const failures = [];
  page.on('pageerror', (error) => failures.push(String(error)));
  await page.goto(HARNESS_URL);
  await page.waitForFunction(() => window.__harnessReady === true);
  page.__failures = failures;
  return page;
}

/** Renders a corpus card. Assertions read the DOM the browser built. */
export async function render(page, text, options = {}) {
  await page.evaluate(
    ([body, opts]) => window.harness.render(body, opts),
    [text, options],
  );
}

/** The message root's innerHTML, for the few assertions that need markup. */
export function html(page) {
  return page.evaluate(() => window.harness.html());
}

/** The text a reader sees, whitespace collapsed. */
export function text(page) {
  return page.evaluate(() => window.harness.text());
}

export function consoleErrors(page) {
  return page.evaluate(() => window.harness.consoleErrors.slice());
}

export function flutterCalls(page) {
  return page.evaluate(() => window.harness.flutterCalls.map((c) => c.method));
}

/**
 * Asserts the render left no formatter bookkeeping behind and did not throw:
 * no placeholder sentinel in the visible text, no uncaught page error.
 */
export async function expectCleanRender(page) {
  const visible = await text(page);
  expect(visible.includes(SENTINEL), 'placeholder sentinel leaked').toBe(false);
  expect(page.__failures, 'uncaught page error').toEqual([]);
}
