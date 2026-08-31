// Structure the browser must build for each corpus card.
//
// Every assertion here is about the rendered tree, never about the source of
// the formatter. If a refactor keeps these green, it kept the cards working.
import { test, expect } from '@playwright/test';
import { card, cards } from '../corpus/cards.js';
import { openHarness, render, text, expectCleanRender } from './harness.js';

test.beforeEach(async ({ page }) => {
  await openHarness(page);
});

test('no card leaves formatter bookkeeping or a page error behind', async ({ page }) => {
  for (const entry of cards) {
    await render(page, entry.text);
    await expectCleanRender(page);
  }
});

test('an HTML table keeps its own structure', async ({ page }) => {
  await render(page, card('html-table').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const table = root.querySelector('table');
    return {
      hasTable: !!table,
      paragraphsInside: table ? table.querySelectorAll('p').length : -1,
      rows: table ? table.querySelectorAll('tr').length : -1,
      // A `<p>` the browser threw out of the table lands right before it.
      strayBefore: table && table.previousElementSibling
        ? table.previousElementSibling.tagName
        : '',
      firstCell: table ? table.querySelector('th')?.textContent.trim() : '',
      rowsAreTableChildren: table
        ? Array.from(table.querySelectorAll('tr'))
            .every((tr) => tr.parentElement.tagName === 'TBODY' ||
              tr.parentElement.tagName === 'THEAD')
        : false,
    };
  });
  expect(shape.hasTable).toBe(true);
  expect(shape.paragraphsInside).toBe(0);
  expect(shape.rows).toBe(2);
  expect(shape.strayBefore).not.toBe('P');
  expect(shape.firstCell).toBe('Стат');
  expect(shape.rowsAreTableChildren).toBe(true);
});

test('a CSS-only card keeps the checkbox and its target siblings', async ({ page }) => {
  await render(page, card('css-only-checkbox').text);
  const before = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const input = root.querySelector('#t1');
    const overlay = root.querySelector('.ov');
    return {
      sameParent: input.parentElement === overlay.parentElement,
      display: getComputedStyle(overlay).display,
    };
  });
  expect(before.sameParent, 'input and overlay must stay siblings').toBe(true);
  expect(before.display).toBe('none');

  await page.evaluate(() => window.harness.currentRoot().querySelector('label').click());
  const after = await page.evaluate(() =>
    getComputedStyle(window.harness.currentRoot().querySelector('.ov')).display,
  );
  expect(after, 'the sibling combinator must still match after a click').toBe('block');
});

test('a void element inside a card is not escaped into text', async ({ page }) => {
  await render(page, card('video-source').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      source: root.querySelectorAll('video > source').length,
      src: root.querySelector('source')?.getAttribute('src') || '',
    };
  });
  expect(shape.source).toBe(1);
  expect(shape.src).toBe('clip.mp4');
  expect(await text(page)).not.toContain('<source');
});

test('an inline SVG is left alone', async ({ page }) => {
  await render(page, card('svg-icon').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const svg = root.querySelector('svg');
    return {
      paths: svg ? svg.querySelectorAll('path').length : -1,
      paragraphsInside: svg ? svg.querySelectorAll('p').length : -1,
      insideCard: !!root.querySelector('.ico svg'),
    };
  });
  expect(shape.paths).toBe(1);
  expect(shape.paragraphsInside).toBe(0);
  expect(shape.insideCard).toBe(true);
});

test('<details> keeps its summary and toggles', async ({ page }) => {
  await render(page, card('details-block').text);
  const shape = await page.evaluate(() => {
    const details = window.harness.currentRoot().querySelector('details');
    const before = details.open;
    details.querySelector('summary').click();
    return { hasSummary: !!details.querySelector('summary'), before, after: details.open };
  });
  expect(shape.hasSummary).toBe(true);
  expect(shape.before).toBe(false);
  expect(shape.after).toBe(true);
});

test('a <br> inside a card stays inside that card', async ({ page }) => {
  await render(page, card('br-in-card').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      notes: root.querySelectorAll('.note').length,
      breaks: root.querySelectorAll('.note br').length,
    };
  });
  expect(shape.notes).toBe(1);
  expect(shape.breaks).toBe(1);
});

