// The chat chrome — header, composer and drawer — drawn in the chat page.
//
// The chrome floats over the messages, so it lives in the page beside them:
// its glass then blurs the messages with an ordinary backdrop-filter, and the
// keyboard and the drawer move it with the content. It is still the app's own
// UI, though, and nothing a message carries may restyle it or drive it:
//
//  * It is drawn in a closed shadow root, so no message stylesheet and no
//    document query can reach its elements, and it reads only the `--gc-*`
//    properties it sets on its own root.
//  * Its host sits in the top layer (a manual popover), above anything a
//    message can position, with an `all: initial !important` inline style no
//    stylesheet can outrank. Where the page has no popovers it falls back to a
//    fixed layer on top.
//  * Flutter drives it through `window.__glazeChrome`, a frozen,
//    non-configurable object whose `apply` only obeys a key handed to Flutter
//    once, at page start, before any message has been rendered. It answers
//    with intents signed by a second key. Only trusted (real user) events
//    produce intents.
//  * Every DOM call it makes goes through primitives captured before the
//    page ran anything else (./safe.js), so a patched prototype in a message
//    script is never handed one of its nodes.

import * as S from './safe.js';
import { CHROME_CSS } from './style.js';
import { h, css, px, rgba, rectOf } from './ui.js';
import { createDrag } from './drag.js';
import { createHeader } from './header.js';
import { createComposer } from './composer.js';
import { createDrawer } from './drawer.js';
import { compile, sanitizeCss, themeValueEntries } from './template.js';

const KEY_IN = S.randomToken(32);
const KEY_OUT = S.randomToken(32);
// Not a secret: lets Flutter tell this page load from the next one, so the
// keys it was handed are kept for exactly as long as they are valid.
const PAGE_ID = S.randomToken(16);
let handedOut = false;

/* ---------- Host ---------- */

const HOST_TAG = `glaze-${S.randomToken(12)}`;
const HOST_STYLE = [
  'all:initial',
  'display:block',
  'position:fixed',
  'inset:0',
  'width:auto',
  'height:auto',
  'margin:0',
  'padding:0',
  'border:0',
  'background:transparent',
  'overflow:visible',
  'pointer-events:none',
  'z-index:2147483000',
  'opacity:1',
  'visibility:visible',
  'transform:none',
  'filter:none',
  'clip-path:none',
  'mask:none',
  'contain:none',
  'color-scheme:normal',
].map((rule) => `${rule} !important`).join(';');

// The plugin host (a classic script, so it ran before this module) puts
// plugins' chat panels in the top layer over the chrome; see
// plugins/plugin_host.js. Taken now, before any message could replace it —
// it is a non-configurable property anyway.
const pluginPanels = window.__glazePluginPanels || null;

const host = S.createElement(HOST_TAG);
S.setAttribute(host, 'style', HOST_STYLE);
const showPopoverRaw = S.showPopover;
const matchesRaw = S.matches;
if (showPopoverRaw) S.setAttribute(host, 'popover', 'manual');
const shadow = S.attachShadow(host, { mode: 'closed' });
const styleEl = S.createElement('style');
S.setTextContent(styleEl, CHROME_CSS);
S.appendChild(shadow, styleEl);
// A theme's own stylesheet for the chrome, after the chrome's own (applySkin).
const skinStyleEl = S.createElement('style');
S.appendChild(shadow, skinStyleEl);
const rootEl = h('div', 'gc');
S.appendChild(shadow, rootEl);

// A popover's ::backdrop is styled from the document, and by default it is a
// full-screen box that would take every tap. Ours is switched off.
const backdropStyle = S.createElement('style');
S.setTextContent(backdropStyle,
  `${HOST_TAG}::backdrop{display:none!important;pointer-events:none!important;background:none!important}`);
S.appendChild(S.documentElement, backdropStyle);

function isShown() {
  if (!showPopoverRaw) return true;
  try {
    return matchesRaw(host, ':popover-open');
  } catch (_) {
    return false;
  }
}

