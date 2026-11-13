// Small building blocks shared by the header, the composer and the drawer:
// element creation, icons, glass surfaces, the press and glow feedback, and
// tooltips. Every DOM call goes through ./safe.js — see the note there.

import * as S from './safe.js';
import { ICON_PATHS, ICON_VIEWBOX } from './icons.js';

export function h(tag, className, parent) {
  const el = S.createElement(tag);
  if (className) S.setAttribute(el, 'class', className);
  if (parent) S.appendChild(parent, el);
  return el;
}

export function setClass(el, className) {
  S.setAttribute(el, 'class', className);
}

/** Joins the names whose flag is on: `classes('a', {b: true, c: false})`. */
export function classes(base, flags) {
  let out = base;
  for (const name in flags) {
    if (flags[name]) out += ' ' + name;
  }
  return out;
}

export function text(el, value) {
  S.setTextContent(el, value == null ? '' : S.stringFn(value));
}

export function css(el, prop, value) {
  S.setStyle(el, prop, value);
}

/**
 * A theme colour — `[r, g, b, a]` with a in 0..1, as Flutter sends it — as a
 * CSS colour. [alpha], when given, replaces the colour's own alpha, the way
 * Color.withValues(alpha:) does.
 */
export function rgba(c, alpha) {
  if (!S.isArray(c)) return 'transparent';
  const a = alpha === undefined ? c[3] : alpha;
  return `rgba(${c[0]},${c[1]},${c[2]},${S.mathMax(0, S.mathMin(1, a))})`;
}

export function px(n) {
  return `${S.numberIsFinite(n) ? n : 0}px`;
}

export function clear(el) {
  let child = S.getFirstChild(el);
  while (child) {
    S.removeChild(el, child);
    child = S.getFirstChild(el);
  }
}

export function detach(el) {
  const parent = el && S.getParentNode(el);
  if (parent) S.removeChild(parent, el);
}

/** A stable string for an icon spec, to tell whether it changed. */
export function iconKey(spec) {
  if (!spec) return '';
  return `${spec.cp || ''}|${spec.g || ''}|${spec.f || ''}`;
}

/**
 * Draws one button's mark into [box]: a Material glyph by Flutter codepoint
 * (`cp`), a short text token (`g`, the insert actions' `**`), or an image file
 * (`f`; an SVG takes the colour like a glyph, a raster keeps its own). Mirrors
 * ActionGlyph on the Flutter side.
 */
export function drawIcon(box, spec, size) {
  clear(box);
  if (!spec) return;
  if (spec.g) {
    const t = h('span', 'gc-glyph-text', box);
    css(t, 'font-size', px(size * 0.85));
    text(t, spec.g);
    return;
  }
  if (spec.f) {
    if (spec.svg) {
      const m = h('span', 'gc-icon-mask', box);
      css(m, 'width', px(size));
      css(m, 'height', px(size));
      css(m, '-webkit-mask-image', `url("${spec.f}")`);
      css(m, 'mask-image', `url("${spec.f}")`);
    } else {
      const img = h('img', 'gc-icon-img', box);
      S.setAttribute(img, 'src', spec.f);
      S.setAttribute(img, 'alt', '');
      S.setAttribute(img, 'draggable', 'false');
      css(img, 'width', px(size));
      css(img, 'height', px(size));
    }
    return;
  }
  const d = ICON_PATHS[spec.cp];
  if (!d) return;
  const svg = S.createSvg('svg');
  S.setAttribute(svg, 'viewBox', ICON_VIEWBOX);
  S.setAttribute(svg, 'width', S.stringFn(size));
  S.setAttribute(svg, 'height', S.stringFn(size));
  S.setAttribute(svg, 'aria-hidden', 'true');
  const path = S.createSvg('path');
  S.setAttribute(path, 'd', d);
  S.setAttribute(path, 'fill', 'currentColor');
  S.appendChild(svg, path);
  S.appendChild(box, svg);
}

/** An icon box of [size] px with [spec] drawn in it. */
export function icon(spec, size, parent, className) {
  const box = h('span', className ? `gc-icon ${className}` : 'gc-icon', parent);
  css(box, 'width', px(size));
  css(box, 'height', px(size));
  drawIcon(box, spec, size);
  return box;
}

/* ---------- Glass ---------- */

// Noise tiles by alpha; each tile is 128 texels drawn `step` px per texel.
const NOISE_CELLS = 128;
const noiseTiles = {};
function noiseUrl(alphaScale) {
  const key = S.mathRound(alphaScale * 1000);
  if (!(key in noiseTiles)) noiseTiles[key] = S.noiseTile(NOISE_CELLS, alphaScale);
  return noiseTiles[key];
}

/**
 * A glass surface: tint, outline, backdrop blur and grain, like
 * GlassSurface. Returns `{el, content}`; children go in `content`.
 */
export function glass(className, parent) {
  const el = h('div', `gc-glass ${className || ''}`, parent);
  const noise = h('div', 'gc-noise', el);
  const content = h('div', 'gc-glass-content', el);
  return { el, noise, content };
}

/** Grain sized the way NoiseOverlay picks its texel size for a surface. */
export function applyNoise(surface, theme, width, height) {
  const opacity = theme.noiseOpacity || 0;
  const intensity = theme.noiseIntensity || 0;
  const alpha = S.mathMin(1, S.mathMax(0, opacity * intensity));
  if (theme.batterySaver || alpha <= 0) {
    css(surface.noise, 'display', 'none');
    return;
  }
  const pixels = S.mathMax(1, width * height);
  const step = S.mathMin(theme.desktop ? 2 : 10, S.mathMax(1, S.mathCeil(pixels / 50000)));
  const url = noiseUrl(alpha);
  if (!url) {
    css(surface.noise, 'display', 'none');
    return;
  }
  css(surface.noise, 'display', 'block');
  css(surface.noise, 'background-image', `url("${url}")`);
  css(surface.noise, 'background-size', px(NOISE_CELLS * step));
}

