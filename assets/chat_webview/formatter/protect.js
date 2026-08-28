// Everything that has to leave the message text before it is parsed.
//
// Two kinds of region live here:
//
//   * regions that are *not* markup even though they look like it — a fenced
//     code block, a span of inline code, the tag a reasoning block only talks
//     about. Handing those to the parser would turn prose about a `<div>` into
//     a `<div>`;
//   * regions the renderer replaces with UI of its own — an image block, a
//     `<think>` panel, a markdown image card. Those become one placeholder so
//     nothing downstream can split them apart.
//
// Each region is swapped for a placeholder built out of a control character,
// which survives HTML parsing as ordinary text and cannot appear in a message.

import { extractImageBlocks } from './image_blocks.js';
import { maskTags } from './html_scan.js';

/** Wraps every placeholder. U+0001 is not writable in a chat message. */
export const SENTINEL = '\u0001';

/** A protected region, restored into the tree after formatting. */
export const REGION_PATTERN = new RegExp(`${SENTINEL}P_(\\d+)${SENTINEL}`, 'g');

/** A Glaze / markdown style marker, restored while formatting text. */
export const MARKER_PATTERN = new RegExp(`${SENTINEL}S_(\\d+)${SENTINEL}`, 'g');

/** Any placeholder at all — the sweep that proves none leaked. */
export const ANY_PLACEHOLDER = new RegExp(`${SENTINEL}[A-Z_]+\\d+${SENTINEL}`, 'g');

export function createStore(prefix) {
  const entries = [];
  return {
    entries,
    hold(entry) {
      entries.push(entry);
      return `${SENTINEL}${prefix}_${entries.length - 1}${SENTINEL}`;
    },
    get(index) {
      return entries[Number(index)];
    },
  };
}