/** Plugin chat panels always draw over the chrome. */
function raisePlugins() {
  if (!pluginPanels) return;
  try { pluginPanels.raise(); } catch (_) {}
}

function mount() {
  const body = S.bodyOf();
  if (!body) return;
  if (S.getParentNode(host) !== body) S.appendChild(body, host);
  if (S.getParentNode(backdropStyle) !== S.documentElement) S.appendChild(S.documentElement, backdropStyle);
  if (S.getAttribute(host, 'style') !== HOST_STYLE) S.setAttribute(host, 'style', HOST_STYLE);
  if (showPopoverRaw) {
    if (S.getAttribute(host, 'popover') !== 'manual') S.setAttribute(host, 'popover', 'manual');
    if (!isShown()) {
      try { showPopoverRaw(host); } catch (_) {}
      raisePlugins();
    }
  }
}

mount();
// Put back whatever is taken away: the host, its style, its place in the top
// layer.
S.observeMutations(S.bodyOf(), { childList: true }, () => {
  if (!S.getIsConnected(host)) mount();
});
S.observeMutations(host, { attributes: true }, mount);
S.on(host, 'toggle', () => S.setTimer(mount, 0));
// Another element entering the top layer would land above the chrome; raise
// the chrome again — unless one of its fields has the focus, which leaving
// the top layer would take away (and the keyboard with it).
S.on(document, 'toggle', (e) => {
  const target = S.eventTarget(e);
  if (!showPopoverRaw || target === host) return;
  if (pluginPanels && pluginPanels.has(target)) return;
  if (S.getActiveElementOfRoot(shadow)) return;
  S.setTimer(() => {
    try {
      if (isShown()) S.hidePopover(host);
    } catch (_) {}
    mount();
  }, 0);
}, true);

/* ---------- Context ---------- */

const layers = {
  fades: h('div', '', rootEl),
  drawer: h('div', '', rootEl),
  composer: h('div', '', rootEl),
  header: h('div', '', rootEl),
};
for (const name in layers) css(layers[name], 'display', 'contents');

const DEFAULT_THEME = {
  accent: [196, 42, 74, 1],
  onSurface: [230, 225, 229, 1],
  onSurfaceVariant: [202, 196, 208, 1],
  outlineVariant: [73, 69, 79, 1],
  text: [230, 225, 229, 1],
  text2: [202, 196, 208, 1],
  uiBorder: { c: [255, 255, 255, 0.1], w: 1 },
  fillHeader: [43, 41, 48, 0.8],
  fillSurface: [20, 18, 24, 0.8],
  blur: true,
  blurSigma: 20,
  noiseOpacity: 0,
  noiseIntensity: 0,
  batterySaver: false,
  desktop: false,
  fontScale: 1,
  letterSpacing: 0,
  cornerScale: 1,
  avatarRoundness: 1,
  disabled: [230, 225, 229, 0.38],
  tipBg: [97, 97, 97, 0.9],
  tipText: [255, 255, 255, 1],
};

const DEFAULT_LAYOUT = {
  safeTop: 0,
  safeBottom: 0,
  inset: 0,
  viewportH: 0,
  keyboard: 0,
  softKeyboard: false,
  gutter: 0,
  fades: false,
  drawer: { show: false, height: 0, progress: 0 },
};

let reportQueued = false;
let lastReport = '';

const ctx = {
  root: rootEl,
  overlay: rootEl,
  layers,
  theme: DEFAULT_THEME,
  themeKey: '',
  layout: DEFAULT_LAYOUT,
  pinEls: S.dict(),
  send(type, data) {
    S.callFlutter('onChromeIntent', KEY_OUT, S.jsonStringify({ t: type, d: data || {} }));
  },
  rect: rectOf,
  scheduleReport() {
    if (reportQueued) return;
    reportQueued = true;
    S.raf(report);
  },
  /** How much of the keyboard the page's own viewport has already given up. */
  shrink() {
    const full = ctx.layout.viewportH || 0;
    if (full <= 0) return 0;
    const shrink = full - S.viewportHeight();
    if (shrink < 8) return 0;
    return S.mathMin(shrink, ctx.layout.keyboard || 0);
  },
};

