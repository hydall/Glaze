import { expandMacros } from './macros.js';
import { renderStyledSegment } from './text_format.js';

// Vertical 3-dot "options" icon (ported from Glaze useMessageImageGen.js).
const OPTIONS_SVG = '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>';
const VARIANT_PREV_SVG = '<svg viewBox="0 0 24 24"><path d="M15.4 7.4 14 6l-6 6 6 6 1.4-1.4-4.6-4.6z"/></svg>';
const VARIANT_NEXT_SVG = '<svg viewBox="0 0 24 24"><path d="M8.6 7.4 10 6l6 6-6 6-1.4-1.4 4.6-4.6z"/></svg>';
// Stop icon for the loading placeholder. An SVG rather than the ⏹ character:
// the glyph is a font-dependent emoji that renders at a different size (and in
// colour) on every platform, while a path is the same square everywhere and
// takes `fill: currentColor` from the button.
const STOP_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2"/></svg>';

/** Separator between the images one block carries, mirroring the Dart codec. */
const IMG_VARIANT_SEPARATOR = ';;';

/** Marks the image on screen inside a multi-image payload. */
const IMG_VARIANT_ACTIVE_MARKER = '*';

/**
 * Splits an `[IMG:RESULT:…]` payload into its images, the one on screen and
 * the instruction — the JS half of ImageBlockPayload in image_tag_markup.dart.
 * A single-image block keeps the historical `path|instruction` spelling, so
 * messages written before block variants existed parse unchanged.
 */
export function parseImageResultPayload(payload) {
  const raw = String(payload == null ? '' : payload);
  const pipeIdx = raw.indexOf('|');
  const head = pipeIdx === -1 ? raw : raw.substring(0, pipeIdx);
  const instruction = pipeIdx === -1 ? '' : raw.substring(pipeIdx + 1);
  const paths = [];
  let activeIndex = 0;
  for (const entry of head.split(IMG_VARIANT_SEPARATOR)) {
    if (!entry) continue;
    if (entry.startsWith(IMG_VARIANT_ACTIVE_MARKER)) {
      activeIndex = paths.length;
      paths.push(entry.substring(IMG_VARIANT_ACTIVE_MARKER.length));
    } else {
      paths.push(entry);
    }
  }
  return { paths, activeIndex, instruction };
}

/** Introduces the images a pending block carries, mirroring the Dart codec. */
const IMG_PENDING_MARKER = '@';

/**
 * Splits an `[IMG:GEN:…]` payload into the images the block already holds and
 * its instruction — the JS half of ImageBlockPayload.parsePending. Without the
 * `@` marker the whole payload is the instruction, which is how every block
 * written before regeneration carried its images is spelled.
 */
export function parseImagePendingPayload(payload) {
  const raw = String(payload == null ? '' : payload);
  if (!raw.startsWith(IMG_PENDING_MARKER)) {
    return { paths: [], activeIndex: 0, instruction: raw };
  }
  return parseImageResultPayload(raw.substring(IMG_PENDING_MARKER.length));
}

/**
 * Matches one `<img …data-iig-instruction…>` element, the stored form of an
 * image block. Whether it is finished or still waiting is decided by its
 * `src` (see `parseImageResultElement`), not by the pattern.
 */
const IIG_ELEMENT_REGEX = /<img\s[^>]*?data-iig-instruction\s*=\s*(?:"[^"]*"|'[^']*')[^>]*>/gi;

/**
 * Matches an `<img …src="[IMG:GEN…]">` element that carries no instruction
 * attribute — the spelling a model writes by hand, where the payload lives in
 * the `src`. Mirrors ImgGenPatterns.imgSrcGenRegex on the Dart side.
 */
const IMG_SRC_GEN_ELEMENT_REGEX = /<img\b[^>]*?\bsrc\s*=\s*["']\[IMG:GEN[^\]]*\]["'][^>]*>/gi;

/** A paragraph holding only tag placeholders and whitespace (see step 11). */
const ONLY_TAG_PLACEHOLDERS = /^(?:\x01T_(?:BLOCK_)?\d+\x01|\s)+$/;

const ATTRIBUTE_PAIR_REGEX = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]*))/g;

/** Attributes of one `<img …>` element, lower-cased names to raw values. */
function imgAttributes(tag) {
  const body = String(tag == null ? '' : tag).replace(/^<\s*[A-Za-z][-A-Za-z0-9]*/i, '');
  // Null-prototype: an attribute called `constructor` or `toString` must not
  // read as already present, and must not reach an inherited value.
  const attributes = Object.create(null);
  ATTRIBUTE_PAIR_REGEX.lastIndex = 0;
  let match;
  while ((match = ATTRIBUTE_PAIR_REGEX.exec(body)) !== null) {
    const name = match[1].toLowerCase();
    if (name in attributes) continue;
    const value = match[2] !== undefined ? match[2]
      : match[3] !== undefined ? match[3]
      : match[4] !== undefined ? match[4] : '';
    attributes[name] = value;
  }
  return attributes;
}

function unescapeAttribute(value) {
  const raw = String(value == null ? '' : value);
  if (raw.indexOf('&') === -1) return raw;
  return raw
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&');
}

/**
 * Reads the stored `<img data-iig-…>` form of a finished image block — the JS
 * half of ImageTagMarkup.encodeResultElement in image_tag_markup.dart. The
 * visible image is the element's `src`, the block's other images ride along in
 * `data-iig-variants`. Returns null while the block is still waiting for its
 * picture (no `src`, or the `[IMG:GEN…]` placeholder in it), which the caller
 * reads as "not a result".
 */
