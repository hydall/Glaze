// Image blocks: the stored forms an image tag is written in, and the markup
// each one renders to.
//
// Split out of formatter.js when the formatter became a two-phase renderer.
// Everything here works on the *raw* message text, before it is parsed: an
// image tag is pulled out of the source and replaced with a placeholder, so
// the parser never sees an `<img>` with no loadable source and the reader
// never watches a broken-image icon while a picture is being generated.

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
export const IMG_VARIANT_SEPARATOR = ';;';

/** Marks the image on screen inside a multi-image payload. */
const IMG_VARIANT_ACTIVE_MARKER = '*';

/** Introduces the images a pending block carries, mirroring the Dart codec. */
const IMG_PENDING_MARKER = '@';

/**
 * Matches one `<img …data-iig-instruction…>` element, the stored form of an
 * image block. Whether it is finished or still waiting is decided by its
 * `src` (see `parseImageResultElement`), not by the pattern.
 */
export const IIG_ELEMENT_REGEX = /<img\s[^>]*?data-iig-instruction\s*=\s*(?:"[^"]*"|'[^']*')[^>]*>/gi;

/**
 * Matches an `<img …src="[IMG:GEN…]">` element that carries no instruction
 * attribute — the spelling a model writes by hand, where the payload lives in
 * the `src`. Mirrors ImgGenPatterns.imgSrcGenRegex on the Dart side.
 */
export const IMG_SRC_GEN_ELEMENT_REGEX = /<img\b[^>]*?\bsrc\s*=\s*["']\[IMG:GEN[^\]]*\]["'][^>]*>/gi;

const ATTRIBUTE_PAIR_REGEX = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]*))/g;

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