ctx.drag = createDrag(ctx);

const fadeTop = h('div', 'gc-fade-top gc-hidden', layers.fades);
const fadeBottom = h('div', 'gc-fade-bottom gc-hidden', layers.fades);

// Factories append to ctx.root; reparent each into its layer so the paint
// order matches Flutter's: fades, drawer, composer, header.
function inLayer(layer, make) {
  const prev = ctx.root;
  ctx.root = layer;
  try {
    return make();
  } finally {
    ctx.root = prev;
  }
}
const header = inLayer(layers.header, () => createHeader(ctx));
const composer = inLayer(layers.composer, () => createComposer(ctx));
const drawer = inLayer(layers.drawer, () => createDrawer(ctx, composer));
ctx.root = rootEl;

let composerHeight = 0;

function report() {
  reportQueued = false;
  const out = {};
  header.report(out);
  composer.report(out);
  drawer.report(out);
  composerHeight = out.composerHeight || 0;
  placeFades();
  const key = S.jsonStringify(out);
  if (key === lastReport) return;
  lastReport = key;
  ctx.send('layout', out);
}

S.observeResize(composer.root, () => ctx.scheduleReport());
S.on(window, 'resize', () => {
  placeBottom();
  ctx.scheduleReport();
});
S.onFontsLoaded(() => {
  composer.themeChanged();
  ctx.scheduleReport();
});

/* ---------- Theme ---------- */

let fontFace = null;
let fontSource = null;
let fontFamily = null;

const SYSTEM_FONTS = "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif";

function applyFontFamily() {
  const named = ctx.theme.fontFamily;
  const families = fontFamily
    ? `"${fontFamily}", ${SYSTEM_FONTS}`
    : named ? `"${S.stringFn(named).replace(/["\\]/g, '')}", ${SYSTEM_FONTS}` : SYSTEM_FONTS;
  css(rootEl, '--gc-font', families);
}

/**
 * The UI font's file, as a data URL. Registered under a family name of our
 * own, so a font a message declares can't stand in for it.
 */
function applyFont(font) {
  const data = font && typeof font.data === 'string' && font.data.indexOf('data:') === 0 ? font.data : null;
  if (data !== fontSource) {
    S.unloadFont(fontFace);
    fontFace = null;
    fontFamily = null;
    fontSource = data;
    if (data) {
      fontFamily = `gc-${S.randomToken(10)}`;
      // A variable font covers every weight itself; declared as one weight
      // the page would embolden it artificially for the 600 labels.
      fontFace = S.loadFont(fontFamily, data, font.weights ? { weight: S.stringFn(font.weights) } : null);
      if (!fontFace) fontFamily = null;
    }
  }
  applyFontFamily();
  composer.themeChanged();
}

