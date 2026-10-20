// Theme layouts: the HTML templates a theme rearranges the chat with.
//
// A theme file is shared like any other file, so what it carries is data, not
// code. A template is parsed here, by a parser of its own (no innerHTML, no
// DOMParser), into a tree of allowed elements and attributes; everything else
// is dropped. There is no script, no event handler and no link: what a
// template can do is show data and lay out the pieces the app hands it.
//
//   {{ expr }}              text, or part of an attribute value
//   g-if / g-else-if / g-else="expr"
//   g-each="list" g-as="item"   repeats the element; `index` is the position
//   <g-part name="…">       where one of the app's own pieces goes
//   <g-icon name="send">    a named glyph; value="{{icon}}" draws a data icon
//   g-action="…"            a tap on it does one of the surface's actions
//
// Expressions are paths (`swipe.total`), string and number literals, `!`,
// `== != < <= > >=`, `&& ||` and `a ? b : c`.
//
// Nothing a template shows may reach the network: an image source is either
// a data: URL written in the template or a bare path to a URL the app itself
// provides (an avatar), and a style can only load data: URLs. A theme thus
// cannot send what it is shown anywhere.
//
// Every DOM call goes through ./safe.js, so the same views can live in the
// chrome's closed shadow root.

import * as S from './safe.js';
import { ICON } from './icons.js';
import { drawIcon } from './ui.js';

const MAX_SOURCE = 128 * 1024;
const MAX_DEPTH = 64;
const MAX_ITEMS = 500;

const own = (o, k) => o != null && typeof o === 'object' && S.hasOwn(o, k);

/* ---------- Allowed markup ---------- */

const HTML_TAGS = setOf(
  'div span p b i em strong u s small sup sub br hr ul ol li img button label ' +
  'h1 h2 h3 h4 h5 h6 header footer section article aside nav main figure figcaption ' +
  'blockquote pre code mark time abbr q cite del ins table thead tbody tr td th caption ' +
  'g-part g-icon',
);
const SVG_TAGS = setOf(
  'svg g path circle ellipse rect line polyline polygon defs linearGradient radialGradient ' +
  'stop clipPath mask pattern title desc',
);
// Dropped with everything inside them; their content is not markup.
const RAW_TAGS = setOf('script style textarea title xmp iframe noembed noframes noscript plaintext template');
const VOID_TAGS = setOf('br hr img wbr g-part g-icon');

const GLOBAL_ATTRS = setOf('class title role dir lang hidden style');
const TAG_ATTRS = {
  img: setOf('src alt width height loading draggable decoding'),
  'g-part': setOf('name'),
  'g-icon': setOf('name value size'),
  button: setOf('type disabled'),
  td: setOf('colspan rowspan'),
  th: setOf('colspan rowspan'),
  time: setOf('datetime'),
};
const SVG_ATTRS = setOf(
  'viewBox d fill stroke stroke-width stroke-linecap stroke-linejoin stroke-dasharray ' +
  'stroke-dashoffset stroke-opacity fill-opacity fill-rule clip-rule opacity transform ' +
  'cx cy r rx ry x y x1 y1 x2 y2 width height points offset stop-color stop-opacity ' +
  'gradientUnits gradientTransform spreadMethod preserveAspectRatio xmlns ' +
  'clip-path mask patternUnits patternContentUnits',
);
const DIRECTIVES = setOf('g-if g-else-if g-else g-each g-as g-action');

function setOf(words) {
  const out = Object.create(null);
  const list = words.split(/\s+/);
  for (let i = 0; i < list.length; i++) if (list[i]) out[list[i]] = true;
  return out;
}

function attrAllowed(tag, svg, name) {
  if (GLOBAL_ATTRS[name] || DIRECTIVES[name]) return true;
  if (/^(aria|data)-[a-z0-9-]+$/.test(name)) return true;
  if (svg) return !!SVG_ATTRS[name];
  const own = TAG_ATTRS[tag];
  return !!(own && own[name]);
}

/** A data: image, the only URL a template may write itself. */
function isDataImage(value) {
  return /^\s*data:image\/(png|jpe?g|gif|webp|avif|bmp|svg\+xml)[;,]/i.test(value);
}

/** A URL the app handed over as data: a picture of its own, never a page. */
function isAppUrl(value) {
  return /^(data:image\/|blob:|file:|https?:|glaze:)/i.test(value);
}

