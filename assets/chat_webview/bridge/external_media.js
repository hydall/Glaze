// The "Allow external media" setting, off: message and ExtBlock HTML may not
// load anything from the network.
//
// Same idea as SillyTavern's "Forbid external media": a remote `src`, a remote
// `url()` in CSS, a remote `@import` or `@font-face` is dropped before the
// markup is inserted, so the browser never makes the request. Embedded media
// (`data:`, `blob:`) and Glaze's own media — served from the page's origin,
// the loopback file server or `file://` — keep working.

import { withParsedSheet } from './css_sanitizer.js';

/** Hosts that serve Glaze's own pages and media, never a third party. */
const LOCAL_HOSTS = new Set([
  'localhost', '127.0.0.1', '[::1]', 'appassets.androidplatform.net',
]);

const NETWORK_PROTOCOLS = new Set(['http:', 'https:', 'ws:', 'wss:']);

/** Attributes whose URL the browser fetches on its own, without a click. */
const MEDIA_ATTRIBUTES = ['src', 'poster', 'background', 'data'];

/** SVG references that load a resource (`<a href>` is a link, not a load). */
const SVG_REFERENCE_ELEMENTS = new Set(['image', 'use', 'feimage']);

/** True when [value] would be fetched from a host other than Glaze itself. */
export function isExternalUrl(value) {
  const text = String(value == null ? '' : value).trim();
  // Only absolute or protocol-relative URLs can leave the app: a relative one
  // resolves against the page, which Glaze serves itself.
  if (!/^(?:[a-z][a-z0-9+.-]*:)?\/\//i.test(text)) return false;
  let url;
  try {
    url = new URL(text, document.baseURI);
  } catch (_) {
    return false;
  }
  if (!NETWORK_PROTOCOLS.has(url.protocol)) return false;
  const host = url.hostname.toLowerCase();
  if (LOCAL_HOSTS.has(host) || host === location.hostname.toLowerCase()) return false;
  return true;
}

// Every place in a CSS value a URL can sit: `url(…)` and the bare strings
// `image-set()` / `@import "…"` accept.
const CSS_URL = /url\(\s*(["']?)([^"')]*)\1\s*\)|(["'])((?:[a-z][a-z0-9+.-]*:)?\/\/[^"']*)\3/gi;

/** True when the CSS text [value] references an external URL. */
export function hasExternalCssUrl(value) {
  const text = String(value == null ? '' : value);
  if (!text.includes('//')) return false;
  CSS_URL.lastIndex = 0;
  let match;
  while ((match = CSS_URL.exec(text)) !== null) {
    if (isExternalUrl(match[2] ?? match[4])) return true;
  }
  return false;
}

/** Drops every declaration of [style] that would load an external URL. */
function stripDeclarations(style) {
  if (!style || typeof style.item !== 'function') return;
  const external = [];
  for (let i = 0; i < style.length; i++) {
    const property = style.item(i);
    if (hasExternalCssUrl(style.getPropertyValue(property))) external.push(property);
  }
  for (const property of external) style.removeProperty(property);
}

function stripRules(owner) {
  const rules = owner.cssRules;
  if (!rules) return;
  for (let i = rules.length - 1; i >= 0; i--) {
    const rule = rules[i];
    if (typeof CSSImportRule === 'function' && rule instanceof CSSImportRule) {
      if (isExternalUrl(rule.href)) owner.deleteRule(i);
      continue;
    }
    stripDeclarations(rule.style);
    stripRules(rule);
  }
}

/**
 * [css] without anything that loads an external URL. A sheet with no external
 * URL comes back byte-identical; one that has them is re-serialised by the
 * browser's own parser, so an escaped `\75 rl(…)` cannot slip past.
 */
export function stripExternalCss(css) {
  const source = String(css == null ? '' : css);
  if (!hasExternalCssUrl(source) && !source.includes('\\')) return source;
  const stripped = withParsedSheet(source, (sheet) => {
    stripRules(sheet);
    return Array.from(sheet.cssRules).map((rule) => rule.cssText).join('\n');
  });
  return stripped ?? '';
}

function stripSrcset(element) {
  const srcset = element.getAttribute('srcset');
  if (srcset == null) return;
  const kept = srcset.split(',').map((candidate) => candidate.trim()).filter((candidate) => {
    const url = candidate.split(/\s+/)[0] || '';
    return candidate && !isExternalUrl(url);
  });
  if (kept.length) {
    element.setAttribute('srcset', kept.join(', '));
  } else {
    element.removeAttribute('srcset');
  }
}

/**
 * Removes every external load from the parsed markup under [container], in
 * place: media sources, stylesheet links, SVG references, and external URLs in
 * `<style>` blocks and `style="…"` attributes.
 */
export function stripExternalMedia(container) {
  for (const element of Array.from(container.querySelectorAll('*'))) {
    const localName = element.localName.toLowerCase();
    if (localName === 'link') {
      if (isExternalUrl(element.getAttribute('href'))) element.remove();
      continue;
    }
    if (localName === 'style') {
      const css = element.textContent;
      const stripped = stripExternalCss(css);
      if (stripped !== css) element.textContent = stripped;
      continue;
    }
    for (const name of MEDIA_ATTRIBUTES) {
      if (isExternalUrl(element.getAttribute(name))) element.removeAttribute(name);
    }
    stripSrcset(element);
    if (SVG_REFERENCE_ELEMENTS.has(localName)) {
      for (const name of ['href', 'xlink:href']) {
        if (isExternalUrl(element.getAttribute(name))) element.removeAttribute(name);
      }
    }
    if (element.hasAttribute('style') && hasExternalCssUrl(element.getAttribute('style'))) {
      stripDeclarations(element.style);
      if (!element.getAttribute('style')) element.removeAttribute('style');
    }
  }
}