function applyTheme(t) {
  const theme = {};
  for (const k in DEFAULT_THEME) theme[k] = DEFAULT_THEME[k];
  for (const k in t) theme[k] = t[k];
  ctx.theme = theme;
  ctx.themeKey = S.jsonStringify(t);

  const v = (name, value) => css(rootEl, name, value);
  v('--gc-accent', rgba(theme.accent));
  v('--gc-accent-08', rgba(theme.accent, 0.08));
  v('--gc-accent-22', rgba(theme.accent, 0.22));
  v('--gc-accent-35', rgba(theme.accent, 0.35));
  v('--gc-accent-38', rgba(theme.accent, 0.38));
  v('--gc-accent-55', rgba(theme.accent, 0.55));
  v('--gc-on', rgba(theme.onSurface));
  v('--gc-on-06', rgba(theme.onSurface, 0.06));
  v('--gc-on-45', rgba(theme.onSurface, 0.45));
  v('--gc-on-55', rgba(theme.onSurface, 0.55));
  v('--gc-on-60', rgba(theme.onSurface, 0.6));
  v('--gc-onvar-50', rgba(theme.onSurfaceVariant, 0.5));
  v('--gc-onvar-95', rgba(theme.onSurfaceVariant, 0.95));
  v('--gc-outline-var', rgba(theme.outlineVariant));
  v('--gc-outline', rgba(theme.outline || theme.outlineVariant));
  v('--gc-surface-high', rgba(theme.surfaceHigh || theme.fillHeader));
  v('--gc-text', rgba(theme.text));
  v('--gc-text2', rgba(theme.text2));
  v('--gc-disabled', rgba(theme.disabled));
  v('--gc-tip-bg', rgba(theme.tipBg));
  v('--gc-tip-text', rgba(theme.tipText));
  const border = theme.uiBorder || {};
  v('--gc-ui-bw', px(border.w || 0));
  v('--gc-ui-bc', rgba(border.c));
  v('--gc-guide-bw', px(S.mathMax(1, border.w || 0)));
  v('--gc-fill-header', rgba(theme.fillHeader));
  v('--gc-fill-surface', rgba(theme.fillSurface));
  v('--gc-backdrop', theme.blur && !theme.batterySaver && theme.blurSigma > 0
    ? `blur(${theme.blurSigma}px)` : 'none');
  // Shadow every inherited variable the stylesheet reads as a fallback.
  v('--gc-corner', S.stringFn(theme.cornerScale));
  v('--gc-fill', 'transparent');
  v('--gc-bw', '0px');
  v('--gc-bc', 'transparent');
  v('--gc-glow-color', 'transparent');

  applyFontFamily();

  composer.themeChanged();
  drawer.themeChanged();
  header.render();
}

/* ---------- Theme layout ---------- */

// The base every theme layout gets: a placeholder takes no box of its own,
// and what a template leaves out is kept out of sight.
const SKIN_BASE = 'g-part{display:contents}.g-unplaced{display:none!important}';
let skinKey = '';

/**
 * A theme's own layout: templates for the header, the compose area and the
 * drawer's cards and tabs, and a stylesheet (template.js, skin.js). The
 * stylesheet is sanitised here too: it loads data: URLs only.
 */
function applySkin(skin) {
  const s = skin && typeof skin === 'object' ? skin : {};
  const str = (k) => (S.hasOwn(s, k) && typeof s[k] === 'string' ? s[k] : '');
  const key = S.jsonStringify([str('css'), str('header'), str('composer'), str('drawerCard'), str('drawerTab'),
    S.hasOwn(s, 'vars') ? s.vars : null, S.hasOwn(s, 'flags') ? s.flags : null]);

  if (key === skinKey) return;
  skinKey = key;
  applyThemeValues(S.hasOwn(s, 'vars') ? s.vars : null, S.hasOwn(s, 'flags') ? s.flags : null);
  const css = sanitizeCss(str('css'));
  S.setTextContent(skinStyleEl, str('header') || str('composer') || str('drawerCard') || str('drawerTab') || css
    ? SKIN_BASE + css : '');
  const tpl = (k) => (str(k) ? compile(str(k)) : null);
  header.setSkin(tpl('header'));
  composer.setSkin(tpl('composer'));
  drawer.setSkin(tpl('drawerCard'), tpl('drawerTab'));
}

let themeVarNames = [];

/**
 * The theme's own setting values: `--theme-<key>` variables and
 * `theme-<flag>` classes on the chrome's root, for its stylesheet. Set here
 * and not inherited from the page, where a message could override them.
 */
function applyThemeValues(vars, flags) {
  for (let i = 0; i < themeVarNames.length; i++) css(rootEl, `--theme-${themeVarNames[i]}`, '');
  themeVarNames = [];
  const entries = themeValueEntries(vars, flags);
  for (let i = 0; i < entries.vars.length; i++) {
    const k = entries.vars[i][0];
    css(rootEl, `--theme-${k}`, entries.vars[i][1]);
    S.put(themeVarNames, k);
  }
  let cls = 'gc';
  for (let i = 0; i < entries.flags.length; i++) cls += ` theme-${entries.flags[i]}`;
  S.setAttribute(rootEl, 'class', cls);
}

/* ---------- Layout ---------- */