// A style may load data: URLs and nothing else. Escapes are refused outright:
// `u\72l(` is a url( too.
const CSS_LOADERS = /(image-set|cross-fade|element|src|image)\s*\(|@/i;
function styleOk(value, bound) {
  if (value.indexOf('\\') >= 0) return false;
  if (CSS_LOADERS.test(value)) return false;
  const re = /url\s*\(\s*(['"]?)/gi;
  let m;
  while ((m = re.exec(value))) {
    if (bound) return false;
    if (!isDataImage(value.slice(m.index + m[0].length))) return false;
  }
  return true;
}

const MAX_CSS = 256 * 1024;
// A stylesheet may load data: images, and nothing else; rules that reach the
// network or run code are dropped whole.
const CSS_FORBIDDEN_AT = /@(import|charset|namespace)\b/i;
const CSS_FORBIDDEN = /(expression\s*\(|-moz-binding|behavior\s*:|javascript\s*:)/i;

/**
 * Cleans a theme stylesheet: `url()` only for data: images, no `@import`, no
 * escapes (a `u\72l(` is a url() too), nothing that runs code. Rules with any
 * of that are dropped; the rest is returned as it was.
 */
export function sanitizeCss(css) {
  if (typeof css !== 'string' || !css) return '';
  const src = css.length > MAX_CSS ? css.slice(0, MAX_CSS) : css;
  if (src.indexOf('\\') < 0 && src.indexOf('url') < 0 && src.indexOf('@') < 0 &&
      !CSS_FORBIDDEN.test(src)) return src;
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    // Copy up to the next { or ; at this level; @-rules ending in ; are kept
    // unless forbidden.
    const start = i;
    let j = i;
    let paren = 0;
    for (; j < n; j++) {
      const c = src[j];
      if (c === '"' || c === "'") {
        const q = c;
        j++;
        while (j < n && src[j] !== q) {
          if (src[j] === '\\') j++;
          j++;
        }
        continue;
      }
      if (c === '/' && src[j + 1] === '*') {
        const end = src.indexOf('*/', j + 2);
        j = end < 0 ? n : end + 1;
        continue;
      }
      // A `;` inside `url(...)` is part of a data: URL, not the rule's end.
      if (c === '(') paren++;
      else if (c === ')') paren = paren > 0 ? paren - 1 : 0;
      else if (c === '{' && paren === 0) break;
      else if (c === ';' && paren === 0) break;
    }
    if (j >= n) {
      const tail = src.slice(start);
      if (tail.trim() && !badCss(tail)) out += tail;
      break;
    }
    if (src[j] === ';') {
      const stmt = src.slice(start, j + 1);
      if (!badCss(stmt)) out += stmt;
      i = j + 1;
      continue;
    }
    // A block: find its matching brace, quotes and comments included.
    let k = j + 1;
    let d = 1;
    while (k < n && d > 0) {
      const c = src[k];
      if (c === '"' || c === "'") {
        const q = c;
        k++;
        while (k < n && src[k] !== q) {
          if (src[k] === '\\') k++;
          k++;
        }
      } else if (c === '/' && src[k + 1] === '*') {
        const end = src.indexOf('*/', k + 2);
        k = end < 0 ? n : end + 1;
      } else if (c === '{') d++;
      else if (c === '}') d--;
      k++;
    }
    const rule = src.slice(start, k);
    const head = src.slice(start, j);
    if (head.trim()[0] === '@') {
      // A group rule (@media, @supports…) holds rules: clean inside; others
      // (@font-face, @keyframes…) are kept only if they load nothing.
      if (!badCss(rule) && /@(media|supports|layer|container|scope)\b/i.test(head)) {
        const inner = sanitizeCss(src.slice(j + 1, k - 1));
        out += head + '{' + inner + '}';
      } else if (!badCss(rule)) {
        out += rule;
      }
    } else if (!badCss(rule)) {
      out += rule;
    }
    i = k;
  }
  return out;
}

function badCss(text) {
  if (text.indexOf('\\') >= 0) return true;
  if (CSS_FORBIDDEN_AT.test(text)) return true;
  if (CSS_FORBIDDEN.test(text)) return true;
  const re = /url\s*\(\s*(['"]?)/gi;
  let m;
  while ((m = re.exec(text))) {
    if (!isDataImage(text.slice(m.index + m[0].length))) return true;
  }
  return false;
}

/* ---------- Tokenizer ---------- */

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0', '#39': "'" };

function decodeEntities(s) {
  if (s.indexOf('&') < 0) return s;
  return s.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+[0-9]*);/gi, (all, name) => {
    if (name[0] === '#') {
      const code = name[1] === 'x' || name[1] === 'X'
        ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      if (!(code > 0 && code < 0x110000) || (code >= 0xd800 && code <= 0xdfff)) return '';
      return String.fromCodePoint(code);
    }
    const v = ENTITIES[name.toLowerCase()];
    return v === undefined ? all : v;
  });
}

/** Parses [src] into a tree: `{ tag, svg, attrs: [[name, value]], kids }` and text strings. */
function parseHtml(src, warn) {
  const root = { tag: '#root', svg: false, attrs: [], kids: [] };
  const stack = [root];
  let i = 0;
  const n = src.length;
  const top = () => stack[stack.length - 1];

  while (i < n) {
    const lt = src.indexOf('<', i);
    if (lt < 0) {
      top().kids.push(decodeEntities(src.slice(i)));
      break;
    }
    if (lt > i) top().kids.push(decodeEntities(src.slice(i, lt)));
    i = lt;
    if (src.startsWith('<!--', i)) {
      const end = src.indexOf('-->', i + 4);
      i = end < 0 ? n : end + 3;
      continue;
    }
    if (src[i + 1] === '!' || src[i + 1] === '?') {
      const end = src.indexOf('>', i);
      i = end < 0 ? n : end + 1;
      continue;
    }
    if (src[i + 1] === '/') {
      const m = /^<\/\s*([A-Za-z][\w:-]*)\s*>/.exec(src.slice(i, i + 256));
      if (!m) {
        top().kids.push('<');
        i++;
        continue;
      }
      i += m[0].length;
      const name = m[1];
      for (let k = stack.length - 1; k > 0; k--) {
        const t = stack[k].tag;
        if (t === name || t.toLowerCase() === name.toLowerCase()) {
          stack.length = k;
          break;
        }
      }
      continue;
    }
    const m = /^<([A-Za-z][\w:-]*)/.exec(src.slice(i, i + 256));
    if (!m) {
      top().kids.push('<');
      i++;
      continue;
    }
    i += m[0].length;
    const attrs = [];
    let selfClose = false;
    for (;;) {
      const ws = /^[\s]*/.exec(src.slice(i, i + 4096))[0].length;
      i += ws;
      if (i >= n) break;
      if (src[i] === '>') { i++; break; }
      if (src.startsWith('/>', i)) { selfClose = true; i += 2; break; }
      if (src[i] === '/') { i++; continue; }
      const am = /^([^\s/>=]+)/.exec(src.slice(i, i + 256));
      if (!am) { i++; continue; }
      i += am[0].length;
      let value = '';
      const eq = /^\s*=\s*/.exec(src.slice(i, i + 64));
      if (eq) {
        i += eq[0].length;
        const q = src[i];
        if (q === '"' || q === "'") {
          const end = src.indexOf(q, i + 1);
          value = src.slice(i + 1, end < 0 ? n : end);
          i = end < 0 ? n : end + 1;
        } else {
          const um = /^[^\s>]*/.exec(src.slice(i, i + 4096))[0];
          value = um;
          i += um.length;
        }
      }
      attrs.push([am[1], decodeEntities(value)]);
    }
    const parent = top();
    const svg = parent.svg || m[1].toLowerCase() === 'svg';
    const tag = svg ? m[1] : m[1].toLowerCase();
    const lower = tag.toLowerCase();
    if (RAW_TAGS[lower] && !(svg && SVG_TAGS[tag])) {
      const close = new RegExp(`</\\s*${lower}\\s*>`, 'i');
      const rest = src.slice(i);
      const cm = close.exec(rest);
      i = cm ? i + cm.index + cm[0].length : n;
      warn(`<${lower}> is not allowed`);
      continue;
    }
    const node = { tag, svg, attrs, kids: [] };
    parent.kids.push(node);
    if (!selfClose && !(VOID_TAGS[lower] && !svg)) {
      if (stack.length > MAX_DEPTH) {
        warn('nested too deep');
        node.kids = null;
        continue;
      }
      stack.push(node);
    }
  }
  return root.kids;
}

/* ---------- Expressions ---------- */

function tokenize(src) {
  const out = [];
  const re = /\s*(?:(\d+(?:\.\d+)?)|('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)|(==|!=|<=|>=|&&|\|\||[!<>?:()]))/y;
  let i = 0;
  while (i < src.length) {
    if (/^\s*$/.test(src.slice(i))) break;
    re.lastIndex = i;
    const m = re.exec(src);
    if (!m) throw new Error(`bad expression: ${src}`);
    i = re.lastIndex;
    if (m[1] !== undefined) out.push({ k: 'num', v: parseFloat(m[1]) });
    else if (m[2] !== undefined) out.push({ k: 'str', v: m[2].slice(1, -1).replace(/\\(.)/g, '$1') });
    else if (m[3] !== undefined) {
      if (m[3] === 'true' || m[3] === 'false') out.push({ k: 'lit', v: m[3] === 'true' });
      else if (m[3] === 'null') out.push({ k: 'lit', v: null });
      else out.push({ k: 'path', v: m[3].split('.') });
    } else out.push({ k: 'op', v: m[4] });
  }
  return out;
}

/** Compiles [src] to `{ fn(scope), path }`; `path` is set when it is a bare path. */
function compileExpr(src) {
  const toks = tokenize(src);
  let p = 0;
  const peek = () => toks[p];
  const isOp = (v) => toks[p] && toks[p].k === 'op' && toks[p].v === v;
  const eat = (v) => {
    if (!isOp(v)) throw new Error(`expected ${v} in: ${src}`);
    p++;
  };
  function primary() {
    const t = peek();
    if (!t) throw new Error(`unexpected end: ${src}`);
    p++;
    if (t.k === 'num' || t.k === 'str' || t.k === 'lit') return () => t.v;
    if (t.k === 'path') return (scope) => lookup(scope, t.v);
    if (t.k === 'op' && t.v === '(') {
      const e = ternary();
      eat(')');
      return e;
    }
    if (t.k === 'op' && t.v === '!') {
      const e = unary();
      return (s) => !e(s);
    }
    throw new Error(`unexpected ${t.v} in: ${src}`);
  }
  function unary() { return primary(); }
  function compare() {
    let left = unary();
    while (peek() && peek().k === 'op' && /^(==|!=|<=|>=|<|>)$/.test(peek().v)) {
      const op = toks[p++].v;
      const l = left;
      const r = unary();
      left = (s) => {
        const a = l(s), b = r(s);
        switch (op) {
          // Loose on purpose: data from the app is often a number written as text.
          case '==': return a == b; // eslint-disable-line eqeqeq
          case '!=': return a != b; // eslint-disable-line eqeqeq
          case '<': return a < b;
          case '>': return a > b;
          case '<=': return a <= b;
          default: return a >= b;
        }
      };
    }
    return left;
  }
  function and() {
    let left = compare();
    while (isOp('&&')) {
      p++;
      const l = left, r = compare();
      left = (s) => l(s) && r(s);
    }
    return left;
  }
  function or() {
    let left = and();
    while (isOp('||')) {
      p++;
      const l = left, r = and();
      left = (s) => l(s) || r(s);
    }
    return left;
  }
  function ternary() {
    const cond = or();
    if (!isOp('?')) return cond;
    p++;
    const a = ternary();
    eat(':');
    const b = ternary();
    return (s) => (cond(s) ? a(s) : b(s));
  }
  const fn = ternary();
  if (p !== toks.length) throw new Error(`unexpected ${toks[p].v} in: ${src}`);
  const path = toks.length === 1 && toks[0].k === 'path' ? toks[0].v : null;
  return { fn, path };
}

function lookup(scope, path) {
  if (!S.isArray(path)) return undefined;
  let s = scope;
  let value;
  let found = false;
  while (s) {
    if (own(s.vars, path[0])) {
      value = s.vars[path[0]];
      found = true;
      break;
    }
    s = s.parent;
  }
  if (!found) return undefined;
  for (let i = 1; i < path.length; i++) {
    if (!own(value, path[i]) && !(S.isArray(value) && path[i] === 'length')) return undefined;
    value = value[path[i]];
  }
  return value;
}

/** Splits `a {{x}} b` into ['a ', expr, ' b']; null when there is nothing to bind. */
function splitMustache(s) {
  if (s.indexOf('{{') < 0) return null;
  const out = [];
  const re = /\{\{([\s\S]*?)\}\}/g;
  let last = 0;
  let m;
  while ((m = re.exec(s))) {
    if (m.index > last) out.push(s.slice(last, m.index));
    out.push(compileExpr(m[1]));
    last = re.lastIndex;
  }
  if (last < s.length) out.push(s.slice(last));
  return out;
}

function show(v) {
  if (v === undefined || v === null || v === false) return '';
  if (typeof v === 'number') return S.numberIsFinite(v) ? S.stringFn(v) : '';
  if (typeof v === 'object') return '';
  return S.stringFn(v);
}

function evalParts(parts, scope) {
  let out = '';
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    out += typeof p === 'string' ? p : show(p.fn(scope));
  }
  return out;
}

/* ---------- Compiling ---------- */

/**
 * Compiles a template. Returns `{ nodes, errors }`; what could not be used is
 * dropped and named in [errors], the rest still renders.
 */
export function compile(src) {
  const errors = [];
  const warn = (m) => { if (errors.length < 20) errors.push(m); };
  if (typeof src !== 'string' || !src.trim()) return { nodes: [], errors, empty: true };
  if (src.length > MAX_SOURCE) {
    warn('template too large');
    return { nodes: [], errors, empty: true };
  }
  const tree = parseHtml(src, warn);
  return { nodes: compileKids(tree, warn), errors, empty: false };
}

function compileKids(kids, warn) {
  const out = [];
  if (!kids) return out;
  for (let i = 0; i < kids.length; i++) {
    const k = kids[i];
    if (typeof k === 'string') {
      try {
        const parts = splitMustache(k);
        out.push(parts ? { text: null, parts } : { text: k });
      } catch (e) {
        warn(S.stringFn(e.message));
      }
      continue;
    }
    const node = compileElement(k, warn);
    if (!node) continue;
    // g-else / g-else-if join the g-if before them (whitespace between is fine).
    if (node.elseOf) {
      let j = out.length - 1;
      while (j >= 0 && out[j].text != null && !out[j].text.trim()) j--;
      const prev = j >= 0 ? out[j] : null;
      if (prev && prev.branches && !prev.closed) {
        out.length = j + 1;
        prev.branches.push({ cond: node.elseOf === true ? null : node.elseOf, el: node.el });
        if (node.elseOf === true) prev.closed = true;
      } else {
        warn('g-else without g-if');
      }
      continue;
    }
    out.push(node);
  }
  return out;
}

function compileElement(k, warn) {
  const lower = k.tag.toLowerCase();
  if (k.svg ? !SVG_TAGS[k.tag] : !HTML_TAGS[lower]) {
    warn(`<${k.tag}> is not allowed`);
    return null;
  }
  const el = { tag: k.tag, svg: k.svg, attrs: [], kids: null, action: null, icon: null, part: null };
  let ifExpr = null;
  let elseOf = null;
  let each = null;
  let as = 'item';
  for (let i = 0; i < k.attrs.length; i++) {
    const name = k.attrs[i][0];
    const value = k.attrs[i][1];
    const lname = k.svg ? name : name.toLowerCase();
    if (!attrAllowed(lower, k.svg, lname)) {
      warn(`${lname} is not allowed on <${k.tag}>`);
      continue;
    }
    try {
      if (lname === 'g-if') ifExpr = compileExpr(value);
      else if (lname === 'g-else-if') elseOf = compileExpr(value);
      else if (lname === 'g-else') elseOf = true;
      else if (lname === 'g-each') each = compileExpr(value);
      else if (lname === 'g-as') as = /^[A-Za-z_$][\w$]*$/.test(value) ? value : 'item';
      else if (lname === 'g-action') el.action = value.trim();
      else if (lower === 'g-part' && lname === 'name') el.part = value.trim();
      else if (lower === 'g-icon' && lname === 'name') el.icon = { name: value.trim() };
      else if (lower === 'g-icon' && lname === 'value') el.icon = { value: compileExpr(value.replace(/^\s*\{\{|\}\}\s*$/g, '')) };
      else if (lower === 'g-icon' && lname === 'size') el.size = S.mathMax(4, S.mathMin(128, parseFloat(value) || 20));
      else {
        const attr = compileAttr(lname, value, lower, warn);
        if (attr) el.attrs.push(attr);
      }
    } catch (e) {
      warn(S.stringFn(e.message));
    }
  }
  if (lower === 'g-part' && !el.part) {
    warn('<g-part> needs a name');
    return null;
  }
  el.kids = el.part || el.icon ? [] : compileKids(k.kids, warn);
  let node = { el };
  if (elseOf) return { elseOf, el: node };
  if (ifExpr) node = { branches: [{ cond: ifExpr, el: node }], closed: false };
  if (each) node = { each, as, body: node };
  return node;
}

function compileAttr(name, value, tag, warn) {
  const parts = splitMustache(value);
  if (name === 'src') {
    if (!parts) {
      if (!isDataImage(value)) {
        warn('src must be a data: image or {{a path}}');
        return null;
      }
      return { name, value };
    }
    // One bare path and nothing around it: the app's own URL, as it is. A
    // literal or anything joined to it could make it point anywhere.
    if (parts.length !== 1 || typeof parts[0] === 'string' || !parts[0].path) {
      warn('src can only be a data: image or a single {{path}}');
      return null;
    }
    return { name, parts, url: true };
  }
  if (name === 'style') {
    if (!parts && (!styleOk(value, false) || !sanitizeCss(value))) {
      warn('style can only load data: images');
      return null;
    }
    return parts ? { name, parts, style: true } : { name, value };
  }
  return parts ? { name, parts } : { name, value };
}

/* ---------- Views ---------- */

// The views may live in the chrome's shadow root while a message script has
// patched whatever it likes, so from here on nothing that holds a node goes
// through a method or a property someone else could have put on a prototype:
// lists and maps are prototype-less objects (S.dict), lookups are own-property
// only, and the last check on every tag and attribute name is made here, by
// hand, against tables built before any message ran.

const SAFE_ATTRS = (() => {
  const out = S.dict();
  const add = (table) => { for (const k in table) out[k] = true; };
  add(GLOBAL_ATTRS);
  add(SVG_ATTRS);
  for (const tag in TAG_ATTRS) add(TAG_ATTRS[tag]);
  return out;
})();

function attrNameSafe(name) {
  if (typeof name !== 'string') return false;
  if (SAFE_ATTRS[name] === true) return true;
  // data-* and aria-*: lower-case letters, digits and dashes after the prefix.
  const n = name.length;
  if (n < 6 || n > 64) return false;
  const pre = S.charCodeAt(name, 0) === 100 && S.charCodeAt(name, 1) === 97 && S.charCodeAt(name, 2) === 116 &&
    S.charCodeAt(name, 3) === 97 && S.charCodeAt(name, 4) === 45; // "data-"
  const aria = S.charCodeAt(name, 0) === 97 && S.charCodeAt(name, 1) === 114 && S.charCodeAt(name, 2) === 105 &&
    S.charCodeAt(name, 3) === 97 && S.charCodeAt(name, 4) === 45; // "aria-"
  if (!pre && !aria) return false;
  for (let i = 5; i < n; i++) {
    const c = S.charCodeAt(name, i);
    if (!((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c === 45)) return false;
  }
  return true;
}

function tagSafe(tag, svg) {
  if (typeof tag !== 'string') return false;
  return svg === true ? SVG_TAGS[tag] === true : HTML_TAGS[tag] === true;
}

function hooksOf(hooks) {
  const out = S.dict();
  if (hooks && typeof hooks === 'object') {
    if (S.hasOwn(hooks, 'action') && typeof hooks.action === 'function') out.action = hooks.action;
    if (S.hasOwn(hooks, 'icon') && typeof hooks.icon === 'function') out.icon = hooks.icon;
    if (S.hasOwn(hooks, 'rescue') && typeof hooks.rescue === 'function') out.rescue = hooks.rescue;
  }
  return out;
}

function scopeOf(vars, parent) {
  const s = S.dict();
  s.vars = vars;
  s.parent = parent;
  return s;
}

/**
 * Renders [tpl] with [data] into [parent] (before [before]). [hooks]:
 * `action(el, name, scope)` wires a g-action, `icon(box, spec, size)` draws one.
 * Returns a view: `update(data)`, `parts()` (name → placeholder element, the
 * ones on screen now), `destroy()`.
 */
export function mount(tpl, data, parent, before, hooks) {
  const scope = scopeOf(data || S.dict(), null);
  const hk = hooksOf(hooks);
  const start = S.createText('');
  const end = S.createText('');
  insert(parent, start, before || null);
  insert(parent, end, before || null);
  const block = renderList(tpl && S.hasOwn(tpl, 'nodes') ? tpl.nodes : null, scope, parent, end, hk);
  const view = S.dict();
  view.update = (next) => {
    scope.vars = next || S.dict();
    block.update();
  };
  view.parts = () => {
    const out = S.dict();
    block.collect(out);
    return out;
  };
  view.destroy = () => {
    block.destroy();
    remove(start);
    remove(end);
  };
  return view;
}

function insert(parent, node, before) {
  if (before) S.insertBefore(parent, node, before);
  else S.appendChild(parent, node);
}

function remove(node) {
  const p = S.getParentNode(node);
  if (p) S.removeChild(p, node);
}

function block(update, collect, destroy) {
  const b = S.dict();
  b.update = update;
  b.collect = collect;
  b.destroy = destroy;
  return b;
}

// A block is what one compiled node rendered: `update()`, `collect(parts)`,
// `destroy()`. Element blocks own their DOM node; if and each blocks own the
// blocks between their anchors.

function renderList(nodes, scope, parent, before, hooks) {
  const blocks = S.dict();
  let n = 0;
  const count = S.isArray(nodes) ? nodes.length : 0;
  for (let i = 0; i < count; i++) blocks[n++] = renderNode(nodes[i], scope, parent, before, hooks);
  return block(
    () => { for (let i = 0; i < n; i++) blocks[i].update(); },
    (out) => { for (let i = 0; i < n; i++) blocks[i].collect(out); },
    () => { for (let i = 0; i < n; i++) blocks[i].destroy(); },
  );
}

const NOOP = () => {};
const NOOP_BLOCK = block(NOOP, NOOP, NOOP);

function field(o, k) {
  return own(o, k) ? o[k] : undefined;
}

function renderNode(node, scope, parent, before, hooks) {
  if (!node || typeof node !== 'object') return NOOP_BLOCK;
  if (S.hasOwn(node, 'text')) return renderText(node, scope, parent, before);
  if (field(node, 'each')) return renderEach(node, scope, parent, before, hooks);
  if (field(node, 'branches')) return renderIf(node, scope, parent, before, hooks);
  if (field(node, 'el')) return renderElement(node.el, scope, parent, before, hooks);
  return NOOP_BLOCK;
}

function renderText(node, scope, parent, before) {
  const parts = field(node, 'parts');
  const t = S.createText(parts ? evalParts(parts, scope) : S.stringFn(field(node, 'text') || ''));
  insert(parent, t, before);
  let last = null;
  return block(
    () => {
      if (!parts) return;
      const v = evalParts(parts, scope);
      if (v !== last) {
        last = v;
        S.setTextContent(t, v);
      }
    },
    NOOP,
    () => remove(t),
  );
}

function renderElement(el, scope, parent, before, hooks) {
  const svg = field(el, 'svg') === true;
  const tag = field(el, 'tag');
  if (!tagSafe(tag, svg)) return NOOP_BLOCK;
  const dom = svg ? S.createSvg(tag) : S.createElement(tag);
  const attrs = field(el, 'attrs');
  const bound = S.dict();
  let nb = 0;
  const na = S.isArray(attrs) ? attrs.length : 0;
  for (let i = 0; i < na; i++) {
    const a = attrs[i];
    const name = field(a, 'name');
    if (!attrNameSafe(name)) continue;
    if (field(a, 'parts')) bound[nb++] = a;
    else S.setAttribute(dom, name, S.stringFn(field(a, 'value') || ''));
  }
  const action = field(el, 'action');
  if (typeof action === 'string' && action && hooks.action) {
    S.setAttribute(dom, 'data-g-action', action);
    hooks.action(dom, action, scope);
  }
  const lastValues = S.dict();
  const applyAttrs = () => {
    for (let i = 0; i < nb; i++) {
      const a = bound[i];
      const name = a.name;
      let v = evalParts(a.parts, scope);
      if (field(a, 'url') && !isAppUrl(v)) v = '';
      if (field(a, 'style') && !styleOk(v, true)) v = '';
      if (lastValues[name] === v) continue;
      lastValues[name] = v;
      if (v === '' && (name === 'src' || name === 'class' || name === 'style')) S.removeAttribute(dom, name);
      else S.setAttribute(dom, name, v);
    }
  };
  applyAttrs();

  const glyph = field(el, 'icon');
  const size = field(el, 'size') || 20;
  let iconKey = null;
  const drawGlyph = () => {
    if (!glyph) return;
    const named = field(glyph, 'name');
    let spec = null;
    if (typeof named === 'string') spec = S.hasOwn(ICON, named) ? ICON[named] : null;
    else if (field(glyph, 'value')) spec = glyph.value.fn(scope);
    if (!spec || typeof spec !== 'object') spec = null;
    const key = S.jsonStringify([spec, size]);
    if (key === iconKey) return;
    iconKey = key;
    const cls = S.getAttribute(dom, 'class');
    S.setAttribute(dom, 'class', cls && cls.indexOf('gc-icon') < 0 ? `gc-icon ${cls}` : cls || 'gc-icon');
    S.setStyle(dom, 'width', `${size}px`);
    S.setStyle(dom, 'height', `${size}px`);
    (hooks.icon || drawIcon)(dom, spec, size);
  };
  drawGlyph();

  const part = field(el, 'part');
  if (typeof part === 'string') S.setAttribute(dom, 'data-g-part', part);
  const kidNodes = field(el, 'kids');
  const kids = S.isArray(kidNodes) && kidNodes.length ? renderList(kidNodes, scope, dom, null, hooks) : NOOP_BLOCK;
  insert(parent, dom, before);
  return block(
    () => {
      applyAttrs();
      drawGlyph();
      kids.update();
    },
    (out) => {
      if (typeof part === 'string' && !out[part]) out[part] = dom;
      kids.collect(out);
    },
    () => {
      kids.destroy();
      remove(dom);
    },
  );
}

function renderIf(node, scope, parent, before, hooks) {
  const anchor = S.createText('');
  insert(parent, anchor, before);
  const branches = node.branches;
  const nbr = S.isArray(branches) ? branches.length : 0;
  let index = -2;
  let child = NOOP_BLOCK;
  const pick = () => {
    for (let i = 0; i < nbr; i++) {
      const cond = field(branches[i], 'cond');
      if (!cond || cond.fn(scope)) return i;
    }
    return -1;
  };
  const sync = () => {
    const next = pick();
    if (next === index) {
      child.update();
      return;
    }
    rescue(child, hooks);
    child.destroy();
    index = next;
    child = next < 0 ? NOOP_BLOCK : renderNode(field(branches[next], 'el'), scope, S.getParentNode(anchor), anchor, hooks);
  };
  sync();
  return block(
    sync,
    (out) => child.collect(out),
    () => {
      child.destroy();
      remove(anchor);
    },
  );
}

function renderEach(node, scope, parent, before, hooks) {
  const anchor = S.createText('');
  insert(parent, anchor, before);
  const as = typeof field(node, 'as') === 'string' ? node.as : 'item';
  const body = field(node, 'body');
  let items = S.dict();
  let n = 0;
  let key = null;
  const sync = () => {
    const list = node.each.fn(scope);
    const len = S.isArray(list) ? S.mathMin(list.length, MAX_ITEMS) : 0;
    if (len === key) {
      for (let i = 0; i < n; i++) {
        items[i].scope.vars = itemVars(as, list[i], i);
        items[i].block.update();
      }
      return;
    }
    for (let i = 0; i < n; i++) {
      rescue(items[i].block, hooks);
      items[i].block.destroy();
    }
    items = S.dict();
    n = 0;
    key = len;
    const host = S.getParentNode(anchor);
    for (let i = 0; i < len; i++) {
      const item = S.dict();
      item.scope = scopeOf(itemVars(as, list[i], i), scope);
      item.block = renderNode(body, item.scope, host, anchor, hooks);
      items[n++] = item;
    }
  };
  sync();
  return block(
    sync,
    (out) => { for (let i = 0; i < n; i++) items[i].block.collect(out); },
    () => {
      for (let i = 0; i < n; i++) items[i].block.destroy();
      n = 0;
      remove(anchor);
    },
  );
}

// Before a branch goes away, the app's pieces placed in it are taken out.
function rescue(child, hooks) {
  if (!hooks.rescue) return;
  const slots = S.dict();
  child.collect(slots);
  hooks.rescue(slots);
}

// An item's own fields are in scope bare as well as under its name, so a list
// of cards reads `{{label}}` as readily as `{{item.label}}`.
function itemVars(as, value, index) {
  const vars = S.dict();
  if (value && typeof value === 'object' && !S.isArray(value)) {
    for (const k in value) if (S.hasOwn(value, k)) vars[k] = value[k];
  }
  vars[as] = value;
  vars.index = index;
  return vars;
}

/* ---------- Arranging the app's pieces ---------- */

/**
 * Lays [pieces] (name → element) out the way [tpl] says, inside [container].
 * A piece the template does not place stays where it is when it is inside
 * one it does (the field inside the pill), and is otherwise kept out of sight
 * in [holder] rather than removed, so whatever updates it keeps finding it.
 * [homes] (name → element) is where such a piece goes back to.
 *
 * Returns `{ update(data), destroy() }`; destroy leaves the pieces in the
 * holder, for the caller to put back where they belong.
 */
export function arrange(tpl, data, container, pieces, holder, hooks, homes) {
  const parts = S.dict();
  for (const name in pieces) if (S.hasOwn(pieces, name) && pieces[name]) parts[name] = pieces[name];
  const home = S.dict();
  if (homes) for (const name in homes) if (S.hasOwn(homes, name) && homes[name]) home[name] = homes[name];
  const toHolder = (slots) => {
    for (const name in parts) {
      const piece = parts[name];
      if (slots[name] && S.getParentNode(piece) === slots[name]) S.appendChild(holder, piece);
    }
  };
  const hk = hooksOf(hooks);
  hk.rescue = toHolder;
  const view = mount(tpl, data, container, S.getParentNode(holder) === container ? holder : null, hk);

  // Whether [node] sits inside a piece that has a place of its own.
  const insidePlaced = (node, slots) => {
    let n = node;
    while (n && n !== container) {
      for (const name in parts) if (slots[name] && parts[name] === n) return true;
      n = S.getParentNode(n);
    }
    return false;
  };
  const place = () => {
    const slots = view.parts();
    for (const name in parts) {
      const piece = parts[name];
      const slot = slots[name];
      if (slot) {
        if (S.getParentNode(piece) !== slot) S.appendChild(slot, piece);
        continue;
      }
      const at = S.getParentNode(piece);
      if (at && at !== holder && insidePlaced(at, slots)) continue;
      const back = home[name];
      if (back && insidePlaced(back, slots)) S.appendChild(back, piece);
      else if (at !== holder) S.appendChild(holder, piece);
    }
  };
  place();
  const out = S.dict();
  out.update = (next) => {
    view.update(next);
    place();
  };
  out.destroy = () => {
    for (const name in parts) S.appendChild(holder, parts[name]);
    view.destroy();
  };
  return out;
}
