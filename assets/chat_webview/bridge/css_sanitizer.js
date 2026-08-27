// CSS policy shared by message HTML and ExtBlock HTML.
//
// Message scripts are off by default (see `allowMessageScripts`), but styling
// is not code execution: cards, presets and model replies routinely ship
// `<style>` blocks and inline `style=` attributes that carry the whole visual
// layout of a message. Dropping them left the "safe" rendering path unstyled,
// so CSS is kept alive here while JS stays disabled.
//
// Everything is parsed by the browser's own CSS parser — a constructed
// stylesheet, or an inert document that never renders — so escapes and comments
// are normalised for us and nothing slips past by writing `\75 rl(...)` or
// `ur/**/l(...)`. Only the re-serialised, filtered output reaches the caller.
//
// Rejected on purpose:
//   * any `url()` / `image-set()` — inline CSS never needs the network, and a
//     background image is a working beacon for untrusted content
//   * `@import` (network + rule injection), `@font-face`, `@page`, `@namespace`
//   * `expression()`, `behavior`, `-moz-binding` — legacy script vectors
//   * `position: fixed` — the only layout primitive that can cover the whole
//     WebView and impersonate app UI; relative/absolute/sticky stay allowed so
//     ordinary in-message layout keeps working

const BLOCKED_PROPERTIES = new Set([
  'behavior', '-moz-binding', 'binding', '-ms-behavior',
]);