export function parseImageResultElement(tag) {
  const attributes = imgAttributes(tag);
  const src = unescapeAttribute(attributes.src || '').trim();
  if (!src || src.startsWith('[IMG:GEN')) return null;
  const instruction = unescapeAttribute(attributes['data-iig-instruction'] || '');
  const variants = unescapeAttribute(attributes['data-iig-variants'] || '');
  const paths = [];
  for (const entry of variants.split(IMG_VARIANT_SEPARATOR)) {
    if (entry) paths.push(entry);
  }
  if (!paths.length) paths.push(src);
  const declared = parseInt(attributes['data-iig-index'], 10);
  const fallback = paths.indexOf(src);
  let activeIndex = Number.isNaN(declared) ? fallback : declared;
  if (!(activeIndex >= 0)) activeIndex = 0;
  if (activeIndex > paths.length - 1) activeIndex = paths.length - 1;
  return { paths, activeIndex, instruction };
}

/**
 * Reads the pending form of a stored image block: the same `<img data-iig-…>`
 * element, but with no picture in its `src` yet (see `parseImageResultElement`,
 * which is what decides between the two). Returns null for a finished block.
 *
 * Pulling this element out of the markup — instead of leaving it to render as
 * an ordinary `<img>` — is what keeps a browser's broken-image icon off the
 * screen while the picture is still being generated: the tag has no image to
 * load, so the only thing it can paint is the failure glyph.
 */
