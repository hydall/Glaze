// Phase B: markdown over the parsed message, text node by text node.
//
// Phase A handed us a tree. Nothing in this file guesses at structure — the
// parser already decided what is an element, which elements nest and where an
// unclosed tag ends. What is left is to format the *text* between those
// elements, and to do it without moving any of them.
//
// Two rules carry most of the weight:
//
//   * markdown is applied to a run of text and inline elements, with the
//     elements masked out. A `*` inside an attribute is unreachable, and a
//     `<b>` in the middle of an italic run stays where the author put it.
//   * `<p>` is only ever added at the top level of a message, and never
//     between an element and a block sibling it might be styled against. A
//     paragraph wrapped around someone's card is what breaks `~` and `+`.

import { isKnownElement, RAW_TEXT_ELEMENTS } from './html_scan.js';
import { SENTINEL } from './protect.js';
import { applyBlockSyntax } from './block_syntax.js';
import { applyInlineSyntax, escapeText } from './inline_syntax.js';

/** Elements that flow with the text around them, so they join its run. */
const PHRASING = new Set([
  'a', 'abbr', 'audio', 'b', 'bdi', 'bdo', 'big', 'br', 'button', 'canvas',
  'cite', 'code', 'data', 'datalist', 'del', 'dfn', 'em', 'embed', 'font',
  'i', 'iframe', 'img', 'input', 'ins', 'kbd', 'label', 'map', 'mark', 'math',
  'meter', 'nobr', 'object', 'output', 'picture', 'progress', 'q', 'ruby',
  's', 'samp', 'select', 'slot', 'small', 'span', 'strike', 'strong', 'sub',
  'sup', 'svg', 'textarea', 'time', 'tt', 'u', 'var', 'video', 'wbr',
]);

/** Elements whose content is flow content, where a list or table may start. */
const FLOW_CONTAINERS = new Set([
  'article', 'aside', 'blockquote', 'center', 'dd', 'details', 'div',
  'fieldset', 'figcaption', 'figure', 'footer', 'form', 'header', 'li',
  'main', 'nav', 'section', 'td', 'th',
]);

/** Elements this pass never reaches inside: their content is not prose. */
const OPAQUE = new Set([...RAW_TEXT_ELEMENTS, 'svg', 'math', 'template']);

function isElement(node) {
  return node && node.nodeType === 1;
}

function isPhrasing(node) {
  return isElement(node) && PHRASING.has(node.localName);
}

/** A custom element is a card's own container, so it may hold blocks too. */
function canHoldBlocks(name) {
  return FLOW_CONTAINERS.has(name) || !isKnownElement(name);
}

function isBlank(node) {
  return node.nodeType === 3 && !node.data.trim();
}

/** Whitespace between two nodes that contains a blank line detaches them. */
function hasBlankLine(node) {
  return node.nodeType === 3 && /\n[ \t]*\n/.test(node.data);
}

/**
 * True when the run sits right against a block element the author wrote.
 *
 * This is the CSS-only card: `<input id="t1"><label>…</label><div class="ov">`
 * with `#t1:checked ~ .ov` in the card's `<style>`. Wrapping the run in a
 * paragraph moves the checkbox into it, the two stop being siblings, and the
 * card's button goes dead while the checkbox itself still toggles. Prose
 * separated from a card by a blank line is not touching it and still gets its
 * paragraphs.
 */
function touchesBlockSibling(run) {
  const first = run.find((node) => !isBlank(node));
  const last = [...run].reverse().find((node) => !isBlank(node));
  if (!isElement(first) && !isElement(last)) return false;

  const before = run[0].previousSibling;
  const after = run[run.length - 1].nextSibling;
  const leadingGap = isBlank(run[0]) ? run[0] : null;
  const trailingGap = isBlank(run[run.length - 1]) ? run[run.length - 1] : null;

  const tightBefore = isElement(first) && isElement(before) &&
    !(leadingGap && hasBlankLine(leadingGap));
  const tightAfter = isElement(last) && isElement(after) &&
    !(trailingGap && hasBlankLine(trailingGap));
  return tightBefore || tightAfter;
}

/**
 * Replaces every `PREFIX_n` placeholder in [root]'s text with what [resolve]
 * returns for it: a node, a list of nodes, or null to leave it alone.
 */