const UNSAFE_CSS_VALUE =
  /(?:^|[^\w-])(?:url|image|image-set|-webkit-image-set|src|expression)\s*\(|(?:javascript|vbscript)\s*:/i;

// Inert parsing host. `createHTMLDocument` has no browsing context, so
// stylesheets are parsed but never applied and never fetch anything.
let parserDocument;

function getParserDocument() {
  if (parserDocument !== undefined) return parserDocument;
  try {
    parserDocument = document.implementation.createHTMLDocument('glaze-css');
  } catch (_) {
    parserDocument = null;
  }
  return parserDocument;
}

function isUnsafeValue(value) {
  return UNSAFE_CSS_VALUE.test(String(value || ''));
}

function isAllowedDeclaration(property, value) {
  const name = String(property || '').trim().toLowerCase();
  if (!name) return false;
  if (BLOCKED_PROPERTIES.has(name)) return false;
  const text = String(value || '').trim();
  if (!text) return false;
  if (isUnsafeValue(text)) return false;
  // Custom properties keep their raw token stream, so an escaped `\75 rl(…)`
  // would survive serialization and only turn into a fetch once some other
  // declaration resolves it through var(). Anything escaped is rejected.
  if (name.startsWith('--') && text.includes('\\')) return false;
  if (name === 'position' && /\bfixed\b/i.test(text)) return false;
  return true;
}

// Drops every unsafe declaration from a live [CSSStyleDeclaration] in place.
// Used for `style="…"` attributes, which the browser has already parsed.
export function sanitizeStyleDeclaration(style) {
  if (!style || typeof style.item !== 'function') return;
  const blocked = [];
  for (let i = 0; i < style.length; i++) {
    const property = style.item(i);
    if (!isAllowedDeclaration(property, style.getPropertyValue(property))) {
      blocked.push(property);
    }
  }
  for (const property of blocked) style.removeProperty(property);
}

function serializeDeclarations(style) {
  if (!style || typeof style.item !== 'function') return '';
  const parts = [];
  for (let i = 0; i < style.length; i++) {
    const property = style.item(i);
    const value = style.getPropertyValue(property);
    if (!isAllowedDeclaration(property, value)) continue;
    const priority = style.getPropertyPriority(property);
    parts.push(`${property}: ${value}${priority ? ` !${priority}` : ''};`);
  }
  return parts.join(' ');
}

// Splits a selector list on top-level commas only, so `:is(a, b)` survives.
function splitSelectorList(selectorText) {
  const parts = [];
  let depth = 0;
  let quote = '';
  let current = '';
  for (const char of String(selectorText || '')) {
    if (quote) {
      current += char;
      if (char === quote) quote = '';
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      current += char;
      continue;
    }
    if (char === '(' || char === '[') depth++;
    if (char === ')' || char === ']') depth--;
    if (char === ',' && depth <= 0) {
      parts.push(current);
      current = '';
      continue;
    }
    current += char;
  }
  parts.push(current);
  return parts.map(part => part.trim()).filter(Boolean);
}

// Rewrites a selector list so every selector only matches inside [scope].
// Used for ExtBlock CSS, which lands in the light DOM and would otherwise
// restyle the whole app. Message CSS needs no scope: it is written into the
// message's shadow root, which scopes it already.
function scopeSelector(selectorText, scope) {
  const selectors = splitSelectorList(selectorText);
  if (!selectors.length) return '';
  if (!scope) return selectors.join(', ');
  return selectors.map(selector => `${scope} ${selector}`).join(', ');
}

function isInstanceOf(rule, constructorName) {
  const ctor = typeof window !== 'undefined' ? window[constructorName] : undefined;
  return typeof ctor === 'function' && rule instanceof ctor;
}

function groupPrelude(rule) {
  const cssText = String(rule.cssText || '');
  const brace = cssText.indexOf('{');
  if (brace <= 0) return '';
  const prelude = cssText.slice(0, brace).trim();
  return prelude.startsWith('@') ? prelude : '';
}

function serializeRule(rule, scope) {
  if (!rule) return '';
  if (isInstanceOf(rule, 'CSSStyleRule')) {
    const selector = scopeSelector(rule.selectorText, scope);
    if (!selector) return '';
    // Nested rules (`&`) resolve against the already-scoped parent selector,
    // so they are serialized as-is.
    const body = [
      serializeDeclarations(rule.style),
      serializeRules(rule.cssRules, ''),
    ].filter(Boolean).join(' ');
    return body ? `${selector} { ${body} }` : '';
  }
  if (isInstanceOf(rule, 'CSSKeyframesRule')) {
    const frames = Array.from(rule.cssRules || [])
      .map(frame => {
        const body = serializeDeclarations(frame.style);
        return body ? `${frame.keyText} { ${body} }` : '';
      })
      .filter(Boolean);
    if (!frames.length) return '';
    return `@keyframes ${rule.name} { ${frames.join(' ')} }`;
  }
  // @media / @supports / @container / @layer blocks.
  if (isInstanceOf(rule, 'CSSGroupingRule')) {
    const prelude = groupPrelude(rule);
    const inner = serializeRules(rule.cssRules, scope);
    return prelude && inner ? `${prelude} { ${inner} }` : '';
  }
  // @import, @font-face, @page, @namespace, @charset and anything unknown.
  return '';
}

function serializeRules(rules, scope) {
  const parts = [];
  for (const rule of Array.from(rules || [])) {
    const text = serializeRule(rule, scope);
    if (text) parts.push(text);
  }
  return parts.join('\n');
}

// Parses [css] with a constructed stylesheet — never attached to any document,
// and `replaceSync` drops @import for us. Returns null when the engine has no
// constructible stylesheets (older WebKit).
function withConstructedSheet(css, read) {
  if (typeof CSSStyleSheet !== 'function') return null;
  try {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(css);
    return read(sheet);
  } catch (_) {
    return null;
  }
}

// Fallback parser: an inert document has no browsing context, so its
// stylesheets are parsed but never applied and never fetch anything.
function withInertSheet(css, read) {
  const doc = getParserDocument();
  if (!doc) return null;
  const holder = doc.createElement('style');
  holder.textContent = css;
  doc.head.appendChild(holder);
  try {
    return holder.sheet ? read(holder.sheet) : null;
  } catch (_) {
    return null;
  } finally {
    holder.remove();
  }
}

// Parses [css] the safe way and hands the stylesheet to [read]: a constructed
// stylesheet when the engine has them, the inert document otherwise. Returns
// null when neither is available. Shared with the message CSS diagnostics,
// which reads a sheet without rewriting anything.
export function withParsedSheet(css, read) {
  return withConstructedSheet(css, read) ?? withInertSheet(css, read);
}

// A streaming reply re-renders its message on every chunk, and the `<style>`
// block it opens with is identical every time — parsing it once per chunk is
// pure waste, so results are memoized (FIFO, same shape as the formatter cache).
const CACHE_MAX_SIZE = 200;
const cache = new Map();

// Returns a filtered copy of [css], or `''` when nothing safe survives (which
// is also what a WebView without a usable CSS parser gets).
export function sanitizeCssText(css, scope = '') {
  const source = String(css == null ? '' : css);
  if (!source.trim()) return '';
  const key = `${scope}\u0000${source}`;
  if (cache.has(key)) return cache.get(key);

  const read = sheet => serializeRules(sheet.cssRules, scope);
  const result = withParsedSheet(source, read) || '';

  if (cache.size >= CACHE_MAX_SIZE) cache.delete(cache.keys().next().value);
  cache.set(key, result);
  return result;
}
