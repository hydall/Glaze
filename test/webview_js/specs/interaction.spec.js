// What a click does, and what the message keeps when scripts are off.
import { test, expect } from '@playwright/test';
import { card } from '../corpus/cards.js';
import { openHarness, render, text, flutterCalls } from './harness.js';

test.beforeEach(async ({ page }) => {
  await openHarness(page);
});

test('a fragment link lights up the :target panel it points at', async ({ page }) => {
  await render(page, card('target-card').text);
  const before = await page.evaluate(() =>
    getComputedStyle(window.harness.currentRoot().querySelector('.panel')).opacity,
  );
  expect(before).toBe('0');

  await page.evaluate(() => window.harness.currentRoot().querySelector('a.open').click());
  const after = await page.evaluate(() =>
    getComputedStyle(window.harness.currentRoot().querySelector('.panel')).opacity,
  );
  expect(after, 'the card must open on its own anchor').toBe('1');
});

test('a link in the message is handed to the app, not followed', async ({ page }) => {
  await render(page, card('md-link').text);
  const anchors = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return Array.from(root.querySelectorAll('a')).map((a) => a.getAttribute('href'));
  });
  expect(anchors).toEqual(['https://example.org/docs', 'https://example.org/two']);

  await page.evaluate(() => window.harness.currentRoot().querySelector('a').click());
  expect(await flutterCalls(page)).toContain('onLinkClick');
  expect(page.url()).toContain('harness.html');
});

test('markup and CSS survive with message scripts off', async ({ page }) => {
  await render(page, card('style-and-inline-style').text, { allowMessageScripts: false });
  const shape = await page.evaluate(() => {
    const plate = window.harness.currentRoot().querySelector('.plate');
    return {
      exists: !!plate,
      color: plate ? getComputedStyle(plate).color : '',
      spacing: plate ? getComputedStyle(plate).letterSpacing : '',
    };
  });
  expect(shape.exists).toBe(true);
  expect(shape.color, 'a <style> block still styles the card').toBe('rgb(10, 200, 30)');
  expect(shape.spacing, 'inline style="" is not a script').toBe('3px');
});

test('a card script is dropped, and the app is told, when scripts are off', async ({ page }) => {
  await render(page, card('script-card').text, { allowMessageScripts: false });
  const shape = await page.evaluate(() => ({
    scripts: window.harness.currentRoot().querySelectorAll('script').length,
    button: !!window.harness.currentRoot().querySelector('#jsc-btn'),
  }));
  expect(shape.scripts).toBe(0);
  expect(shape.button, 'the card still renders, it just cannot run').toBe(true);
  expect(await flutterCalls(page)).toContain('notifyMessageScriptBlocked');
});

test('an image block reports the block a tap belongs to', async ({ page }) => {
  await render(page, card('imggen-result').text);
  await page.evaluate(() =>
    window.harness.currentRoot().querySelector('.imggen-options-btn').click(),
  );
  const calls = await page.evaluate(() => window.harness.flutterCalls.slice());
  expect(calls.length).toBeGreaterThan(0);
  expect(await text(page)).not.toContain('data-img-index');
});
