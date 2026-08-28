// The document contract: what a card may rely on inside a message shadow root.
//
// One case per item of docs/INVARIANTS.md § Message document contract. A hole
// closed here is a hole closed by list, not by complaint.
import { test, expect } from '@playwright/test';
import { card } from '../corpus/cards.js';
import { openHarness, render } from './harness.js';

test.beforeEach(async ({ page }) => {
  await openHarness(page);
});

test('INV-MR1 a card script declares the function its onclick calls', async ({ page }) => {
  await render(page, card('script-card').text);
  const before = await page.evaluate(() =>
    window.harness.currentRoot().querySelector('#jsc-out').hidden);
  expect(before).toBe(true);

  await page.evaluate(() => window.harness.currentRoot().querySelector('#jsc-btn').click());
  const after = await page.evaluate(() =>
    window.harness.currentRoot().querySelector('#jsc-out').hidden);
  expect(after, 'the script runs in the global scope, so onclick resolves').toBe(false);
  expect(page.__failures).toEqual([]);
});

test('INV-MR1 a message script leaves no <script> behind', async ({ page }) => {
  await render(page, card('script-card').text);
  const shape = await page.evaluate(() => ({
    inMessage: window.harness.currentRoot().querySelectorAll('script').length,
    // The element the runner injects to reach global scope is removed again.
    inHead: document.head.querySelectorAll('script:not([src])').length,
  }));
  expect(shape.inMessage).toBe(0);
  expect(shape.inHead).toBe(0);
});

test('INV-MR3/MR4 document lookups find the message\'s own elements', async ({ page }) => {
  await render(page, card('doc-query-card').text);
  const out = await page.evaluate(() =>
    window.harness.currentRoot().querySelector('#dq-out').textContent);
  expect(out, 'querySelector/getElementsBy*/forms all resolve in the message')
    .toBe('qs/1/1/1/1');
});

test('INV-MR3 a lookup the message cannot answer still reaches the document', async ({ page }) => {
  await render(page, '<div id="mr3">x</div><script>window.__mr3 = ' +
    "document.getElementById('chat-container') ? 'document' : 'missing';</script>");
  const seen = await page.evaluate(() => window.__mr3);
  expect(seen).toBe('document');
});

test('INV-MR6 a modal handed to document.body stays under the message CSS', async ({ page }) => {
  await render(page, card('doc-body-card').text);
  await page.evaluate(() => window.harness.currentRoot().querySelector('#db-open').click());
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const modal = root.querySelector('#db-modal');
    return {
      inMessage: !!modal,
      inAppBody: !!document.body.querySelector(':scope > #db-modal'),
      colour: modal ? getComputedStyle(modal).color : '',
      overlay: !!root.querySelector('.glaze-message-overlay'),
    };
  });
  expect(shape.inMessage, 'the modal is in the message, not in the app chrome').toBe(true);
  expect(shape.inAppBody).toBe(false);
  expect(shape.colour, "the card's own rule applies to it").toBe('rgb(9, 90, 200)');
  expect(shape.overlay).toBe(true);
});

test('INV-MR7 the load events a card waits for still arrive', async ({ page }) => {
  await render(page, card('doc-ready-card').text);
  const out = await page.evaluate(() =>
    window.harness.currentRoot().querySelector('#dr-out').textContent);
  expect(out).toBe('готово+load');
});

test('INV-MR5 a dropped @import is reported, not silent', async ({ page }) => {
  await render(page, card('import-font-card').text);
  const report = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      shown: root.querySelector('.glaze-css-error')?.textContent || '',
      styleKept: !!root.querySelector('style'),
      titleStyled: getComputedStyle(root.querySelector('.if-title')).fontFamily,
    };
  });
  expect(report.shown).toContain('@import');
  expect(report.styleKept, 'the rest of the card CSS still applies').toBe(true);
  expect(report.titleStyled).toContain('cursive');
});

test('INV-MR2 the app keeps its own document while a message runs', async ({ page }) => {
  await render(page, card('doc-body-card').text);
  const restored = await page.evaluate(() => {
    // Every shim is an own property, removed once the message's code is done.
    const own = ['getElementById', 'querySelector', 'body', 'head', 'forms']
      .filter((name) => Object.prototype.hasOwnProperty.call(document, name));
    return { own, bodyIsBody: document.body === document.querySelector('body') };
  });
  expect(restored.own).toEqual([]);
  expect(restored.bodyIsBody).toBe(true);
});

test('INV-MR8 message scripts stay off when the toggle is off', async ({ page }) => {
  await render(page, card('doc-body-card').text, { allowMessageScripts: false });
  await page.evaluate(() => window.harness.currentRoot().querySelector('#db-open').click());
  const shape = await page.evaluate(() => ({
    modal: !!window.harness.currentRoot().querySelector('#db-modal'),
    scripts: window.harness.currentRoot().querySelectorAll('script').length,
  }));
  expect(shape.modal).toBe(false);
  expect(shape.scripts).toBe(0);
});

test('a card script survives its own comparisons', async ({ page }) => {
  // `i<n; i++) { if (i>` looks exactly like a tag to a scan that works on the
  // message as a string, and escaping it leaves the script unparseable. The
  // scan never sees a <script> body: it is masked for the length of it.
  await render(page, card('script-comparison').text);
  const shape = await page.evaluate((body) => ({
    out: window.harness.currentRoot().querySelector('#sc-out').textContent,
    formatted: window.harness.format(body),
  }), card('script-comparison').text);
  expect(shape.out, 'the script ran').toBe('ok2');
  expect(shape.formatted).toContain('i<n');
  expect(shape.formatted).not.toContain('&lt;n');
});