function placeBottom() {
  const layout = ctx.layout;
  const bottom = S.mathMax(0, (layout.inset || 0) - ctx.shrink());
  css(composer.root, 'bottom', px(bottom));
  drawer.render();
  placeFades();
}

function placeFades() {
  const layout = ctx.layout;
  const on = !!layout.fades;
  S.setAttribute(fadeTop, 'class', on ? 'gc-fade-top' : 'gc-fade-top gc-hidden');
  S.setAttribute(fadeBottom, 'class', on && composerHeight > 0 ? 'gc-fade-bottom' : 'gc-fade-bottom gc-hidden');
  if (!on) return;
  css(fadeTop, 'height', px(layout.safeTop + 20));
  css(fadeTop, 'left', px(layout.gutter));
  css(fadeTop, 'right', px(layout.gutter));
  css(fadeBottom, 'left', px(layout.gutter));
  css(fadeBottom, 'right', px(layout.gutter));
  const bottom = S.mathMax(0, (layout.inset || 0) - ctx.shrink());
  css(fadeBottom, 'height', px(composerHeight + bottom + 40));
}

function applyLayout(l) {
  const layout = {};
  for (const k in DEFAULT_LAYOUT) layout[k] = DEFAULT_LAYOUT[k];
  for (const k in l) layout[k] = l[k];
  const prev = ctx.layout;
  ctx.layout = layout;
  // For theme layouts: the page and the chrome can keep their own frame while
  // still clearing the status bar, without a gap above the window.
  css(rootEl, '--gc-safe-top', px(layout.safeTop || 0));
  css(rootEl, '--gc-safe-bottom', px(layout.safeBottom || 0));
  // The same insets on the document, in the names theme layouts use.
  css(document.documentElement, '--sat', px(layout.safeTop || 0));
  css(document.documentElement, '--sab', px(layout.safeBottom || 0));
  const shallow = prev.safeTop === layout.safeTop && prev.safeBottom === layout.safeBottom &&
    prev.gutter === layout.gutter && prev.desktop === layout.desktop;
  if (!shallow) {
    header.render();
    composer.render();
  }
  placeBottom();
}

/* ---------- API ---------- */

function handle(msg) {
  if (msg.theme) applyTheme(msg.theme);
  if ('skin' in msg) applySkin(msg.skin);
  if ('font' in msg) applyFont(msg.font);
  if (msg.layout) applyLayout(msg.layout);
  if (msg.header) header.apply(msg.header);
  if (msg.composer) composer.apply(msg.composer);
  if ('sendHover' in msg) composer.setSendHover(!!msg.sendHover);
  if (msg.attachments) composer.apply({ attachments: S.isArray(msg.attachments) ? msg.attachments : [] });
  if (msg.drawer) drawer.apply(msg.drawer);
  if (msg.text) composer.setText(S.stringFn(msg.text.v == null ? '' : msg.text.v), msg.text.rev);
  if (msg.guidanceText) {
    composer.setGuidanceText(S.stringFn(msg.guidanceText.v == null ? '' : msg.guidanceText.v), msg.guidanceText.rev);
  }
  const cmd = msg.cmd;
  if (cmd) {
    if (cmd.focus) composer.focus();
    if (cmd.blur) {
      composer.blur();
      header.blurAll();
    }
    if (cmd.insert) composer.insertSurround(S.stringFn(cmd.insert));
    if (cmd.cancelDrag) ctx.drag.cancel();
  }
  ctx.scheduleReport();
}

const api = S.freeze({
  pageId: PAGE_ID,
  /** Hands the two keys out — once per page load, to Flutter. */
  handshake() {
    if (handedOut) return null;
    handedOut = true;
    return `${KEY_IN}:${KEY_OUT}`;
  },
  apply(key, json) {
    if (key !== KEY_IN || typeof json !== 'string') return false;
    let msg;
    try {
      msg = S.jsonParse(json);
    } catch (_) {
      return false;
    }
    if (!msg || typeof msg !== 'object') return false;
    handle(msg);
    return true;
  },
});

S.defineProperty(window, '__glazeChrome', {
  value: api,
  writable: false,
  configurable: false,
  enumerable: false,
});