function escapeHtml(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function imageSrc(path) {
  if (!path) return '';
  if (path.startsWith('data:') || path.startsWith('http://') ||
      path.startsWith('https://') || path.startsWith('file://')) {
    return path;
  }
  const normalized = path.replace(/\\/g, '/');
  return normalized.startsWith('/') ? `file://${normalized}` : `file:///${normalized}`;
}

// Extract a human-readable prompt from an IMG:GEN instruction payload.
// The payload may be a JSON object ({prompt, caption, ...}) or raw text.
function imgPrompt(instruction) {
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

/**
 * The markup one image block renders to.
 *
 * [at] is the block's position in the message — the same order
 * ImageTagMarkup.scanImageBlocks() sees on the Dart side. It rides back with
 * every tap as `data-img-index`, which is what makes an action apply to one
 * image and not the whole message (INV-IG6).
 */
export function renderImageBlock(block, at) {
  if (block.type === 'result') return renderResult(block, at);
  if (block.type === 'gen') return renderPending(block, at);
  if (block.type === 'error') return renderError(block, at);
  return '';
}

function renderResult(block, at) {
  const src = imageSrc(block.path);
  const encInstr = encodeURIComponent(block.instruction || '');
  const variants = (block.paths || []).map((p) => imageSrc(p));
  const activeIndex = variants.length > 1 ? (block.activeIndex || 0) : 0;
  // The switcher only exists once the block holds a second image, so a
  // single-image block renders exactly as it always did.
  const switcher = variants.length > 1
    ? `<span class="imggen-variants"><button class="imggen-variant-btn" type="button" data-action="img-variant-prev" data-img-index="${at}" title="Previous image">${VARIANT_PREV_SVG}</button><span class="imggen-variant-count">${activeIndex + 1}/${variants.length}</span><button class="imggen-variant-btn" type="button" data-action="img-variant-next" data-img-index="${at}" title="Next image">${VARIANT_NEXT_SVG}</button></span>`
    : '';
  // The whole list rides along on the wrapper so paging through the
  // block swaps the picture in place, with no round trip to Flutter.
  const variantAttrs = variants.length > 1
    ? ` data-variants="${escapeHtml(variants.join(IMG_VARIANT_SEPARATOR))}" data-variant-index="${activeIndex}"`
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

function renderPending(block, at) {
  const start = Date.now();
  // A pending block that carried images through a regeneration spells its
  // payload `@paths|instruction`; reading it here keeps the prompt line
  // showing the prompt instead of the path list in front of it.
  const pending = parseImagePendingPayload(block.instruction);
  const prompt = escapeHtml(imgPrompt(pending.instruction));
  const promptEl = prompt ? `<div class="imggen-loading-prompt">${prompt}</div>` : '';
  // The children are moved into a shadow root of the placeholder's own by
  // `isolateImgGenPlaceholders` right after insertion, which is what keeps
  // message CSS from restyling them (see renderer/imggen_placeholder.js).
  // Two labels, one of which is hidden: the block is "queued" until the
  // reply has finished streaming and post-gen actually reaches the image
  // stage (INV-IG1), and only then does anything start elapsing or
  // become stoppable. `refreshImgGenPlaceholderState` flips the class.
  return `<div class="imggen-loading" data-start="${start}" data-img-index="${at}"><span class="imggen-loading-hint">Generating image…</span><span class="imggen-queued-hint">Image queued…</span><span class="imggen-loading-timer" data-start="${start}">0.0s</span><button class="imggen-stop-btn" type="button" data-action="img-stop" title="Stop image generation" aria-label="Stop image generation">${STOP_SVG}</button>${promptEl}</div>`;
}

function renderError(block, at) {
  let errorMsg = 'Unknown error';
  let instruction = '';
  try {
    const parsed = JSON.parse(block.data);
    errorMsg = parsed.error || errorMsg;
    instruction = parsed.instruction || '';
  } catch (_) { /* keep the defaults */ }
  const encInstr = encodeURIComponent(instruction);
  if (errorMsg === 'Image generation disabled') {
    return `<div class="imggen-error imggen-disabled" data-instruction="${encInstr}" data-img-index="${at}"><span class="imggen-error-icon">🖼</span><span class="imggen-error-msg">Image generation disabled</span><div class="imggen-error-actions"><button class="imggen-error-retry" type="button" data-action="img-enable-retry" data-instruction="${encInstr}" data-img-index="${at}">Enable and generate</button></div></div>`;
  }
  return `<div class="imggen-error" data-instruction="${encInstr}" data-img-index="${at}"><span class="imggen-error-icon">⚠</span><span class="imggen-error-msg">${escapeHtml(errorMsg)}</span><div class="imggen-error-actions"><button class="imggen-error-retry" type="button" data-action="img-retry" data-instruction="${encInstr}" data-img-index="${at}">↻ Regenerate</button><button class="imggen-error-options" type="button" data-action="img-options" data-instruction="${encInstr}" data-img-index="${at}" title="Options">${OPTIONS_SVG}</button></div></div>`;
}

/**
 * Pulls every image tag out of the raw message text.
 *
 * Runs before the message is parsed, and in document order, so the blocks the
 * renderer emits are numbered the way the Dart side numbers them. [hold] takes
 * one block and returns the placeholder that stands in for it; [inert] takes a
 * tag that must stay literal text (a tag inside a reasoning block never
 * generates — INV-IG11).
 */
export function extractImageBlocks(text, { hold, inert, inReasoning }) {
  let out = text;

  out = out.replace(IIG_ELEMENT_REGEX, (match) => {
    const parsed = parseImageResultElement(match);
    if (!parsed) {
      // Still waiting for its picture: render the loading placeholder in the
      // element's place. Leaving the tag alone would put an <img> with no
      // loadable source into the message, and the reader would watch a
      // broken-image icon for the whole generation.
      const pending = parseImagePendingElement(match);
      if (!pending) return match;
      if (inReasoning) return inert(match);
      return hold({ type: 'gen', instruction: pending.instruction });
    }
    return hold({
      type: 'result',
      path: parsed.paths[parsed.activeIndex] || parsed.paths[0] || '',
      paths: parsed.paths,
      activeIndex: parsed.activeIndex,
      instruction: parsed.instruction,
    });
  });

  // `<img src="[IMG:GEN…]">` with no instruction attribute: the whole element
  // is the block, so it has to go before the bare-payload pass below —
  // otherwise only the src payload is consumed and the empty <img> stays
  // behind as a broken-image icon.
  out = out.replace(IMG_SRC_GEN_ELEMENT_REGEX, (match) => {
    const pending = parseImagePendingElement(match);
    if (!pending) return match;
    if (inReasoning) return inert(match);
    return hold({ type: 'gen', instruction: pending.instruction });
  });

  out = out.replace(/\[IMG:GEN(?::(.*?))?\]/g, (match, instruction) => {
    if (inReasoning) return inert(match);
    return hold({ type: 'gen', instruction: instruction || '' });
  });

  out = out.replace(/\[IMG:RESULT:(.*?)\]/g, (_match, payload) => {
    const parsed = parseImageResultPayload(payload);
    return hold({
      type: 'result',
      path: parsed.paths[parsed.activeIndex] || parsed.paths[0] || '',
      paths: parsed.paths,
      activeIndex: parsed.activeIndex,
      instruction: parsed.instruction,
    });
  });

  out = out.replace(/\[IMG:ERROR:(.*?)\]/g, (_match, data) => hold({ type: 'error', data }));

  return out;
}
