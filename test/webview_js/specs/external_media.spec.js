// The "Allow external media" setting.
//
// On (the default) a message renders exactly as written. Off, every load from
// a third-party host is dropped before the markup is inserted — the same
// promise as SillyTavern's "Forbid external media" — while embedded media and
// Glaze's own media keep working.
import { test, expect } from '@playwright/test';
import { card } from '../corpus/cards.js';
import { openHarness, render } from './harness.js';

test.beforeEach(async ({ page }) => {
  await openHarness(page);
});

function readCard() {
  const root = window.harness.currentRoot();
  const q = (selector) => root.querySelector(selector);
  const css = Array.from(root.querySelectorAll('style')).map((s) => s.textContent).join('\n');
  return {
    remote: q('.em-remote').getAttribute('src'),
    proto: q('.em-proto').getAttribute('src'),
    data: q('.em-data').getAttribute('src'),
    file: q('.em-file').getAttribute('src'),
    srcset: q('.em-srcset').getAttribute('srcset'),
    poster: q('.em-video').getAttribute('poster'),
    source: q('.em-video source').getAttribute('src'),
    inline: q('.em-inline').getAttribute('style') || '',
    inlineColour: getComputedStyle(q('.em-inline')).color,
    bgColour: getComputedStyle(q('.em-bg')).color,
    link: q('.em-link').getAttribute('href'),
    css,
    imports: Array.from(document.head.querySelectorAll('link[data-glaze-import]'))
      .map((l) => l.getAttribute('href')),
    fonts: Array.from(document.head.querySelectorAll('style[data-glaze-font-face]'))
      .map((s) => s.textContent),
    report: root.querySelector('.glaze-css-error')?.textContent || '',
  };
}

test('on: a message loads its external media as written', async ({ page }) => {
  await render(page, card('external-media-card').text);
  const shape = await page.evaluate(readCard);
  expect(shape.remote).toBe('https://cdn.example/pic.png');
  expect(shape.poster).toBe('https://cdn.example/poster.png');
  expect(shape.css).toContain('https://cdn.example/bg.png');
  expect(shape.imports).toEqual(['https://fonts.example/sheet.css']);
  expect(shape.fonts.some((f) => f.includes('https://fonts.example/r.woff2'))).toBe(true);
});

test('off: every third-party load is dropped, the rest of the card stays', async ({ page }) => {
  await render(page, card('external-media-card').text, { allowExternalMedia: false });
  const shape = await page.evaluate(readCard);

  expect(shape.remote).toBeNull();
  expect(shape.proto).toBeNull();
  expect(shape.poster).toBeNull();
  expect(shape.source).toBeNull();
  expect(shape.srcset, 'only the remote candidate goes').toBe('/local/b.png 2x');
  expect(shape.inline).not.toContain('cdn.example');
  expect(shape.inlineColour, 'the rest of an inline style stays').toBe('rgb(7, 8, 9)');

  expect(shape.css).not.toContain('cdn.example');
  expect(shape.css).not.toContain('fonts.example');
  expect(shape.bgColour, 'the rest of the stylesheet stays').toBe('rgb(4, 5, 6)');
  expect(shape.imports).toEqual([]);
  expect(shape.fonts.some((f) => f.includes('fonts.example'))).toBe(false);
  expect(shape.report, 'a choice the reader made is not a CSS error').toBe('');

  // Embedded and Glaze-served media, and plain links, are not network media.
  expect(shape.data).toMatch(/^data:image\/gif/);
  expect(shape.file).toBe('file:///data/user/0/app/files/pic.png');
  expect(shape.css).toContain('http://127.0.0.1:1/local.png');
  expect(shape.fonts.some((f) => f.includes('data:font/woff2'))).toBe(true);
  expect(shape.link).toBe('https://example.com/page');
});

test('off: a page without a <style> URL keeps its CSS byte-identical', async ({ page }) => {
  const body = '<style>.plain{color:rgb(1,1,1)}  /* kept */</style><div class="plain">x</div>';
  await render(page, body, { allowExternalMedia: false });
  const css = await page.evaluate(
    () => window.harness.currentRoot().querySelector('style').textContent,
  );
  expect(css).toBe('.plain{color:rgb(1,1,1)}  /* kept */');
});

test('off: an escaped url() cannot slip past the filter', async ({ page }) => {
  const body = '<style>.esc{background:\\75 rl(https://cdn.example/e.png);color:rgb(2,2,2)}</style><div class="esc">x</div>';
  await render(page, body, { allowExternalMedia: false });
  const css = await page.evaluate(
    () => window.harness.currentRoot().querySelector('style').textContent,
  );
  expect(css).not.toContain('cdn.example');
  expect(css).toContain('rgb(2, 2, 2)');
});

test('off: ExtBlock HTML drops external images too', async ({ page }) => {
  const html = await page.evaluate(async () => {
    const { sanitizeExtBlockHtml } = await import('/assets/chat_webview/bridge/html_sanitizer.js');
    return sanitizeExtBlockHtml(
      '<img class="a" src="https://cdn.example/x.png"><img class="b" src="data:image/png;base64,AAAA">',
      { allowExternalMedia: false },
    );
  });
  expect(html).not.toContain('cdn.example');
  expect(html).toContain('data:image/png');
});