function escapeAttribute(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Normalizes the destination of a markdown image/link.
//
// The raw capture is everything between the parens, which for CommonMark can
// carry padding, an <…> wrapper and a title: `![a]( <u> "cap" )`. A browser
// trims and re-encodes most of that when it loads the <img>, so the picture
// still appears in the message — but the same raw string handed to Flutter
// (via data-src) is not a valid URL there, and the full-screen viewer opens
// onto nothing. Normalize once, so both sides see the same URL.
export function normalizeMdUrl(url) {
  let out = String(url == null ? '' : url).trim();
  // Trailing title: `url "caption"` / `url 'caption'` / `url (caption)`.
  const titled = out.match(/^(\S+)\s+(?:"[^"]*"|'[^']*'|\([^)]*\))$/);
  if (titled) out = titled[1];
  if (out.startsWith('<') && out.endsWith('>')) out = out.slice(1, -1).trim();
  return out;
}

const OPTIONS_SVG = '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>';

/** The card a markdown image renders to: the picture and its options button. */
function markdownImageCard(alt, url) {
  // `![alt](url =100x50)` — the dimension suffix is markdown, not part of the
  // address; leaving it in `src` requests a URL that cannot resolve.
  const sized = url.match(/^(.*?)\s+=(\d+)?x(\d+)?$/);
  const size = sized
    ? `${sized[2] ? ` width="${sized[2]}"` : ''}${sized[3] ? ` height="${sized[3]}"` : ''}`
    : '';
  const safeUrl = escapeAttribute(normalizeMdUrl(sized ? sized[1] : url));
  return `<span class="janitor-img-wrapper"><img${size} src="${safeUrl}" alt="${escapeAttribute(alt)}" class="janitor-img" loading="lazy" data-action="image-click" data-src="${safeUrl}"><button class="janitor-options-btn" type="button" data-action="img-options" data-src="${safeUrl}" title="Options">${OPTIONS_SVG}</button></span>`;
}

/**
 * A block region is padded with blank lines so it lands in a block of its own:
 * an image block or a code block is never part of the paragraph around it.
 */
function block(placeholder) {
  return `\n\n${placeholder}\n\n`;
}

/**
 * Pulls the protected regions out of [text] and returns what is left to parse.
 *
 * [store] collects the regions; the caller puts them back into the tree once
 * the markdown passes are done.
 */
export function protectRegions(text, { store, inReasoning = false }) {
  let out = text;

  // `<think>` is the model's own panel, not part of the reply's flow. Both
  // spellings, and both the closed and the still-streaming form.
  const think = (content) => block(store.hold({ kind: 'think', content: content.trim() }));
  out = out
    .replace(/<think\b[^>]*>([\s\S]*?)<\/think\b[^>]*>/gi, (_m, content) => think(content))
    .replace(/<think\b[^>]*?(?:>|\n)([\s\S]*?)<\/think\b/gi, (_m, content) => think(content))
    .replace(/<thinking\b[^>]*>([\s\S]*?)<\/thinking\b[^>]*>/gi, (_m, content) => think(content))
    .replace(/<thinking\b[^>]*?(?:>|\n)([\s\S]*?)<\/thinking\b/gi, (_m, content) => think(content));

  // Fenced code first: everything else in this file must not read inside one.
  out = out.replace(/```(\w*)\n?([\s\S]*?)(?:```|$)/g, (_match, lang, code) =>
    block(store.hold({ kind: 'code', lang, code })));

  // Inline code, before the tag scan can read what is inside it as HTML.
  // `Пиши `<div>`` is prose about a tag, not a tag.
  out = out.replace(/`([^`\n]+)`/g, (_match, code) =>
    store.hold({ kind: 'inline-code', code }));

  // A model writes `&lt;br&gt;` when it escapes its own output; the reader
  // meant a line break.
  out = out.replace(/&lt;br\s*\/?&gt;/gi, '<br>');

  out = extractImageBlocks(out, {
    inReasoning,
    hold: (imageBlock) => block(store.hold({ kind: 'image', block: imageBlock })),
    // Tags a reasoning block only talks about stay the text the model wrote:
    // nothing here loads, spins or generates (INV-IG11).
    inert: (raw) => store.hold({ kind: 'text', text: raw }),
  });

  out = out.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_match, alt, url) =>
    store.hold({ kind: 'html', html: markdownImageCard(alt, url) }));

  return out;
}

/**
 * Hides `<style>` and `<script>` bodies for the duration of the marker scan.
 *
 * Their contents are code, not prose: a `*` in a CSS selector is not an italic
 * marker and `**` in a script is not bold. They go back into the text before
 * it is parsed, so both still reach the message as real elements.
 */
export function maskCodeElements(text) {
  const bodies = [];
  const masked = text.replace(
    /<(style|script)\b[^>]*>[\s\S]*?(?:<\/\1\s*>|$)/gi,
    (match) => {
      bodies.push(match);
      return `${SENTINEL}RAW_${bodies.length - 1}${SENTINEL}`;
    },
  );
  const pattern = new RegExp(`${SENTINEL}RAW_(\\d+)${SENTINEL}`, 'g');
  return {
    masked,
    unmask: (value) => String(value).replace(pattern, (_m, i) => bodies[Number(i)]),
  };
}

/** Glaze colour markers and the markdown emphasis run that follows them. */
const MARKER_REGEX = /(==hc:#[0-9a-fA-F]{3,8}==.+?==|==glow:#[0-9a-fA-F]{3,8},\d+==.+?==|==cg:#[0-9a-fA-F]{3,8},#[0-9a-fA-F]{3,8},\d+==.+?==|==grad:#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+==.+?==|==bg:#[0-9a-fA-F]{3,8}==.+?==|==mark==.+?==|==active==.+?==|==accent==.+?==|\*\*[^*\n]+?\*\*|(?<!\*)\*(?=[^*\n]*[^ \t*\n])[^*\n]+?\*(?!\*)|__[^_\n]+?__|(?<!\w)_[^_\n]+?_(?!\w)|~~[^~\n]+?~~)/gs;

/**
 * Pulls the style markers out of [text] before it is parsed.
 *
 * They have to come out here, not from the parsed tree: html_to_markdown puts
 * rich content inside a colour marker (`==hc:#fff==<b>x</b>==`), and once that
 * is parsed the marker's two halves live in two different text nodes with an
 * element between them. Tags are masked for the scan so a `*` inside an
 * attribute cannot open an emphasis run, while a marker that spans a tag still
 * matches.
 */
export function extractMarkers(text, markers) {
  const { masked, unmask } = maskTags(text, SENTINEL);
  const held = masked.replace(MARKER_REGEX, (segment) =>
    markers.hold(unmask(segment)));
  // Models occasionally emit `».* *action*`: the first `*` is an orphan
  // marker, not an empty italic segment. Drop it once the real action is
  // safely stashed, otherwise it steals that action's opening marker.
  return unmask(held.replace(
    new RegExp(`\\*([ \\t]+)(?=${SENTINEL}S_\\d+${SENTINEL})`, 'g'),
    '$1',
  ));
}