/* ---------- Feedback ---------- */

const easeOut = (t) => 1 - S.mathPow(1 - t, 3);

/**
 * The glow a GlowRippleOverlay draws where a press lands: a radial accent
 * gradient growing from 0.2x to 2.5x the surface's larger side while it fades,
 * over 800ms.
 */
export function attachGlow(surfaceEl, ctx, { radiusFactor = 1, intensity = 0.15 } = {}) {
  const layer = h('div', 'gc-glow-layer', surfaceEl);
  S.on(surfaceEl, 'pointerdown', (e) => {
    if (!e.isTrusted || ctx.theme.batterySaver) return;
    const r = S.getBoundingClientRect(surfaceEl);
    const x = S.clientX(e) - r.left;
    const y = S.clientY(e) - r.top;
    const maxRadius = S.mathMax(r.width, r.height) * radiusFactor;
    const dot = h('div', 'gc-glow', layer);
    css(dot, 'left', px(x - maxRadius));
    css(dot, 'top', px(y - maxRadius));
    css(dot, 'width', px(maxRadius * 2));
    css(dot, 'height', px(maxRadius * 2));
    css(dot, '--gc-glow-color', rgba(ctx.theme.accent, intensity));
    const start = S.now();
    const step = () => {
      const t = S.mathMin(1, (S.now() - start) / 800);
      const k = easeOut(t);
      css(dot, 'transform', `scale(${0.2 + 2.3 * k})`);
      css(dot, 'opacity', S.stringFn(1 - k));
      if (t < 1) S.raf(step);
      else detach(dot);
    };
    step();
  });
}

/**
 * Shrinks [el] to 0.82 while pressed: 80ms down, 150ms back, easeOut — the
 * composer buttons' ScaleTransition. [enabled] is asked on every press.
 */
export function attachPress(el, ctx, enabled) {
  const release = () => {
    css(el, 'transition', 'transform 150ms cubic-bezier(0.215, 0.61, 0.355, 1)');
    css(el, 'transform', 'scale(1)');
  };
  S.on(el, 'pointerdown', (e) => {
    if (!e.isTrusted || ctx.theme.batterySaver || !enabled()) return;
    css(el, 'transition', 'transform 80ms cubic-bezier(0.215, 0.61, 0.355, 1)');
    css(el, 'transform', 'scale(0.82)');
  });
  S.on(el, 'pointerup', release);
  S.on(el, 'pointercancel', release);
  S.on(el, 'pointerleave', release);
}

/**
 * A tap: a trusted click. Clicks the page synthesizes (`el.click()`, a
 * dispatched event) are ignored, so nothing but a real touch or mouse press
 * can drive the chrome.
 */
let tapsSuppressedUntil = 0;

/** Swallows the click that follows a drop, which is not a tap. */
export function suppressTaps() {
  tapsSuppressedUntil = S.dateNow() + 400;
}

export function onTap(el, fn) {
  S.on(el, 'click', (e) => {
    if (!e.isTrusted) return;
    S.stopPropagation(e);
    if (S.dateNow() < tapsSuppressedUntil) return;
    fn(e);
  });
}

/* ---------- Tooltip ---------- */

let tipEl = null;
let tipTimer = 0;
let tipHideTimer = 0;

function hideTip() {
  S.clearTimer(tipTimer);
  S.clearTimer(tipHideTimer);
  if (tipEl) css(tipEl, 'opacity', '0');
}

function showTip(ctx, target, message) {
  if (!message) return;
  if (!tipEl) tipEl = h('div', 'gc-tooltip', ctx.overlay);
  text(tipEl, message);
  css(tipEl, 'left', '0px');
  css(tipEl, 'top', '0px');
  css(tipEl, 'opacity', '0');
  const r = S.getBoundingClientRect(target);
  const t = S.getBoundingClientRect(tipEl);
  const vw = S.getBoundingClientRect(ctx.overlay).width;
  // Above the target (preferBelow: false), centred and kept on screen.
  let left = r.left + r.width / 2 - t.width / 2;
  left = S.mathMax(8, S.mathMin(vw - t.width - 8, left));
  let top = r.top - t.height - 8;
  if (top < 8) top = r.bottom + 8;
  css(tipEl, 'left', px(left));
  css(tipEl, 'top', px(top));
  css(tipEl, 'opacity', '1');
}

/**
 * Material's Tooltip: shown after hovering with a mouse, or on a long press
 * by touch, then hidden again. [message] is asked when it is about to show.
 */
export function attachTooltip(el, ctx, message) {
  S.on(el, 'pointerenter', (e) => {
    if (!e.isTrusted || S.pointerType(e) !== 'mouse') return;
    S.clearTimer(tipTimer);
    tipTimer = S.setTimer(() => showTip(ctx, el, message()), 500);
  });
  S.on(el, 'pointerleave', hideTip);
  S.on(el, 'pointerdown', (e) => {
    hideTip();
    if (!e.isTrusted || S.pointerType(e) === 'mouse') return;
    tipTimer = S.setTimer(() => {
      showTip(ctx, el, message());
      tipHideTimer = S.setTimer(hideTip, 1500);
    }, 500);
  });
  S.on(el, 'pointerup', () => S.clearTimer(tipTimer));
  S.on(el, 'pointercancel', () => S.clearTimer(tipTimer));
}

export function rectOf(el) {
  const r = S.getBoundingClientRect(el);
  return [S.mathRound(r.left), S.mathRound(r.top), S.mathRound(r.width), S.mathRound(r.height)];
}
