// Two policies live here.
//
// **Message HTML** (`sanitizeMessageHtml`) filters *code* and nothing else.
// Turning message scripts off has to stop JS from running — it must not also
// rewrite the markup: elements, attributes, `<style>` blocks and `style="…"`
// reach the message shadow root exactly as the author wrote them, so a card
// renders the same with execution on and off. Only the things that run code
// are dropped: `<script>`, the frame elements that host a document of their
// own, `on…=` handlers and script-bearing URLs.
//
// **ExtBlock HTML** (`sanitizeExtBlockHtml`) keeps the stricter element /
// attribute / CSS policy below. It is inserted into the light DOM next to the
// app's own chrome rather than into a per-message shadow root, so its rules
// stay scoped and its element set stays narrow.

import { sanitizeCssText, sanitizeStyleDeclaration } from './css_sanitizer.js';

const BLOCKED_ELEMENTS = new Set([
  'script', 'iframe', 'object', 'embed', 'form', 'math', 'meta',
  'link', 'base',
  // Preserve formatter-generated static <svg><path> icons, but reject SVG
  // features that can load resources, embed HTML, or trigger animation.
  'foreignobject', 'animate', 'animatemotion', 'animatetransform', 'set',
  'use', 'image', 'feimage',
]);

const URL_ATTRIBUTES = new Set([
  'href', 'src', 'xlink:href', 'action', 'formaction', 'poster',
]);

const SAFE_IMAGE_DATA_URL = /^data:image\/(?:png|jpe?g|webp|gif|avif);base64,/i;

// ExtBlock HTML is inserted into the light DOM, so its `<style>` rules are
// pinned to the block body instead of leaking into the app chrome. Message
// HTML needs no prefix — it is written into a per-message shadow root.
const EXT_BLOCK_CSS_SCOPE = '.ext-block-content';

function isSafeDataUrl(element, attributeName, value) {
  if (!SAFE_IMAGE_DATA_URL.test(value)) return false;
  const localName = element.localName.toLowerCase();
  return attributeName === 'src' &&
    (localName === 'img' || localName === 'source');
}

// Message and ExtBlock CSS keeps working while message scripts are disabled;
// the declaration-level policy lives in css_sanitizer.js.
function sanitizeStyleAttribute(element) {
  sanitizeStyleDeclaration(element.style);
  if (!element.getAttribute('style')) element.removeAttribute('style');
}

function sanitizeStyleElement(element, cssScope) {
  const safe = sanitizeCssText(element.textContent, cssScope);
  if (!safe) {
    element.remove();
    return;
  }
  // media/type/nonce/blocking attributes carry no styling the block needs.
  for (const attribute of Array.from(element.attributes)) {
    element.removeAttribute(attribute.name);
  }
  element.textContent = safe;
}

function sanitizeHtml(html, cssScope) {
  const template = document.createElement('template');
  template.innerHTML = String(html == null ? '' : html);

  for (const element of Array.from(template.content.querySelectorAll('*'))) {
    const localName = element.localName.toLowerCase();
    if (BLOCKED_ELEMENTS.has(localName)) {
      element.remove();
      continue;
    }
    if (localName === 'style') {
      sanitizeStyleElement(element, cssScope);
      continue;
    }
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith('on') || name === 'srcdoc') {
        element.removeAttribute(attribute.name);
        continue;
      }
      if (name === 'style') {
        sanitizeStyleAttribute(element);
        continue;
      }
      if (!URL_ATTRIBUTES.has(name)) continue;
      const value = attribute.value.trim();
      const compact = value.replace(/[\u0000-\u0020]+/g, '').toLowerCase();
      if (compact.startsWith('javascript:') || compact.startsWith('vbscript:') ||
          (compact.startsWith('data:') &&
            !isSafeDataUrl(element, name, value))) {
        element.removeAttribute(attribute.name);
      }
    }
    if (element.hasAttribute('srcset')) {
      const candidates = element.getAttribute('srcset').split(',');
      const unsafe = candidates.some(candidate => {
        const value = candidate.trim().split(/\s+/)[0] || '';
        const compact = value.replace(/[\u0000-\u0020]+/g, '').toLowerCase();
        return compact.startsWith('javascript:') ||
          compact.startsWith('vbscript:') ||
          (compact.startsWith('data:') && !SAFE_IMAGE_DATA_URL.test(value));
      });
      if (unsafe) element.removeAttribute('srcset');
    }
  }

  return template.innerHTML;
}

// The elements a message may not carry while script execution is off. Each one
// hosts a document (or plugin) that runs code of its own, which is the one
// thing the disabled mode has to prevent. Everything that merely *renders* —
// `<form>`, SVG animation, `<use>`, `<link rel=stylesheet>`, custom elements —
// stays, because the toggle is not a markup policy.
const MESSAGE_CODE_ELEMENTS = new Set(['script', 'iframe', 'object', 'embed']);

// `javascript:` and `vbscript:` run on navigation; a non-image `data:` URL can
// carry a document that does the same. `data:image/…` is a picture, so it is
// left alone like the rest of the markup.
function isMessageCodeUrl(compact) {
  return compact.startsWith('javascript:') ||
    compact.startsWith('vbscript:') ||
    (compact.startsWith('data:') && !compact.startsWith('data:image/'));
}

// Strips the code out of message HTML and touches nothing else: no element is
// dropped for how it looks, and `<style>` / `style="…"` are left byte-identical
// so the message renders exactly as written.
function stripMessageCode(html) {
  const template = document.createElement('template');
  template.innerHTML = String(html == null ? '' : html);

  for (const element of Array.from(template.content.querySelectorAll('*'))) {
    if (MESSAGE_CODE_ELEMENTS.has(element.localName.toLowerCase())) {
      element.remove();
      continue;
    }
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith('on') || name === 'srcdoc') {
        element.removeAttribute(attribute.name);
        continue;
      }
      if (!URL_ATTRIBUTES.has(name)) continue;
      const compact = attribute.value
        .trim()
        .replace(/[\u0000-\u0020]+/g, '')
        .toLowerCase();
      if (isMessageCodeUrl(compact)) element.removeAttribute(attribute.name);
    }
  }

  return template.innerHTML;
}

// [allowScripts] mirrors the app's message-script setting. With execution on
// the message HTML is inserted verbatim; with it off the code is removed and
// the markup and CSS are still inserted verbatim.
export function sanitizeMessageHtml(html, { allowScripts = false } = {}) {
  if (allowScripts) return String(html == null ? '' : html);
  return stripMessageCode(html);
}

export function sanitizeExtBlockHtml(html) {
  return sanitizeHtml(html, EXT_BLOCK_CSS_SCOPE);
}