test('a composite card keeps its structure and its styling', async ({ page }) => {
  await render(page, card('stat-card').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const ledger = root.querySelector('loomledger');
    const head = root.querySelector('.ll-head');
    const fill = root.querySelector('.ll-bar > i');
    return {
      hasLedger: !!ledger,
      tableInsideLedger: !!ledger?.querySelector('table'),
      paragraphsInTable: ledger?.querySelector('table')?.querySelectorAll('p').length ?? -1,
      headColor: head ? getComputedStyle(head).color : '',
      barWidth: fill ? getComputedStyle(fill).width : '',
      emphasis: !!root.querySelector('.ll-note em'),
    };
  });
  expect(shape.hasLedger, 'a custom element the card styles is markup').toBe(true);
  expect(shape.tableInsideLedger).toBe(true);
  expect(shape.paragraphsInTable).toBe(0);
  expect(shape.headColor).toBe('rgb(200, 40, 90)');
  expect(shape.barWidth).not.toBe('');
  expect(shape.emphasis, 'markdown inside a card is still markdown').toBe(true);
});

test('form controls survive as markup', async ({ page }) => {
  await render(page, card('form-controls').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      form: root.querySelectorAll('form.picker').length,
      legend: root.querySelector('legend')?.textContent.trim() || '',
      checked: root.querySelector('input[type=radio]')?.checked ?? null,
    };
  });
  expect(shape.form).toBe(1);
  expect(shape.legend).toBe('Выбор');
  expect(shape.checked).toBe(true);
});

test('prose keeps its angle brackets', async ({ page }) => {
  await render(page, card('prose-angle-brackets').text);
  const visible = await text(page);
  expect(visible).toContain('<вздох>');
  expect(visible).toContain('5 < 7 > 3');
});

test('a tag inside backticks is shown, not rendered', async ({ page }) => {
  await render(page, card('inline-code-tag').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      codeTexts: Array.from(root.querySelectorAll('code')).map((c) => c.textContent),
      // The code-block wrapper is ours; any other <div> would mean the tag
      // inside the backticks was parsed as markup.
      realDivs: root.querySelectorAll('div:not(.code-block-wrapper)').length,
    };
  });
  expect(shape.codeTexts).toContain('<div>');
  expect(shape.realDivs).toBe(0);
});

test('a fenced code block shows its HTML as text', async ({ page }) => {
  await render(page, card('fenced-code').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const code = root.querySelector('pre code');
    return {
      hasPre: !!code,
      body: code ? code.textContent : '',
      realCards: root.querySelectorAll('div.card').length,
    };
  });
  expect(shape.hasPre).toBe(true);
  expect(shape.body).toContain('<div class="card">');
  expect(shape.realCards).toBe(0);
});

test('markdown prose renders emphasis, strike and quotes', async ({ page }) => {
  await render(page, card('markdown-basics').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      paragraphs: root.querySelectorAll('p').length,
      em: root.querySelectorAll('em').length,
      strong: root.querySelectorAll('strong').length,
      del: root.querySelectorAll('del').length,
      quotes: root.querySelectorAll('.chat-quote-text').length,
    };
  });
  expect(shape.paragraphs).toBe(3);
  expect(shape.em).toBeGreaterThanOrEqual(1);
  expect(shape.strong).toBeGreaterThanOrEqual(1);
  expect(shape.del).toBe(1);
  expect(shape.quotes).toBeGreaterThanOrEqual(1);
});

test('markdown structure renders headings, lists and a table', async ({ page }) => {
  await render(page, card('markdown-structure').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      heading: root.querySelector('h2')?.textContent.trim() || '',
      topLevelItems: root.querySelector('ul.chat-list')
        ?.querySelectorAll(':scope > li').length ?? -1,
      nested: root.querySelectorAll('ul.chat-list li ul li').length,
      ordered: root.querySelectorAll('ol.chat-list > li').length,
      orderedStart: root.querySelector('ol.chat-list')?.start ?? -1,
      tableRows: root.querySelectorAll('table.chat-table tbody tr').length,
      headers: root.querySelectorAll('table.chat-table th').length,
    };
  });
  expect(shape.heading).toBe('Отчёт');
  expect(shape.topLevelItems).toBe(2);
  expect(shape.nested).toBe(1);
  expect(shape.ordered).toBe(2);
  expect(shape.orderedStart).toBe(1);
  expect(shape.tableRows).toBe(2);
  expect(shape.headers).toBe(2);
});