export function replacePlaceholders(root, prefix, resolve) {
  const pattern = new RegExp(`${SENTINEL}${prefix}_(\\d+)${SENTINEL}`, 'g');
  const document_ = root.ownerDocument || document;
  const walker = document_.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const pending = [];
  while (walker.nextNode()) {
    pattern.lastIndex = 0;
    if (pattern.test(walker.currentNode.data)) pending.push(walker.currentNode);
  }
  for (const node of pending) {
    const parts = node.data.split(new RegExp(`${SENTINEL}${prefix}_(\\d+)${SENTINEL}`));
    const fragment = document_.createDocumentFragment();
    for (let i = 0; i < parts.length; i++) {
      if (i % 2 === 0) {
        if (parts[i]) fragment.appendChild(document_.createTextNode(parts[i]));
        continue;
      }
      const resolved = resolve(parts[i]);
      if (resolved == null) {
        fragment.appendChild(document_.createTextNode(
          `${SENTINEL}${prefix}_${parts[i]}${SENTINEL}`,
        ));
      } else if (Array.isArray(resolved)) {
        for (const child of resolved) fragment.appendChild(child);
      } else {
        fragment.appendChild(resolved);
      }
    }
    node.replaceWith(fragment);
  }
}

/** Turns an HTML string into nodes, in the message's own document. */
export function parseHtml(html, document_) {
  const template = document_.createElement('template');
  template.innerHTML = html;
  return template.content;
}

function formatRun(run, container, context) {
  const document_ = container.ownerDocument || document;
  const kept = [];
  const masked = run.map((node) => {
    if (node.nodeType === 3) return escapeText(node.data);
    if (isElement(node)) {
      kept.push(node);
      return `${SENTINEL}E_${kept.length - 1}${SENTINEL}`;
    }
    return '';
  }).join('');

  if (!masked.trim()) return;

  const inline = (line) => applyInlineSyntax(line, context.inlineContext);
  const html = context.allowBlocks
    ? applyBlockSyntax(masked, { inline, paragraphs: context.paragraphs })
    : inline(masked).replace(/\n/g, '<br>');

  // Detach the run before the formatted tree is built: the elements it kept
  // are moved into that tree, and removing "what the run used to be"
  // afterwards would take them straight back out again.
  const anchor = document_.createTextNode('');
  container.insertBefore(anchor, run[0]);
  for (const node of run) node.remove();

  const formatted = parseHtml(html, document_);
  replacePlaceholders(formatted, 'E', (index) => kept[Number(index)] || null);
  anchor.replaceWith(formatted);
}

/**
 * Formats the text inside one container: first its element children (each in
 * its own context), then the runs of text between them.
 */
export function formatContainer(container, { isRoot, allowBlocks, inlineContext }) {
  for (const child of Array.from(container.children)) {
    const name = child.localName;
    if (OPAQUE.has(name)) continue;
    formatContainer(child, {
      isRoot: false,
      allowBlocks: canHoldBlocks(name),
      inlineContext,
    });
  }

  const runs = [];
  let run = [];
  for (const node of Array.from(container.childNodes)) {
    if (isElement(node) && !isPhrasing(node)) {
      if (run.length) runs.push(run);
      run = [];
      continue;
    }
    if (node.nodeType === 8) continue;
    run.push(node);
  }
  if (run.length) runs.push(run);

  for (const current of runs) {
    formatRun(current, container, {
      allowBlocks,
      paragraphs: isRoot && !touchesBlockSibling(current),
      inlineContext,
    });
  }
}

/**
 * `<font>` is the one element the message CSS restyles rather than renders.
 *
 * A gradient fill written as `<font style="background-clip:text">` has nothing
 * to clip when the visible text sits in a nested `<span style="transform:…">`,
 * which is how models write it. The fill properties are copied down to that
 * first child so the text takes the gradient instead of disappearing.
 */
export function convertFontElements(root) {
  for (const font of Array.from(root.querySelectorAll('font'))) {
    const span = (root.ownerDocument || document).createElement('span');
    const color = font.getAttribute('color');
    const style = font.getAttribute('style');
    if (style) {
      span.className = 'font-style-block';
      span.setAttribute('style', style);
    } else if (color) {
      span.className = 'font-color-block';
      span.setAttribute('style', `color:${color}`);
    } else {
      span.className = 'font-color-block';
    }
    while (font.firstChild) span.appendChild(font.firstChild);
    font.replaceWith(span);

    const fill = /(?:-webkit-)?background-clip\s*:\s*text|-webkit-text-fill-color\s*:\s*transparent/i;
    if (!style || !fill.test(style)) continue;
    const inner = span.firstElementChild;
    if (!inner) continue;
    const carried = (style.match(
      /(?:background-image|-webkit-background-clip|-webkit-text-fill-color|-webkit-text-stroke|filter)\s*:\s*[^;]+/gi,
    ) || []).join('; ');
    if (!carried) continue;
    const own = (inner.getAttribute('style') || '').replace(/;?\s*$/, '');
    inner.setAttribute('style', own ? `${own}; ${carried}` : carried);
  }
}