export function parseImagePendingElement(tag) {
  const attributes = imgAttributes(tag);
  const src = unescapeAttribute(attributes.src || '').trim();
  if (src && !src.startsWith('[IMG:GEN')) return null;
  // The instruction attribute is the authoritative payload; a bare
  // `<img src="[IMG:GEN:…]">` carries it inside the src instead.
  let instruction = unescapeAttribute(attributes['data-iig-instruction'] || '');
  if (!instruction && src) {
    const inSrc = src.match(/^\[IMG:GEN(?::([\s\S]*))?\]$/);
    if (inSrc) instruction = inSrc[1] || '';
  }
  return { instruction };
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
  // in the message body, from step 17.
  format(text, isUser = false, inReasoning = false) {
    const key = `${text}:${isUser}:${inReasoning}`;
    if (this.cache.has(key)) return this.cache.get(key);

    let result;
    try {
      result = this._processText(text, isUser, false, inReasoning);
    } catch (e) {
      console.error('Formatter error:', e);
      result = (text || '').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\n/g, '<br>');
    }

    const leaked = result.match(/\x01[A-Z_]+\d+\x01/g);
    if (leaked) {
      console.error('Formatter LEAK:', leaked, 'text:', text?.substring(0, 100));
      result = result.replace(/\x01[A-Z_]+\d+\x01/g, '');
    }

    if (this.cache.size >= this.cacheMaxSize) {
      const firstKey = this.cache.keys().next().value;
      this.cache.delete(firstKey);
    }
    this.cache.set(key, result);
    return result;
  }

  _ph(prefix, i, isBlock) {
    return `\x01${prefix}${isBlock ? 'BLOCK_' : ''}${i}\x01`;
  }

  // [inReasoning] marks the recursive pass over a `<think>…</think>` body. A
  // model plans its images out loud there, and Glaze does not generate from a
  // tag it finds in that plan (INV-IG11) — so the tag must not render as a
  // block either: a placeholder whose picture is never coming, or an <img>
  // with no loadable source, would both be a lie about what the app is doing.
  _processText(text, isUser, skipQuotes = false, inReasoning = false) {
    if (!text) return '';
    text = expandMacros(text).replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();

    let html = text;

    // 1a. Extract <think...</think...> reasoning blocks
    const thinkBlocks = [];
    html = html.replace(/<think\b[^>]*>([\s\S]*?)<\/think\b[^>]*>/gi, (match, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    html = html.replace(/<think\b([^>]*?)(?:>|\n)([\s\S]*?)<\/think\b/gi, (match, attrs, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    html = html.replace(/<thinking\b[^>]*>([\s\S]*?)<\/thinking\b[^>]*>/gi, (match, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    html = html.replace(/<thinking\b([^>]*?)(?:>|\n)([\s\S]*?)<\/thinking\b/gi, (match, attrs, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    // 1b. Extract <style>...</style> blocks
    const styleBlocks = [];
    html = html.replace(/<style\b[^>]*>([\s\S]*?)<\/style>/gi, (match, content) => {
      const id = this._ph('STY_', styleBlocks.length, true);
      styleBlocks.push(match);
      return '\n\n' + id + '\n\n';
    });

    // 1c. Extract <script>...</script> blocks
    const scriptBlocks = [];
    html = html.replace(/<script\b[^>]*>([\s\S]*?)<\/script>/gi, (match, content) => {
      const id = this._ph('SCR_', scriptBlocks.length, true);
      scriptBlocks.push(match);
      return '\n\n' + id + '\n\n';
    });

    // 2. Extract Code Blocks
    const codeBlocks = [];
    html = html.replace(/```(\w*)\n?([\s\S]*?)(?:```|$)/g, (match, lang, code) => {
      const id = this._ph('CB_', codeBlocks.length);
      codeBlocks.push({ lang, code });
      return id;
    });

    // 2b. Extract inline code spans, before the tag pass can read what is
    //     inside them as HTML. `Пиши `<div>`` is prose about a tag, not a tag.
    const inlineCode = [];
    html = html.replace(/`([^`\n]+)`/g, (match, code) => {
      const id = this._ph('IC_', inlineCode.length);
      inlineCode.push(code);
      return id;
    });

    // 3. Extract CSS comments inside code blocks are already protected
    //    Extract standalone CSS comments (outside code blocks)
    const cssComments = [];
    html = html.replace(/\/\*([\s\S]*?)\*\//g, (match) => {
      const id = this._ph('CC_', cssComments.length);
      cssComments.push(match);
      return id;
    });

    // 4. Fix escaped HTML line breaks
    html = html.replace(/&lt;br\s*\/?&gt;/gi, '<br>');

    // 5. Extract <font color="..."> blocks before quote processing
    const fontBlocks = [];
    html = html.replace(/<font\s+color=["']?(#[0-9a-fA-F]{3,8})["']?\s*>([\s\S]*?)<\/font>/gi, (match, color, content) => {
      const id = this._ph('FC_', fontBlocks.length);
      fontBlocks.push({ type: 'color', color, content });
      return id;
    });
    // font style with double-quoted attribute value
    html = html.replace(/<font\s+style\s*=\s*"([^"]*)"['"]*\s*>([\s\S]*?)<\/font>/gi, (match, style, content) => {
      const id = this._ph('FC_', fontBlocks.length);
      fontBlocks.push({ type: 'style', style, content });
      return id;
    });
    // font style with single-quoted attribute value
    html = html.replace(/<font\s+style\s*=\s*'([^']*)'\s*>([\s\S]*?)<\/font>/gi, (match, style, content) => {
      const id = this._ph('FC_', fontBlocks.length);
      fontBlocks.push({ type: 'style', style, content });
      return id;
    });

    // 5b. Janitor images: ![alt](url) → <span class="janitor-img-wrapper"> with options button
    //
    // The card is stashed as ONE atomic placeholder and restored at the very
    // end (step 12c). Emitting its raw HTML here instead would hand it to the
    // tag extraction in step 6, which classifies <img>/<svg>/<path> as *block*
    // tags — step 11 then isolates every block placeholder in its own
    // paragraph, so `<span class="janitor-img-wrapper">`, the `<img>` and the
    // options `<button>` end up in three different <p> elements. The button
    // would lose its positioned wrapper and its `position: absolute` would
    // resolve against the message container, pinning the 3-dot menu to the top
    // of the whole message instead of the top of the image.
    const mdImages = [];
    html = html.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (match, alt, url) => {
      // `![alt](url =100x50)` — the dimension suffix is markdown, not part of
      // the address; leaving it in `src` requests a URL that cannot resolve.
      const sized = url.match(/^(.*?)\s+=(\d+)?x(\d+)?$/);
      const size = sized
        ? `${sized[2] ? ` width="${sized[2]}"` : ''}` +
          `${sized[3] ? ` height="${sized[3]}"` : ''}`
        : '';
      const safeUrl = this._escapeHtml(
        this._normalizeMdUrl(sized ? sized[1] : url),
      );
      const id = this._ph('MI_', mdImages.length);
      mdImages.push(`<span class="janitor-img-wrapper"><img${size} src="${safeUrl}" alt="${this._escapeHtml(alt)}" class="janitor-img" loading="lazy" data-action="image-click" data-src="${safeUrl}"><button class="janitor-options-btn" type="button" data-action="img-options" data-src="${safeUrl}" title="Options">${OPTIONS_SVG}</button></span>`);
      return id;
    });

    // 5c. Glaze image gen tags
    //
    // The stored `<img data-iig-…>` element comes first: it is the form every
    // finished block is written in, and pulling it out here (rather than
    // letting step 6 treat it as an ordinary HTML tag) is what gives it the
    // options button, the variant switcher and its `data-img-index`.
    const imgBlocks = [];
    // Tags a reasoning block only talks about: kept as their own literal text,
    // restored in step 19b. Inline (not a block placeholder) so a tag written
    // mid-sentence does not break the sentence in two.
    const inertImgTags = [];
    const inertTag = (match) => {
      const id = this._ph('IGT_', inertImgTags.length);
      inertImgTags.push(match);
      return id;
    };
    html = html.replace(IIG_ELEMENT_REGEX, (match) => {
      const parsed = parseImageResultElement(match);
      if (!parsed) {
        // Still waiting for its picture: render the loading placeholder in the
        // element's place. Leaving the tag alone would put an <img> with no
        // loadable source into the message, and the reader would watch a
        // broken-image icon for the whole generation.
        const pending = parseImagePendingElement(match);
        if (!pending) return match;
        if (inReasoning) return inertTag(match);
        const id = this._ph('IG_', imgBlocks.length, true);
        imgBlocks.push({ type: 'gen', instruction: pending.instruction });
        return '\n\n' + id + '\n\n';
      }
      const id = this._ph('IG_', imgBlocks.length, true);
      imgBlocks.push({
        type: 'result',
        path: parsed.paths[parsed.activeIndex] || parsed.paths[0] || '',
        paths: parsed.paths,
        activeIndex: parsed.activeIndex,
        instruction: parsed.instruction,
      });
      return '\n\n' + id + '\n\n';
    });
    // `<img src="[IMG:GEN…]">` with no instruction attribute: the whole element
    // is the block, so it has to go before the bare-tag pass below — otherwise
    // only the src payload is consumed and the empty <img> stays behind as a
    // broken-image icon.
    html = html.replace(IMG_SRC_GEN_ELEMENT_REGEX, (match) => {
      const pending = parseImagePendingElement(match);
      if (!pending) return match;
      if (inReasoning) return inertTag(match);
      const id = this._ph('IG_', imgBlocks.length, true);
      imgBlocks.push({ type: 'gen', instruction: pending.instruction });
      return '\n\n' + id + '\n\n';
    });
    html = html.replace(/\[IMG:GEN(?::(.*?))?\]/g, (match, instruction) => {
      if (inReasoning) return inertTag(match);
      const id = this._ph('IG_', imgBlocks.length, true);
      imgBlocks.push({ type: 'gen', instruction: instruction || '' });
      return '\n\n' + id + '\n\n';
    });
    html = html.replace(/\[IMG:RESULT:(.*?)\]/g, (match, payload) => {
      const id = this._ph('IG_', imgBlocks.length, true);
      const parsed = parseImageResultPayload(payload);
      imgBlocks.push({
        type: 'result',
        path: parsed.paths[parsed.activeIndex] || parsed.paths[0] || '',
        paths: parsed.paths,
        activeIndex: parsed.activeIndex,
        instruction: parsed.instruction,
      });
      return '\n\n' + id + '\n\n';
    });
    html = html.replace(/\[IMG:ERROR:(.*?)\]/g, (match, data) => {
      const id = this._ph('IG_', imgBlocks.length, true);
      imgBlocks.push({ type: 'error', data });
      return '\n\n' + id + '\n\n';
    });

    // 6. Extract HTML Tags — distinguish block vs inline
    //    Skip orphan tags (no matching pair) so they render as visible text
    //    instead of being interpreted as real HTML elements.
    const tagBlocks = [];
    const blockTags = new Set(['div','p','style','pre','table','ul','ol','li','h1','h2','h3','h4','h5','h6','blockquote','section','article','header','footer','hr','details','summary','figure','figcaption','svg','path','math','canvas','video','audio','form','fieldset','nav','aside','main','img','loomledger']);
    const TAG_REGEX = /<(?:[^"'>]|"[^"]*"|'[^']*')*>/g;

    const allTagMatches = [...html.matchAll(TAG_REGEX)];
    const tagCounts = new Map();
    for (const m of allTagMatches) {
      const nameMatch = m[0].match(/^<\/?(\w+)/);
      if (nameMatch) {
        const name = nameMatch[1].toLowerCase();
        tagCounts.set(name, (tagCounts.get(name) || 0) + 1);
      }
    }

    html = html.replace(TAG_REGEX, (match) => {
      const tagMatch = match.match(/^<\/?(\w+)/);
      if (!tagMatch) return match;
      const name = tagMatch[1].toLowerCase();
      const count = tagCounts.get(name) || 0;
      // Self-closing tags (br, hr, img) and paired tags are fine;
      // single occurrence of a non-self-closing tag is orphan — escape it.
      // Every HTML void element: it is written once, with no closing tag, so
      // the orphan rule below would turn `<source>` inside a `<video>` into
      // visible `&lt;source&gt;` text.
      const selfClosing = new Set([
        'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link',
        'meta', 'param', 'source', 'track', 'wbr',
      ]);
      const isExplicitSelfClosing = /\/\s*>$/.test(match);
      if (count === 1 && !selfClosing.has(name) && !isExplicitSelfClosing) {
        return match.replace(/</g, '&lt;').replace(/>/g, '&gt;');
      }
      const isBlock = blockTags.has(name);
      const id = this._ph('T_', tagBlocks.length, isBlock);
      tagBlocks.push(match);
      return id;
    });

    // 7. Extract Glaze custom markers BEFORE quotes
    const styledSegments = [];
    const styledRegex = /(==hc:#[0-9a-fA-F]{3,8}==.+?==|==glow:#[0-9a-fA-F]{3,8},\d+==.+?==|==cg:#[0-9a-fA-F]{3,8},#[0-9a-fA-F]{3,8},\d+==.+?==|==grad:#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+==.+?==|==bg:#[0-9a-fA-F]{3,8}==.+?==|==mark==.+?==|==active==.+?==|==accent==.+?==|\*\*[^*\n]+?\*\*|(?<!\*)\*(?=[^*\n]*[^ \t*\n])[^*\n]+?\*(?!\*)|__[^_\n]+?__|(?<!\w)_[^_\n]+?_(?!\w)|~~[^~\n]+?~~)/gs;

    html = html.replace(styledRegex, (match) => {
      const id = this._ph('S_', styledSegments.length);
      styledSegments.push(match);
      return id;
    });
    // Models occasionally emit `».* *action*`: the first `*` is an orphan
    // marker, not an empty italic segment. Drop it once the real action is
    // safely stashed, otherwise it steals that action's opening marker.
    html = html.replace(/\*([ \t]+)(?=\x01S_\d+\x01)/g, '$1');

    // 8. Quote formatting — with unclosed quote handling for streaming
    if (!skipQuotes) {
      const phGroup = '\x01[A-Z_]+\\d+\x01';
      // Never let a malformed outer « quote consume a styled-segment
      // placeholder while looking for its closing ». Each placeholder is
      // restored independently in step 9.
      const quoteRegex = new RegExp(`(${phGroup})|(=[ \\t]*"(?:[^"]|\\\\")*?")|(")((?:[^"]|\\\\")*?)(")|(«)([^»\x01]*?(?:«[^»\x01]*?»[^»\x01]*?)*?)(»)|(")((?:[^"]*)$)`, 'gm');
      html = html.replace(quoteRegex, (match, placeholder, skipQuote, openQ, closedContent, closeQ, openG, guillemetContent, closeG, openU, unclosedContent) => {
        if (placeholder) return placeholder;
        if (skipQuote) return skipQuote;
        if (openQ !== undefined) return `<span class="chat-quote">${openQ}</span><span class="chat-quote-text">${closedContent}</span><span class="chat-quote">${closeQ}</span>`;
        if (openG !== undefined) {
          // Nested «outer «inner» more outer» — split at inner «» so the
          // inner quote renders with default (narration) color, while the
          // outer text keeps the quote color. Inner «» are literal chars,
          // not separately colored.
          const parts = guillemetContent.split(/(«[^»]*?»)/);
          const rendered = parts.map(p => {
            if (!p) return '';
            if (/^«[^»]*?»$/.test(p)) return p;
            return `<span class="chat-quote-text">${p}</span>`;
          }).join('');
          return `<span class="chat-quote">${openG}</span>${rendered}<span class="chat-quote">${closeG}</span>`;
        }
        if (openU !== undefined) return `<span class="chat-quote">${openU}</span><span class="chat-quote-text">${unclosedContent}</span>`;
        return match;
      });
    }

    // 9. Restore styled segments with Glaze marker rendering
    html = html.replace(/\x01S_(\d+)\x01/g, (_, i) => {
      const seg = styledSegments[parseInt(i)];
      // skipQuotes defaults to true (preserve color markers' fills);
      // plain formatting (italic/bold/strike) opts out via the second arg.
      return renderStyledSegment(seg, (innerRaw, skipQuotes = true) => this._processText(innerRaw, false, skipQuotes, inReasoning));
    });

    // 10. Markdown Parsing
    html = html.replace(/^>\s?(.*)$/gm, '<blockquote class="chat-blockquote">$1</blockquote>');
    html = html.replace(/<\/blockquote>\n*<blockquote class="chat-blockquote">/g, '<br>');
    html = html.replace(/^(_{3,}|-{3,}|\*{3,})$/gm, () => {
      // A raw `<hr>` here would be plain text to step 11 and end up inside a
      // paragraph; as a tag placeholder it keeps its own line.
      tagBlocks.push('<hr>');
      return `\n\n${this._ph('T_', tagBlocks.length - 1, true)}\n\n`;
    });
    html = html.replace(/~~([^~\n]+?)~~/g, '<del>$1</del>');
    html = html.replace(/\*\*\*([^*\n]+?)\*\*\*/g, '<strong><em>$1</em></strong>');
    html = html.replace(/\*\*([^*\n]+?)\*\*/g, '<strong>$1</strong>');
    // Never let an unmatched marker consume text from a later line.
    html = html.replace(/\*([^*\n]+?)\*/g, '<em>$1</em>');
    html = html.replace(/<em>/g, '<em class="chat-italic">');

    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');

    // 10a0. Markdown tables — header row, a `---` separator, then body rows.
    //       The separator is what tells a table from a line of prose that
    //       happens to use pipes, so it is required.
    const TABLE_RUN =
      /(?:^|\n)([ \t]*\|[^\n]*\|[ \t]*\n[ \t]*\|[ \t:|-]+\|[ \t]*(?:\n[ \t]*\|[^\n]*\|[ \t]*)*)/g;
    html = html.replace(TABLE_RUN, (match, run) => {
      const rows = run.trim().split('\n').map(line => line.trim());
      const cells = row => row.replace(/^\||\|$/g, '').split('|').map(c => c.trim());
      const head = cells(rows[0]).map(c => `<th>${c}</th>`).join('');
      const body = rows.slice(2)
        .map(row => `<tr>${cells(row).map(c => `<td>${c}</td>`).join('')}</tr>`)
        .join('');
      tagBlocks.push(
        `<table class="chat-table"><thead><tr>${head}</tr></thead>` +
        `${body ? `<tbody>${body}</tbody>` : ''}</table>`,
      );
      return `\n\n${this._ph('T_', tagBlocks.length - 1, true)}\n\n`;
    });

    // 10a. Headings — `#` through `######`, the way every markdown renderer
    //      spells them. Left as text they show up as literal hashes.
    html = html.replace(/^(#{1,6})[ \t]+(.+?)[ \t]*#*$/gm, (match, hashes, body) => {
      const level = hashes.length;
      tagBlocks.push(`<h${level} class="chat-heading">${body}</h${level}>`);
      return `\n\n${this._ph('T_', tagBlocks.length - 1, true)}\n\n`;
    });

    // 10b. Markdown lists
    const listBlocks = [];
    html = html.replace(/((?:^|\n)((?:[ \t]*[-*] .+(?:\n|$))+))/g, (match) => {
      const id = this._ph('LB_', listBlocks.length, true);
      // An indented item belongs to the list above it. Splitting the run at
      // the first indented line left it stranded as its own paragraph between
      // two lists; nesting it keeps the run one list.
      const items = match.trim().split('\n')
        .filter(line => /^[ \t]*[-*] /.test(line))
        .map(line => ({
          depth: /^[ \t]+/.test(line) ? 1 : 0,
          text: line.replace(/^[ \t]*[-*] /, ''),
        }));
      let rendered = '';
      let nested = false;
      let open = false;
      for (const item of items) {
        if (item.depth) {
          // The sub-list lives inside the item above it, which stays open
          // until the run ends or the next top-level item starts.
          if (!nested) { rendered += '<ul class="chat-list">'; nested = true; }
          rendered += `<li>${item.text}</li>`;
          continue;
        }
        if (nested) { rendered += '</ul>'; nested = false; }
        if (open) rendered += '</li>';
        rendered += `<li>${item.text}`;
        open = true;
      }
      if (nested) rendered += '</ul>';
      if (open) rendered += '</li>';
      listBlocks.push(`<ul class="chat-list">${rendered}</ul>`);
      return '\n\n' + id + '\n\n';
    });
    html = html.replace(/((?:^|\n)((?:\d+\. .+(?:\n|$))+))/g, (match) => {
      const id = this._ph('LB_', listBlocks.length, true);
      const items = match.trim().split('\n')
        .filter(line => line.match(/^\d+\. /))
        .map(line => `<li>${line.replace(/^\d+\. /, '')}</li>`)
        .join('');
      listBlocks.push(`<ol class="chat-list">${items}</ol>`);
      return '\n\n' + id + '\n\n';
    });

    // 11. Paragraphs — isolate block placeholders, don't wrap in <p>
    const blockPh = '\x01T_BLOCK_\\d+\x01';
    const codePh = '\x01CB_\\d+\x01';
    const stylePh = '\x01STY_BLOCK_\\d+\x01';
    const scriptPh = '\x01SCR_BLOCK_\\d+\x01';
    const listPh = '\x01LB_BLOCK_\\d+\x01';
    const imgPh = '\x01IG_BLOCK_\\d+\x01';
    const allBlockPh = `${codePh}|${blockPh}|${stylePh}|${scriptPh}|${listPh}|${imgPh}`;
    html = html.replace(new RegExp(`\\n?(${allBlockPh})\\n?`, 'g'), '\n\n$1\n\n');

    const paragraphs = html.split(/\n\n+/);
    html = paragraphs
      .map(p => {
        let trimmed = p.trim();
        if (!trimmed) return '';

        if (new RegExp(`^(${allBlockPh})$`).test(trimmed)) return trimmed;

        // A paragraph made of nothing but HTML tags — a bare `<input>` on its
        // own line, say — is left unwrapped. A `<p>` around it would reparent
        // the tag, and CSS-only cards are built on exactly that adjacency:
        // `#toggle:checked ~ .overlay` stops matching the moment the checkbox
        // and its target stop being siblings, so the card's button goes dead
        // while the checkbox itself still toggles.
        if (ONLY_TAG_PLACEHOLDERS.test(trimmed)) {
          return trimmed.replace(/\s*\n\s*/g, '');
        }

        const startsWithBlock = new RegExp(`^(${blockPh}|${stylePh}|${scriptPh})`).test(trimmed);
        trimmed = trimmed.replace(new RegExp(`(\x01T_(?:BLOCK_)?\\d+\x01)\\s*\\n\\s*`, 'g'), '$1 ');
        trimmed = trimmed.replace(new RegExp(`\\s*\\n\\s*(\x01T_(?:BLOCK_)?\\d+\x01)`, 'g'), ' $1');
        trimmed = trimmed.replace(/\n/g, '<br>');
        return startsWithBlock ? trimmed : `<p>${trimmed}</p>`;
      })
      .filter(p => p !== '')
      .join('');

    // 12. Restore HTML Tags
    html = html.replace(/\x01T_(?:BLOCK_)?(\d+)\x01/g, (_, i) => tagBlocks[parseInt(i)]);
    html = html.replace(/(<svg\b[^>]*>)\s*<p>([\s\S]*?)<\/p>\s*(<\/svg>)/gi, '$1$2$3');

    // 12b. Restore list blocks
    html = html.replace(/\x01LB_BLOCK_(\d+)\x01/g, (_, i) => listBlocks[parseInt(i)]);

    // 12c. Restore markdown image cards — kept whole so the options button
    //      stays inside its positioned .janitor-img-wrapper (see step 5b).
    html = html.replace(/\x01MI_(\d+)\x01/g, (_, i) => mdImages[parseInt(i)]);

    // 12d. Restore inline code — escaped, so a tag written inside backticks
    //      is shown, not rendered.
    html = html.replace(/\x01IC_(\d+)\x01/g, (_, i) => {
      const code = inlineCode[parseInt(i)];
      return `<code>${this._escapeHtml(code)}</code>`;
    });

    // 13. Restore CSS comments
    html = html.replace(/\x01CC_(\d+)\x01/g, (_, i) => cssComments[parseInt(i)]);

    // 14. Restore style blocks
    html = html.replace(/\x01STY_BLOCK_(\d+)\x01/g, (_, i) => styleBlocks[parseInt(i)]);

    // 15. Restore script blocks (will be executed by renderer via DOM API)
    html = html.replace(/\x01SCR_BLOCK_(\d+)\x01/g, (_, i) => {
      return scriptBlocks[parseInt(i)];
    });

    // 16. Restore Code Blocks
    html = html.replace(/\x01CB_(\d+)\x01/g, (_, i) => {
      const block = codeBlocks[parseInt(i)];
      const escapedCode = block.code
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
      const langAttr = block.lang ? ` class="language-${block.lang}"` : '';
      const langLabel = block.lang ? `<span class="code-lang">${block.lang}</span>` : '';
      return `<div class="code-block-wrapper">${langLabel}<pre><code${langAttr}>${escapedCode}</code></pre></div>`;
    });

    // 17. Restore think blocks
    html = html.replace(/\x01TB_BLOCK_(\d+)\x01/g, (_, i) => {
      const content = thinkBlocks[parseInt(i)];
      const formatted = this._processText(content, isUser, false, true);
      return `<details class="reasoning-block"><summary class="reasoning-summary">💭 Reasoning</summary><div class="reasoning-content">${formatted}</div></details>`;
    });

    // 18. Restore font color/style blocks
    // skipQuotes=true: quotes inside styled spans keep their visual style intact
    // (chat-quote color would override gradient/color fills)
    html = html.replace(/\x01FC_(\d+)\x01/g, (_, i) => {
      const block = fontBlocks[parseInt(i)];
      if (block.type === 'style') {
        let formatted = this._processText(block.content, isUser, true, inReasoning);
        formatted = formatted.replace(/^\s*<p>([\s\S]*?)<\/p>\s*$/i, '$1');

        // Propagate gradient / text-fill / clip styles down to the first nested inline element
        // when the LLM put the visible text inside <span style="transform..."> inside the <font>.
        // Without this the background-clip:text on the outer span has no text to clip.
        const hasGradientClip = /background-clip\s*:\s*text/i.test(block.style) ||
                                /-webkit-background-clip\s*:\s*text/i.test(block.style) ||
                                /-webkit-text-fill-color\s*:\s*transparent/i.test(block.style);
        if (hasGradientClip) {
          const toMerge = [];
          const bg = block.style.match(/background-image\s*:\s*[^;]+/i);
          const clip = block.style.match(/-webkit-background-clip\s*:\s*[^;]+/i);
          const fill = block.style.match(/-webkit-text-fill-color\s*:\s*[^;]+/i);
          const stroke = block.style.match(/-webkit-text-stroke\s*:\s*[^;]+/i);
          const filter = block.style.match(/filter\s*:\s*[^;]+/i);
          for (const m of [bg, clip, fill, stroke, filter]) if (m) toMerge.push(m[0]);
          if (toMerge.length) {
            const extra = toMerge.join('; ');
            formatted = formatted.replace(/^(\s*<span)(\s+style=")([^"]*)(")/i, (m, tagOpen, styleOpen, inner, styleClose) => {
              const merged = (inner || '').replace(/;?\s*$/, '') + '; ' + extra;
              return `${tagOpen}${styleOpen}${merged}${styleClose}`;
            });
          }
        }

        return `<span class="font-style-block" style="${block.style}">${formatted}</span>`;
      }
      let formatted = this._processText(block.content, isUser, true, inReasoning);
      formatted = formatted.replace(/^\s*<p>([\s\S]*?)<\/p>\s*$/i, '$1');
      return `<span class="font-color-block" style="color:${block.color}">${formatted}</span>`;
    });

    // 19. Restore image gen blocks (Imagen UI ported from Glaze ShadowContent.vue)
    //
    // The placeholders sit where their tags were, so this pass walks the blocks
    // in document order — the same order ImageTagMarkup.scanImageBlocks() sees
    // on the Dart side. `data-img-index` carries that position back with every
    // tap, which is what makes an action apply to one image and not the whole
    // message.
    let imgBlockIndex = 0;
    html = html.replace(/\x01IG_BLOCK_(\d+)\x01/g, (_, i) => {
      const block = imgBlocks[parseInt(i)];
      const at = imgBlockIndex++;
      if (block.type === 'result') {
        const src = this._imageSrc(block.path);
        const encInstr = encodeURIComponent(block.instruction || '');
        const variants = (block.paths || []).map((p) => this._imageSrc(p));
        const activeIndex = variants.length > 1 ? (block.activeIndex || 0) : 0;
        // The switcher only exists once the block holds a second image, so a
        // single-image block renders exactly as it always did.
        const switcher = variants.length > 1
          ? `<span class="imggen-variants"><button class="imggen-variant-btn" type="button" data-action="img-variant-prev" data-img-index="${at}" title="Previous image">${VARIANT_PREV_SVG}</button><span class="imggen-variant-count">${activeIndex + 1}/${variants.length}</span><button class="imggen-variant-btn" type="button" data-action="img-variant-next" data-img-index="${at}" title="Next image">${VARIANT_NEXT_SVG}</button></span>`
          : '';
        // The whole list rides along on the wrapper so paging through the
        // block swaps the picture in place, with no round trip to Flutter.
        const variantAttrs = variants.length > 1
          ? ` data-variants="${this._escapeHtml(variants.join(IMG_VARIANT_SEPARATOR))}" data-variant-index="${activeIndex}"`
          : '';
        // loading="eager" (not "lazy"): a just-generated image lands at the
        // bottom edge of the WebView, where Android/iOS keep resizing the
        // viewport around the input bar. A lazy image there can be evaluated
        // while the row is still off-screen and never come back for it, and
        // the picture the user just waited for shows as a broken tag. These
        // are local files, so eager loading costs nothing — same reasoning as
        // _renderExtBlockImageHtml in the bridge controller.
        return `<span class="imggen-result-wrapper"${variantAttrs}><img src="${src}" class="imggen-result" loading="eager" decoding="async" data-action="image-click" data-src="${src}"><button class="imggen-options-btn" type="button" data-action="img-options" data-src="${src}" data-instruction="${encInstr}" data-img-index="${at}" title="Options">${OPTIONS_SVG}</button>${switcher}</span>`;
      }
      if (block.type === 'gen') {
        const start = Date.now();
        // A pending block that carried images through a regeneration spells its
        // payload `@paths|instruction`; reading it here keeps the prompt line
        // showing the prompt instead of the path list in front of it.
        const pending = parseImagePendingPayload(block.instruction);
        const prompt = this._escapeHtml(this._imgPrompt(pending.instruction));
        const promptEl = prompt ? `<div class="imggen-loading-prompt">${prompt}</div>` : '';
        // The children are moved into a shadow root of the placeholder's own by
        // `isolateImgGenPlaceholders` right after insertion, which is what keeps
        // message CSS from restyling them (see renderer/imggen_placeholder.js).
        return `<div class="imggen-loading" data-start="${start}" data-img-index="${at}"><span class="imggen-loading-hint">Generating image…</span><span class="imggen-loading-timer" data-start="${start}">0.0s</span><button class="imggen-stop-btn" type="button" data-action="img-stop" title="Stop image generation" aria-label="Stop image generation">${STOP_SVG}</button>${promptEl}</div>`;
      }
      if (block.type === 'error') {
        let errorMsg = 'Unknown error';
        let instruction = '';
        try {
          const parsed = JSON.parse(block.data);
          errorMsg = parsed.error || errorMsg;
          instruction = parsed.instruction || '';
        } catch(_) {}
        const encInstr = encodeURIComponent(instruction);
        if (errorMsg === 'Image generation disabled') {
          return `<div class="imggen-error imggen-disabled" data-instruction="${encInstr}" data-img-index="${at}"><span class="imggen-error-icon">🖼</span><span class="imggen-error-msg">Image generation disabled</span><div class="imggen-error-actions"><button class="imggen-error-retry" type="button" data-action="img-enable-retry" data-instruction="${encInstr}" data-img-index="${at}">Enable and generate</button></div></div>`;
        }
        return `<div class="imggen-error" data-instruction="${encInstr}" data-img-index="${at}"><span class="imggen-error-icon">⚠</span><span class="imggen-error-msg">${this._escapeHtml(errorMsg)}</span><div class="imggen-error-actions"><button class="imggen-error-retry" type="button" data-action="img-retry" data-instruction="${encInstr}" data-img-index="${at}">↻ Regenerate</button><button class="imggen-error-options" type="button" data-action="img-options" data-instruction="${encInstr}" data-img-index="${at}" title="Options">${OPTIONS_SVG}</button></div></div>`;
      }
      return '';
    });

    // 19b. Restore the tags a reasoning block only talked about, as the text
    // the model wrote. Nothing here loads, spins or generates.
    html = html.replace(/\x01IGT_(\d+)\x01/g, (_, i) =>
      this._escapeHtml(inertImgTags[parseInt(i)]),
    );

    html = html.replace(/\x01[A-Z_]+\d+\x01/g, '');

    return html;
  }

  _renderStyledSegment(seg) {
    return renderStyledSegment(seg, (innerRaw) => this._processText(innerRaw, false, true));
  }

  _imageSrc(path) {
    if (!path) return '';
    if (path.startsWith('data:') || path.startsWith('http://') || path.startsWith('https://') || path.startsWith('file://')) {
      return path;
    }
    const normalized = path.replace(/\\/g, '/');
    return normalized.startsWith('/') ? `file://${normalized}` : `file:///${normalized}`;
  }

  // Normalizes the destination of a markdown image/link.
  //
  // The raw capture is everything between the parens, which for CommonMark can
  // carry padding, an <…> wrapper and a title: `![a]( <u> "cap" )`. A browser
  // trims and re-encodes most of that when it loads the <img>, so the picture
  // still appears in the message — but the same raw string handed to Flutter
  // (via data-src) is not a valid URL there, and the full-screen viewer opens
  // onto nothing. Normalize once, so both sides see the same URL.
  _normalizeMdUrl(url) {
    let out = String(url == null ? '' : url).trim();
    // Trailing title: `url "caption"` / `url 'caption'` / `url (caption)`.
    const titled = out.match(/^(\S+)\s+(?:"[^"]*"|'[^']*'|\([^)]*\))$/);
    if (titled) out = titled[1];
    if (out.startsWith('<') && out.endsWith('>')) out = out.slice(1, -1).trim();
    return out;
  }

  _escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Extract a human-readable prompt from an IMG:GEN instruction payload.
  // The payload may be a JSON object ({prompt, caption, ...}) or raw text.
  _imgPrompt(instruction) {
    const raw = (instruction || '').trim();
    if (!raw) return '';
    try {
      const json = JSON.parse(raw);
      if (json && typeof json === 'object') {
        const p = (json.prompt || json.caption || '').replace(/^SCENE_PROMPT:\s*/, '');
        return p || '';
      }
    } catch (_) { /* fall through to raw */ }
    return raw;
  }
}