test('ordered markdown list preserves a zero start', async ({ page }) => {
  await render(page, card('ordered-list-zero').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const list = root.querySelector('ol.chat-list');
    return {
      start: list?.start ?? -1,
      items: list?.querySelectorAll(':scope > li').length ?? -1,
      text: list?.querySelector('li')?.textContent.trim() || '',
    };
  });
  expect(shape.start).toBe(0);
  expect(shape.items).toBe(1);
  expect(shape.text).toBe('test');
});

test('blockquote and horizontal rule render as elements', async ({ page }) => {
  await render(page, card('blockquote-hr').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      quote: root.querySelector('blockquote')?.textContent.trim() || '',
      rules: root.querySelectorAll('hr').length,
    };
  });
  expect(shape.quote).toBe('цитата');
  expect(shape.rules).toBe(1);
});

test('quotes keep their spans, nested guillemets included', async ({ page }) => {
  await render(page, card('nested-quotes').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      marks: root.querySelectorAll('.chat-quote').length,
      texts: root.querySelectorAll('.chat-quote-text').length,
    };
  });
  expect(shape.marks).toBeGreaterThanOrEqual(2);
  expect(shape.texts).toBeGreaterThanOrEqual(2);
});

test('Glaze colour markers render as styled spans', async ({ page }) => {
  await render(page, card('glaze-markers').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const hc = root.querySelector('.glaze-hc');
    return {
      hcColor: hc ? getComputedStyle(hc).color : '',
      hcText: hc ? hc.textContent : '',
      accent: !!root.querySelector('.glaze-accent'),
    };
  });
  expect(shape.hcColor).toBe('rgb(255, 0, 102)');
  expect(shape.hcText).toBe('Красным');
  expect(shape.accent).toBe(true);
});

test('an inline <think> block becomes a reasoning panel', async ({ page }) => {
  await render(page, card('think-block').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      panel: !!root.querySelector('details.reasoning-block'),
      body: root.querySelector('.reasoning-content')?.textContent.trim() || '',
      rest: root.textContent.includes('Хорошо, идём.'),
    };
  });
  expect(shape.panel).toBe(true);
  expect(shape.body).toContain('Надо ответить коротко.');
  expect(shape.rest).toBe(true);
});

test('a markdown image keeps its options button inside the wrapper', async ({ page }) => {
  await render(page, card('md-image').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const wrapper = root.querySelector('.janitor-img-wrapper');
    return {
      hasWrapper: !!wrapper,
      img: !!wrapper?.querySelector('img.janitor-img'),
      button: !!wrapper?.querySelector('button.janitor-options-btn'),
    };
  });
  expect(shape).toEqual({ hasWrapper: true, img: true, button: true });
});

test('a pending image block renders its placeholder', async ({ page }) => {
  await render(page, card('imggen-pending').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const block = root.querySelector('.imggen-loading');
    return {
      hasBlock: !!block,
      index: block?.dataset.imgIndex,
      // isolateImgGenPlaceholders moves the contents behind a shadow root.
      isolated: !!block?.shadowRoot,
    };
  });
  expect(shape.hasBlock).toBe(true);
  expect(shape.index).toBe('0');
  expect(shape.isolated).toBe(true);
});

test('a finished image block renders its variant switcher', async ({ page }) => {
  await render(page, card('imggen-result').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const wrapper = root.querySelector('.imggen-result-wrapper');
    return {
      variants: wrapper?.dataset.variants || '',
      count: root.querySelector('.imggen-variant-count')?.textContent || '',
      brokenImg: root.querySelectorAll('img.imggen-result').length,
    };
  });
  expect(shape.variants).toContain(';;');
  expect(shape.count).toBe('1/2');
  expect(shape.brokenImg).toBe(1);
});

test('inline tags in prose keep their paragraphs and their markdown', async ({ page }) => {
  await render(page, card('inline-tags-in-prose').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const quote = root.querySelector('.chat-quote-text');
    const marker = root.querySelector('.glaze-hc');
    return {
      paragraphs: root.querySelectorAll('p').length,
      bold: root.querySelectorAll('b').length,
      // A quote that opens before a tag and closes after it is one quote.
      quoteHoldsTag: !!quote && !!quote.querySelector('b'),
      // Same for a colour marker: html_to_markdown writes rich content in one.
      markerHoldsTag: !!marker && !!marker.querySelector('i'),
    };
  });
  expect(shape.paragraphs).toBe(2);
  expect(shape.bold).toBe(2);
  expect(shape.quoteHoldsTag).toBe(true);
  expect(shape.markerHoldsTag).toBe(true);
});

