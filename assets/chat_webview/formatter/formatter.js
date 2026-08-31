// The message renderer, in two phases.
//
//   Phase A — parse. The message is handed to the browser's own HTML parser.
//     What is an element, how elements nest, and where an unclosed tag ends
//     are the parser's answers, not ours. That is what makes a card render as
//     a card from its first streamed chunk instead of flickering as raw tags,
//     and it is why there is no list of block tags and no "orphan" counter
//     here any more.
//
//   Phase B — format the text. Markdown is applied to text nodes, never to a
//     string with live markup in it. Attributes, `<style>`, `<script>`, `<pre>`
//     and `<code>` are out of reach by construction, and a `<p>` of ours is
//     only ever added at the top level of the message — never inside markup
//     the author wrote.
//
// Around those two: `protect.js` takes out the regions that are not markup
// (code, image tags, a `<think>` panel) before parsing, and puts them back
// afterwards. See docs/rules/message-rendering.md.

import { expandMacros } from './macros.js';
import { escapeProseTags, styledElementNames } from './html_scan.js';
import {
  ANY_PLACEHOLDER,
  createStore,
  extractMarkers,
  maskCodeElements,
  protectRegions,
} from './protect.js';
import {
  convertFontElements,
  formatContainer,
  parseHtml,
  replacePlaceholders,
} from './dom_format.js';
import { formatInlineRaw } from './inline_syntax.js';
import { renderImageBlock } from './image_blocks.js';

export {
  parseImageResultPayload,
  parseImageResultElement,
  parseImagePendingPayload,
  parseImagePendingElement,
} from './image_blocks.js';

function escapeHtml(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

export class Formatter {
  constructor() {
    this.cache = new Map();
    this.cacheMaxSize = 500;
  }

  // [inReasoning] formats a body that *is* a reasoning block — the split-out
  // `message.reasoning`, which the renderer shows in its own panel. Dart never
  // scans that field for image tags, so a tag in it must not render as a block
  // here either (INV-IG11); the same flag covers a `<think>` block found inline
  // in the message body.
  format(text, isUser = false, inReasoning = false) {
    const key = `${text}:${isUser}:${inReasoning}`;
    if (this.cache.has(key)) return this.cache.get(key);

    let result;
    try {
      result = this._render(text, isUser, inReasoning);
    } catch (e) {
      console.error('Formatter error:', e);
      result = escapeHtml(text || '').replace(/\n/g, '<br>');
    }

    const leaked = result.match(ANY_PLACEHOLDER);
    if (leaked) {
      console.error('Formatter LEAK:', leaked, 'text:', text?.substring(0, 100));
      result = result.replace(ANY_PLACEHOLDER, '');
    }

    if (this.cache.size >= this.cacheMaxSize) {
      const firstKey = this.cache.keys().next().value;
      this.cache.delete(firstKey);
    }
    this.cache.set(key, result);
    return result;
  }

  _render(text, isUser, inReasoning) {
    if (!text) return '';
    const source = expandMacros(text)
      .replace(/\r\n/g, '\n')
      .replace(/\r/g, '\n')
      .trim();

    const regions = createStore('P');
    const markers = createStore('S');

    let staged = protectRegions(source, { store: regions, inReasoning });
    // `<style>` and `<script>` bodies are code, and both string passes below
    // would read them as prose: a `*` in a selector is not an italic marker,
    // and `i<n; i++) { if (i>` in a script is not a tag. They are masked for
    // the length of both, and put back for the parser.
    const styled = styledElementNames(staged);
    const code = maskCodeElements(staged);
    // Style markers come out before the parse, because html_to_markdown writes
    // rich content inside them and a parsed marker is two text nodes with an
    // element between them. `styled` goes along so the balance check there
    // reads the message's tags exactly as `escapeProseTags` will below — the
    // `<style>` bodies that declare them are masked out of `code.masked`.
    staged = extractMarkers(code.masked, markers, styled);

    const tree = parseHtml(code.unmask(escapeProseTags(staged, styled)), document);

    formatContainer(tree, {
      isRoot: true,
      allowBlocks: true,
      inlineContext: {
        markers,
        inner: (raw, skipQuotes = true) => formatInlineRaw(raw, { skipQuotes }),
      },
    });

    let imageIndex = 0;
    replacePlaceholders(tree, 'P', (index) => {
      const region = regions.get(index);
      if (!region) return null;
      if (region.kind === 'image') {
        // Document order: the blocks are numbered the way
        // ImageTagMarkup.scanImageBlocks() numbers them on the Dart side, so
        // `data-img-index` addresses one image and not the whole message.
        return Array.from(
          parseHtml(renderImageBlock(region.block, imageIndex++), document).childNodes,
        );
      }
      return Array.from(parseHtml(this._regionHtml(region, isUser), document).childNodes);
    });

    convertFontElements(tree);
    return this._serialize(tree);
  }

  _regionHtml(region, isUser) {
    switch (region.kind) {
      case 'code': {
        const langAttr = region.lang ? ` class="language-${region.lang}"` : '';
        const langLabel = region.lang ? `<span class="code-lang">${region.lang}</span>` : '';
        return `<div class="code-block-wrapper">${langLabel}` +
          `<pre><code${langAttr}>${escapeHtml(region.code)}</code></pre></div>`;
      }
      case 'inline-code':
        // Escaped: a tag written inside backticks is shown, not rendered.
        return `<code>${escapeHtml(region.code)}</code>`;
      case 'think':
        return '<details class="reasoning-block">' +
          '<summary class="reasoning-summary">💭 Reasoning</summary>' +
          `<div class="reasoning-content">${this._render(region.content, isUser, true)}</div>` +
          '</details>';
      case 'html':
        return region.html;
      case 'text':
        return escapeHtml(region.text);
      default:
        return '';
    }
  }

  _serialize(tree) {
    const template = document.createElement('template');
    template.content.appendChild(tree);
    return template.innerHTML;
  }
}
