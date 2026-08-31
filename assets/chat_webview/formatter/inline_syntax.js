// Inline markdown: what happens *inside* a line of a message.
//
// Everything here works on a string that is already known to be text — either
// a text node the parser produced, or the inside of a style marker. Elements
// around it are opaque placeholders, so no pass in this file can reach into a
// tag, an attribute or a script. That is the whole point of the split: the
// old formatter ran these same regexes over a string with live HTML in it,
// and the markdown kept eating the markup.

import { renderStyledSegment } from './text_format.js';
import { SENTINEL, createStore, extractMarkers } from './protect.js';

/**
 * Text becomes markup only through this file, so what could open a tag is
 * escaped first. `>` is deliberately left alone: it needs no escaping in text
 * content, and escaping it would hide the `>` a blockquote line starts with
 * from the block pass.
 */
export function escapeText(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;');
}

/** Any placeholder, as one alternative inside a larger pattern. */
const PLACEHOLDER_GROUP = `${SENTINEL}[A-Z_]+\\d+${SENTINEL}`;

// Quotes, with the unclosed case handled so a reply reads correctly while it
// is still streaming. The first two alternatives are guards: a placeholder is
// opaque, and `="…"` is an attribute value, not dialogue.
const QUOTE_REGEX = new RegExp(
  `(${PLACEHOLDER_GROUP})|(=[ \\t]*"(?:[^"]|\\\\")*?")|(")((?:[^"]|\\\\")*?)(")` +
  `|(«)([^»\\u0001]*?(?:«[^»\\u0001]*?»[^»\\u0001]*?)*?)(»)|(")((?:[^"]*)$)`,
  'gm',
);

function applyQuotes(text) {
  return text.replace(QUOTE_REGEX, (
    match, placeholder, attribute,
    openQ, closedContent, closeQ,
    openG, guillemetContent, closeG,
    openU, unclosedContent,
  ) => {
    if (placeholder) return placeholder;
    if (attribute) return attribute;
    if (openQ !== undefined) {
      return `<span class="chat-quote">${openQ}</span>` +
        `<span class="chat-quote-text">${closedContent}</span>` +
        `<span class="chat-quote">${closeQ}</span>`;
    }
    if (openG !== undefined) {
      // Nested «outer «inner» more outer» — split at the inner «» so the inner
      // quote renders with the narration colour while the outer text keeps the
      // quote colour. Inner «» are literal characters, not a second quote.
      const rendered = guillemetContent.split(/(«[^»]*?»)/).map((part) => {
        if (!part) return '';
        if (/^«[^»]*?»$/.test(part)) return part;
        return `<span class="chat-quote-text">${part}</span>`;
      }).join('');
      return `<span class="chat-quote">${openG}</span>${rendered}` +
        `<span class="chat-quote">${closeG}</span>`;
    }
    if (openU !== undefined) {
      return `<span class="chat-quote">${openU}</span>` +
        `<span class="chat-quote-text">${unclosedContent}</span>`;
    }
    return match;
  });
}

function applyLinks(text) {
  return text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_match, label, url) => {
    const href = url.trim().replace(/"/g, '&quot;');
    return `<a href="${href}" target="_blank" rel="noopener">${label}</a>`;
  });
}

/**
 * Emphasis the marker scan could not take: a run that spans a line break, or
 * one whose opening marker only became unambiguous after the quotes pass.
 */
function applyLooseEmphasis(text) {
  return text
    .replace(/~~([^~\n]+?)~~/g, '<del>$1</del>')
    .replace(/\*\*\*([^*\n]+?)\*\*\*/g, '<strong><em class="chat-italic">$1</em></strong>')
    .replace(/\*\*([^*\n]+?)\*\*/g, '<strong>$1</strong>')
    // Never let an unmatched marker consume text from a later line.
    .replace(/\*([^*\n]+?)\*/g, '<em class="chat-italic">$1</em>');
}

/**
 * Formats one run of message text.
 *
 * [markers] holds the style markers pulled out before parsing; [inner] renders
 * the content of one marker (it recurses back into this file). [skipQuotes]
 * is set inside a colour marker, whose fill the quote colour would override.
 */
export function applyInlineSyntax(text, { markers, inner, skipQuotes = false }) {
  let out = skipQuotes ? text : applyQuotes(text);
  out = out.replace(new RegExp(`${SENTINEL}S_(\\d+)${SENTINEL}`, 'g'), (_m, i) => {
    const segment = markers ? markers.get(i) : '';
    return segment === undefined ? '' : renderStyledSegment(segment, inner);
  });
  out = applyLooseEmphasis(out);
  return applyLinks(out);
}

/**
 * Formats the inside of one style marker, which may carry its own nested
 * markers and the `E_n` placeholders of elements it wrapped.
 *
 * The string is already what `formatRun` built — escaped text and masked
 * elements — so nothing here escapes or masks again: doing either would show
 * the author's own `<b>` as `&lt;b&gt;` on screen. Its only job is the passes
 * a marker's content still needs.
 *
 * Always inline — a marker is a `<span>`, and a `<p>` inside one is what the
 * browser throws straight back out, leaving the marker empty on screen.
 */
export function formatInlineMasked(text, { skipQuotes = false } = {}) {
  if (!text) return '';
  const markers = createStore('S');
  const held = extractMarkers(String(text), markers);
  return applyInlineSyntax(held, {
    markers,
    skipQuotes,
    inner: (nested, nestedSkipQuotes = true) =>
      formatInlineMasked(nested, { skipQuotes: nestedSkipQuotes }),
  });
}