test('emphasis around a regex-built card leaves the card alone', async ({ page }) => {
  await render(page, card('regex-card-in-emphasis').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const wrap = root.querySelector('.imsg-wrap');
    const details = root.querySelector('.imsg-details');
    const footer = root.querySelector('.imsg-footer');
    const bubble = root.querySelector('.imsg-bubble');
    return {
      // The card's stylesheet is what the marker used to take with it.
      styles: root.querySelectorAll('style').length,
      summaries: details ? details.querySelectorAll('summary').length : -1,
      // Everything after the point the closing `*` landed used to end up
      // outside <details>, and the footer outside the wrapper entirely.
      footerInsideDetails: !!footer && !!footer.closest('.imsg-details'),
      bodyInsideDetails: !!root.querySelector('.imsg-details .imsg-body'),
      wrapHoldsCard: !!wrap && wrap.contains(details) && wrap.contains(footer),
      // A marker never reparents markup: no <em> may hold a block element.
      emAroundCard: root.querySelectorAll('em .imsg-wrap, em .imsg-details').length,
      // The CSS still resolves, which is the whole reason it has to survive.
      bubbleRadius: bubble ? getComputedStyle(bubble).borderRadius : '',
      arrowWidth: getComputedStyle(root.querySelector('.imsg-send svg')).width,
    };
  });
  expect(shape.styles).toBe(1);
  expect(shape.summaries).toBe(1);
  expect(shape.footerInsideDetails).toBe(true);
  expect(shape.bodyInsideDetails).toBe(true);
  expect(shape.wrapHoldsCard).toBe(true);
  expect(shape.emAroundCard).toBe(0);
  expect(shape.bubbleRadius).toBe('16px');
  expect(shape.arrowWidth).toBe('11px');
});

test('a marker that spans balanced inline markup still holds it', async ({ page }) => {
  await render(page, card('emphasis-over-inline-tag').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const em = root.querySelector('em.chat-italic');
    const marker = root.querySelector('.glaze-hc');
    return {
      emHoldsTag: !!em && !!em.querySelector('b'),
      emText: em ? em.textContent : '',
      markerHoldsTag: !!marker && !!marker.querySelector('i'),
      breaks: root.querySelectorAll('br').length,
      strayAsterisks: (root.textContent.match(/\*/g) || []).length,
    };
  });
  expect(shape.emHoldsTag, 'balanced markup inside a marker is still a marker').toBe(true);
  expect(shape.emText).toBe('шёпот громче и снова тише');
  expect(shape.markerHoldsTag).toBe(true);
  expect(shape.breaks).toBe(1);
  expect(shape.strayAsterisks).toBe(0);
});

test('a gradient <font> carries its fill down to the text', async ({ page }) => {
  await render(page, card('font-gradient').text);
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    const outer = root.querySelector('.font-style-block');
    const inner = outer?.firstElementChild;
    return {
      outer: !!outer,
      // Without this the outer span clips a gradient over no text at all.
      innerFill: inner ? getComputedStyle(inner).webkitTextFillColor : '',
      innerSpacing: inner ? getComputedStyle(inner).letterSpacing : '',
    };
  });
  expect(shape.outer).toBe(true);
  expect(shape.innerFill).toBe('rgba(0, 0, 0, 0)');
  expect(shape.innerSpacing, 'the author\'s own style survives').toBe('1px');
});

test('an image tag inside a reasoning panel stays text', async ({ page }) => {
  // INV-IG11: Dart never generates from a tag written while thinking, so the
  // renderer must not show a placeholder whose picture is never coming.
  await render(page, 'Думаю: [IMG:GEN:лес]', { isReasoning: true });
  const shape = await page.evaluate(() => {
    const root = window.harness.currentRoot();
    return {
      placeholders: root.querySelectorAll('.imggen-loading').length,
      text: root.textContent,
    };
  });
  expect(shape.placeholders).toBe(0);
  expect(shape.text).toContain('[IMG:GEN:лес]');
});
