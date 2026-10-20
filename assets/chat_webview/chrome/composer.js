// The composer: attachments, the input pill (with the guidance field as its
// top half), the row of pinned buttons and the send button — and, in its
// place while searching or selecting, the matching control bar. Mirrors
// ChatInputBar.
//
// The text lives here, in the textarea, because that is where the keyboard
// types; every change is reported to Flutter, which owns everything else:
// what a button does, whether a send goes through, the draft, the drawer.
// Flutter writes the text back only when it changes it itself (a send that
// clears the box, impersonation streaming in, a translation, the fullscreen
// editor).

import * as S from './safe.js';
import { ICON } from './icons.js';
import {
  h, css, px, text, rgba, setClass, classes, icon, drawIcon, iconKey, glass, attachGlow,
  applyNoise, onTap, attachPress, attachTooltip, clear, detach,
} from './ui.js';
import { createSkin } from './skin.js';

const DISMISS_DRAG_PX = 28;

export function createComposer(ctx) {
  const st = {
    show: false,
    mode: 'compose',
    placeholder: '',
    readOnly: false,
    locked: false,
    virtualSend: false,
    enterSend: false,
    guidance: null,
    attachments: [],
    pins: [],
    editing: false,
    send: null,
    search: null,
    selection: null,
    extraBottom: 0,
    pinsKey: '',
    attsKey: '',
  };
  let hadSelection = false;
  let lineHeight = 0;
  let guideLineHeight = 0;

  const root = h('div', 'gc-cmp gc-hidden', ctx.root);

  /* ---- Compose ---- */
  const compose = h('div', '', root);
  const atts = h('div', 'gc-atts gc-hidden', compose);

  const pill = glass('gc-pill', compose);
  attachGlow(pill.el, ctx);

  const guide = h('div', 'gc-guide gc-hidden', pill.content);
  const guideHead = h('div', 'gc-guide-head', guide);
  const guideCaption = h('div', 'gc-guide-caption', guideHead);
  const guideClose = h('button', 'gc-guide-x', guideHead);
  icon(ICON.close_rounded, 16, guideClose);
  onTap(guideClose, () => {
    if (!st.locked) ctx.send('guidanceClose');
  });
  const guideBody = h('div', 'gc-guide-body', guide);
  icon(ICON.tips_and_updates_outlined, 20, h('div', 'gc-guide-prefix', guideBody));
  const guideInput = h('textarea', 'gc-guide-input', guideBody);
  S.setAttribute(guideInput, 'rows', '1');
  S.setAttribute(guideInput, 'autocapitalize', 'sentences');

  const input = h('textarea', 'gc-input', pill.content);
  S.setAttribute(input, 'rows', '1');
  S.setAttribute(input, 'autocapitalize', 'sentences');

  // Line heights come from the font: one empty row's scrollHeight, padding
  // taken off. Measured on a hidden twin so the live field is never disturbed.
  const measure = h('textarea', 'gc-input', ctx.root);
  css(measure, 'position', 'absolute');
  css(measure, 'visibility', 'hidden');
  css(measure, 'left', '-9999px');
  css(measure, 'top', '0');
  css(measure, 'width', '200px');
  S.setAttribute(measure, 'rows', '1');
  S.setAttribute(measure, 'tabindex', '-1');
  S.setAttribute(measure, 'aria-hidden', 'true');

  const row = h('div', 'gc-row', compose);
  const pins = h('div', 'gc-pins', row);
  const pinsInner = h('div', 'gc-pins-inner', pins);
  const sendWrap = h('div', 'gc-send-wrap', row);
  const sendBtn = h('button', 'gc-send', sendWrap);
  let sendGlyph = null;
  let sendGlyphKey = null;
  let sendBadge = null;
  attachPress(sendBtn, ctx, () => !!(st.send && st.send.tap));
  attachTooltip(sendWrap, ctx, () => (st.send && st.send.slot && st.send.hint) || '');
  function tapSend() {
    if (!st.send || !st.send.tap) return;
    // The empty composer's button may be assigned an insert action: typed
    // here, inside the tap, so the keyboard comes up with it.
    if (st.send.insert) {
      insertSurround(st.send.insert);
      return;
    }
    ctx.send('sendTap', { v: S.getValue(input), g: S.getValue(guideInput) });
  }
  onTap(sendBtn, tapSend);
  ctx.drag.target(sendWrap, {
    group: 'send',
    depth: 3,
    accepts: (payload) => !!(st.editing && st.send && st.send.slot &&
      payload !== st.send.emptyPin && payload.indexOf('tool:') !== 0),
    enter: () => setClass(sendWrap, 'gc-send-wrap gc-candidate'),
    leave: () => setClass(sendWrap, 'gc-send-wrap'),
    drop: (payload) => ctx.send('assignEmpty', { key: payload }),
  });

  // A theme's own layout of the compose area (skin.js).
  const skin = createSkin(compose, {
    attachments: atts,
    pill: pill.el,
    guidance: guide,
    input,
    row,
    pins,
    send: sendWrap,
  }, [
    [compose, [atts, pill.el, row]],
    [pill.content, [guide, input]],
    [row, [pins, sendWrap]],
  ], {
    send: () => tapSend(),
    focus: () => {
      if (!st.locked) S.focusRaw(input);
    },
  });
  let skinHasText = null;

  function skinData() {
    const list = st.pins || [];
    const pinData = [];
    for (let i = 0; i < list.length; i++) pinData[pinData.length] = { key: list[i].key, icon: list[i].icon || null };
    return {
      placeholder: st.placeholder || '',
      hasText: S.getValue(input) !== '',
      locked: !!st.locked,
      readOnly: !!st.readOnly,
      editing: !!st.editing,
      guidance: !!st.guidance,
      attachments: (st.attachments || []).length,
      pins: pinData,
      send: { icon: (st.send && st.send.icon) || null, enabled: !!(st.send && st.send.tap) },
    };
  }

  function updateSkin() {
    if (!skin.active) return;
    skinHasText = S.getValue(input) !== '';
    skin.update(skinData());
  }

  /* ---- Search / selection bar ---- */
  const barPill = glass('gc-pill', root);
  attachGlow(barPill.el, ctx);
  const bar = h('div', 'gc-bar', barPill.content);

  /* ---- Text ---- */
  function grow(el, lineH, maxLines, padV, minH) {
    if (!lineH) return;
    css(el, 'height', '0px');
    const sh = S.getScrollHeight(el);
    const max = lineH * maxLines + padV;
    css(el, 'height', px(S.mathMax(minH, S.mathMin(sh, max))));
    css(el, 'overflow-y', sh > max + 0.5 ? 'auto' : 'hidden');
  }

  function growAll() {
    grow(input, lineHeight, 5, 24, 56);
    if (st.guidance) grow(guideInput, guideLineHeight, 3, 16, 0);
    ctx.scheduleReport();
  }

  function measureLines() {
    css(measure, 'font-size', px(16 * ctx.theme.fontScale));
    css(measure, 'letter-spacing', px(ctx.theme.letterSpacing));
    css(measure, 'padding', '0');
    css(measure, 'line-height', '1.5');
    css(measure, 'min-height', '0');
    css(measure, 'height', '0px');
    S.setValue(measure, '');
    lineHeight = S.getScrollHeight(measure);
    css(measure, 'font-size', px(14 * ctx.theme.fontScale));
    guideLineHeight = S.getScrollHeight(measure);
  }

  S.on(input, 'input', (e) => {
    growAll();
    if (skin.active && (S.getValue(input) !== '') !== skinHasText) updateSkin();
    if (!e.isTrusted) return;
    ctx.send('text', { v: S.getValue(input) });
  });
  S.on(guideInput, 'input', (e) => {
    growAll();
    if (!e.isTrusted) return;
    ctx.send('guidanceText', { v: S.getValue(guideInput) });
  });
  S.on(input, 'focus', (e) => {
    if (!e.isTrusted) return;
    hadSelection = true;
    ctx.send('focus', { f: true });
  });
  S.on(input, 'blur', () => ctx.send('focus', { f: false }));

  function wantsNewline() {
    // Enter-to-send is for physical keyboards: while the soft keyboard is up
    // its Enter (some keyboards send it as a key event) inserts a newline.
    return ctx.layout.softKeyboard;
  }

  S.on(input, 'keydown', (e) => {
    if (!e.isTrusted || st.locked) return;
    if (S.keyOf(e) !== 'Enter' || S.shiftKeyOf(e) || S.keyIsComposing(e)) return;
    if (st.enterSend && !wantsNewline()) {
      S.preventDefault(e);
      ctx.send('sendTap', { v: S.getValue(input), g: S.getValue(guideInput), enter: true });
    }
  });
  // The soft keyboard's action key, when it is set to Send.
  S.on(input, 'beforeinput', (e) => {
    if (!e.isTrusted || !st.virtualSend || st.locked) return;
    const type = S.inputTypeOf(e);
    if (type !== 'insertLineBreak' && type !== 'insertParagraph') return;
    if (S.inputIsComposing(e)) return;
    if (st.enterSend && !wantsNewline()) return; // handled on keydown
    S.preventDefault(e);
    ctx.send('sendTap', { v: S.getValue(input), g: S.getValue(guideInput), enter: true });
  });

  // Images on the clipboard become attachments; a paste with no text at all
  // asks Flutter, which can read clipboard images the page cannot see.
  S.on(input, 'paste', (e) => {
    if (!e.isTrusted || st.locked) return;
    const dt = S.clipboardDataOf(e);
    const files = S.clipboardFiles(dt);
    const images = [];
    for (let i = 0; i < files.length; i++) {
      if (S.blobType(files[i]).indexOf('image/') === 0) images[images.length] = files[i];
    }
    if (images.length) {
      S.preventDefault(e);
      const urls = [];
      let left = images.length;
      for (let i = 0; i < images.length; i++) {
        S.readDataUrl(images[i]).then((url) => {
          if (url) urls[urls.length] = url;
          if (--left === 0 && urls.length) ctx.send('attach', { urls });
        });
      }
      return;
    }
    if (!S.clipboardHasText(dt)) {
      S.preventDefault(e);
      ctx.send('pasteRequest');
    }
  });

  // A downward swipe over the composer puts the keyboard away.
  let dragStartY = null;
  let dragDist = 0;
  S.on(root, 'touchstart', (e) => {
    if (!e.isTrusted) return;
    dragStartY = S.firstTouchY(e);
    dragDist = 0;
  }, { passive: true });
  S.on(root, 'touchmove', (e) => {
    if (dragStartY == null || !e.isTrusted) return;
    const y = S.firstTouchY(e);
    if (y == null) return;
    const dy = y - dragStartY;
    dragStartY = y;
    dragDist = dy <= 0 ? 0 : dragDist + dy;
  }, { passive: true });
  S.on(root, 'touchend', () => {
    if (dragStartY != null && dragDist >= DISMISS_DRAG_PX && ctx.layout.keyboard > 0) {
      S.blurRaw(input);
      S.blurRaw(guideInput);
    }
    dragStartY = null;
    dragDist = 0;
  }, { passive: true });

  /** Wraps the caret / selection in a pair of [token] — insertSurroundingText. */
  function insertSurround(token) {
    if (!token || st.locked) return;
    const value = S.getValue(input);
    let start = value.length;
    let end = value.length;
    if (hadSelection) {
      start = S.getSelectionStart(input);
      end = S.getSelectionEnd(input);
    }
    const selected = value.slice(start, end);
    const next = value.slice(0, start) + token + selected + token + value.slice(end);
    S.setValue(input, next);
    S.focusRaw(input);
    const caret = start + token.length + selected.length;
    S.setSelectionRange(input, caret, caret);
    hadSelection = true;
    growAll();
    ctx.send('text', { v: next });
  }

  /* ---- Rendering ---- */
  function renderAttachments() {
    const key = S.jsonStringify(st.attachments);
    if (key === st.attsKey) return;
    st.attsKey = key;
    clear(atts);
    const list = st.attachments || [];
    setClass(atts, list.length ? 'gc-atts' : 'gc-atts gc-hidden');
    const single = list.length === 1;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      const box = h('div', single ? 'gc-att gc-single' : 'gc-att gc-multi', atts);
      const img = h('img', '', box);
      S.setAttribute(img, 'src', item.src);
      S.setAttribute(img, 'alt', '');
      S.setAttribute(img, 'draggable', 'false');
      const x = h('button', 'gc-att-x', box);
      icon(ICON.close, 14, x);
      onTap(x, () => ctx.send('removeAttachment', { id: item.id }));
    }
  }

  function circle(parent, spec, color, enabled, onPress) {
    const surface = glass('gc-circle', parent);
    css(surface.el, 'border-radius', px(20 * ctx.theme.cornerScale));
    const mark = icon(spec, 20, surface.content);
    css(mark, 'color', color);
    applyNoise(surface, ctx.theme, 40, 40);
    attachPress(surface.el, ctx, enabled);
    if (onPress) onTap(surface.el, () => { if (enabled()) onPress(); });
    css(surface.el, 'cursor', enabled() ? 'pointer' : 'default');
    return surface;
  }

  function pinColor(pin) {
    return pin.color ? rgba(pin.color) : rgba(ctx.theme.accent);
  }

  function renderPins() {
    const key = S.jsonStringify([st.pins, st.editing, ctx.themeKey]);
    if (key === st.pinsKey) return;
    if (ctx.drag.active) {
      ctx.drag.whenIdle(renderPins);
      return;
    }
    st.pinsKey = key;
    clear(pinsInner);
    ctx.drag.removeGroup('pins');
    ctx.pinEls = S.dict();
    const list = st.pins || [];
    // An empty row still takes its share of the width, so the send button
    // keeps its place at the end (the Expanded around a SizedBox.shrink).
    setClass(pins, classes('gc-pins', { 'gc-editing': st.editing, 'gc-empty': !list.length }));
    // The row as a whole takes a card dropped past its last button.
    ctx.drag.target(pins, {
      group: 'pins',
      depth: 1,
      accepts: (payload) => st.editing && !hasPin(payload),
      drop: (payload) => ctx.send('pinDrop', { key: payload, target: null }),
    });
    for (let i = 0; i < list.length; i++) {
      const pin = list[i];
      const cell = h('div', 'gc-pin', pinsInner);
      // For theme layouts: which action a pin is, without exposing its label.
      S.setAttribute(cell, 'data-pin', pin.key);
      ctx.pinEls[pin.key] = cell;
      const surface = circle(cell, pin.icon, pinColor(pin), () => !st.editing && !!pin.tap, () => {
        if (pin.insert) insertSurround(pin.insert);
        ctx.send('pinTap', { key: pin.key });
      });
      if (st.editing && !pin.permanent) {
        const badge = h('button', 'gc-badge', cell);
        css(badge, 'width', '18px');
        css(badge, 'height', '18px');
        css(badge, 'background', rgba(ctx.theme.accent));
        css(badge, 'box-shadow', `0 4px 8px ${rgba(ctx.theme.accent, 0.3)}`);
        icon(ICON.arrow_downward, 18 * 0.58, badge);
        attachTooltip(badge, ctx, () => pin.badgeTip || '');
        onTap(badge, () => ctx.send('unpin', { key: pin.key }));
      }
      if (st.editing) {
        ctx.drag.source(cell, {
          payload: () => pin.key,
          enabled: () => st.editing,
          axis: 'x',
          ghostSource: () => surface.el,
          ghosted: (on) => css(cell, 'opacity', on ? '0.25' : null),
        });
        ctx.drag.target(cell, {
          group: 'pins',
          depth: 2,
          accepts: (payload) => st.editing && payload !== pin.key,
          drop: (payload) => ctx.send('pinDrop', { key: payload, target: pin.key }),
        });
      }
    }
  }

  function hasPin(key) {
    const list = st.pins || [];
    for (let i = 0; i < list.length; i++) if (list[i].key === key) return true;
    return false;
  }

  function renderSend() {
    const s = st.send;
    if (!s) return;
    const key = iconKey(s.icon);
    if (key !== sendGlyphKey) {
      const old = sendGlyph;
      sendGlyphKey = key;
      sendGlyph = h('span', 'gc-send-glyph', sendBtn);
      icon(s.icon, 20, sendGlyph);
      if (old && !ctx.theme.batterySaver) {
        setClass(sendGlyph, 'gc-send-glyph gc-entering');
        setClass(old, 'gc-send-glyph gc-leaving');
        const fresh = sendGlyph;
        S.raf(() => S.raf(() => setClass(fresh, 'gc-send-glyph')));
        S.setTimer(() => detach(old), 200);
      } else if (old) {
        detach(old);
      }
    }
    css(sendBtn, 'cursor', s.tap ? 'pointer' : 'default');
    const wantBadge = st.editing && s.slot && s.badge;
    if (wantBadge && !sendBadge) {
      sendBadge = h('button', 'gc-badge', sendWrap);
      css(sendBadge, 'width', '18px');
      css(sendBadge, 'height', '18px');
      icon(ICON.undo, 18 * 0.58, sendBadge);
      attachTooltip(sendBadge, ctx, () => (st.send && st.send.badgeTip) || '');
      onTap(sendBadge, () => ctx.send('resetEmpty'));
    } else if (!wantBadge && sendBadge) {
      detach(sendBadge);
      sendBadge = null;
    }
    if (sendBadge) {
      css(sendBadge, 'background', rgba(ctx.theme.accent));
      css(sendBadge, 'box-shadow', `0 4px 8px ${rgba(ctx.theme.accent, 0.3)}`);
    }
  }

  function renderBar() {
    clear(bar);
    const theme = ctx.theme;
    const textColor = rgba(theme.text);
    if (st.mode === 'search') {
      const s = st.search || {};
      css(h('div', '', bar), 'width', '18px');
      const mark = icon(ICON.search, 20, bar);
      css(mark, 'color', rgba(theme.accent));
      css(mark, 'margin-right', '12px');
      const label = h('div', 'gc-bar-label', bar);
      css(label, 'font-size', px(16 * theme.fontScale));
      css(label, 'letter-spacing', px(theme.letterSpacing));
      text(label, s.label || '');
      const prev = h('button', 'gc-iconbtn', bar);
      icon(ICON.keyboard_arrow_up, 24, prev);
      if (!s.prev) S.setAttribute(prev, 'disabled', '');
      onTap(prev, () => { if (s.prev) ctx.send('searchPrev'); });
      const next = h('button', 'gc-iconbtn', bar);
      icon(ICON.keyboard_arrow_down, 24, next);
      if (!s.next) S.setAttribute(next, 'disabled', '');
      onTap(next, () => { if (s.next) ctx.send('searchNext'); });
      css(h('div', '', bar), 'width', '8px');
      return;
    }
    const s = st.selection || {};
    css(h('div', '', bar), 'width', '8px');
    circle(bar, ICON.close, rgba(theme.accent), () => true, () => ctx.send('selCancel'));
    const label = h('div', 'gc-bar-label', bar);
    css(label, 'margin-left', '10px');
    css(label, 'font-size', px(16 * theme.fontScale));
    css(label, 'font-weight', '600');
    css(label, 'letter-spacing', px(theme.letterSpacing));
    text(label, s.label || '');
    circle(bar, ICON.keyboard_double_arrow_up, textColor, () => true, () => ctx.send('selAbove'));
    css(h('div', '', bar), 'width', '6px');
    circle(bar, ICON.keyboard_double_arrow_down, textColor, () => true, () => ctx.send('selBelow'));
    css(h('div', '', bar), 'width', '6px');
    circle(bar, s.allHidden ? ICON.visibility : ICON.visibility_off,
      s.any ? rgba(theme.accent) : rgba(theme.text2, 0.5),
      () => !!s.any, () => ctx.send('selHide'));
    if (s.canDelete) {
      css(h('div', '', bar), 'width', '6px');
      circle(bar, ICON.delete, '#FF5252', () => !!s.any, () => ctx.send('selDelete'));
    }
    css(h('div', '', bar), 'width', '8px');
  }

  let barKey = '';

  function render() {
    const theme = ctx.theme;
    const layout = ctx.layout;
    setClass(root, st.show ? 'gc-cmp' : 'gc-cmp gc-hidden');
    if (!st.show) return;
    css(root, 'left', px(layout.gutter));
    css(root, 'right', px(layout.gutter));
    const barMode = st.mode === 'search' || st.mode === 'selection';
    // The search and selection bars sit in a SafeArea of their own on top of
    // the inset the whole composer rides on, as ChatInputBar's did.
    css(root, 'padding-bottom', px(16 + (barMode ? st.extraBottom : 0)));
    setClass(compose, classes(barMode ? 'gc-hidden' : '', { 'g-skinned': skin.active }));
    setClass(barPill.el, barMode ? 'gc-glass gc-pill' : 'gc-glass gc-pill gc-hidden');

    const radius = px(28 * theme.cornerScale);
    css(pill.el, 'border-radius', radius);
    css(barPill.el, 'border-radius', radius);

    if (barMode) {
      const key = S.jsonStringify([st.mode, st.search, st.selection, ctx.themeKey]);
      if (key !== barKey) {
        barKey = key;
        renderBar();
      }
      const r = S.getBoundingClientRect(barPill.el);
      applyNoise(barPill, theme, r.width, r.height);
      ctx.scheduleReport();
      return;
    }
    barKey = '';

    renderAttachments();

    // Guidance.
    const g = st.guidance;
    setClass(pill.el, classes('gc-glass gc-pill', { 'gc-guiding': !!g }));
    setClass(guide, g ? 'gc-guide' : 'gc-guide gc-hidden');
    if (g) {
      text(guideCaption, g.caption || '');
      css(guideCaption, 'font-size', px(10 * theme.fontScale));
      S.setAttribute(guideInput, 'placeholder', g.placeholder || '');
      css(guideInput, 'font-size', px(14 * theme.fontScale));
      css(guideInput, 'letter-spacing', px(theme.letterSpacing));
    } else if (S.getValue(guideInput)) {
      S.setValue(guideInput, '');
    }

    // Field.
    S.setAttribute(input, 'placeholder', st.placeholder || '');
    css(input, 'font-size', px(16 * theme.fontScale));
    css(input, 'letter-spacing', px(theme.letterSpacing));
    S.setAttribute(input, 'enterkeyhint', st.virtualSend ? 'send' : 'enter');
    if (st.readOnly || st.locked) S.setAttribute(input, 'readonly', '');
    else S.removeAttribute(input, 'readonly');
    if (st.locked) {
      // Editing a message: the composer can't be focused or selected into.
      S.setAttribute(input, 'tabindex', '-1');
      S.setAttribute(guideInput, 'readonly', '');
      S.setAttribute(guideInput, 'tabindex', '-1');
      S.blurRaw(input);
      S.blurRaw(guideInput);
    } else {
      S.removeAttribute(input, 'tabindex');
      S.removeAttribute(guideInput, 'readonly');
      S.removeAttribute(guideInput, 'tabindex');
    }
    setClass(input, classes('gc-input', { 'gc-nocaret': st.locked }));
    css(input, 'pointer-events', st.locked ? 'none' : null);

    renderPins();
    renderSend();
    updateSkin();
    growAll();
    const r = S.getBoundingClientRect(pill.el);
    applyNoise(pill, theme, r.width, r.height);
    ctx.scheduleReport();
  }

  return {
    root,
    apply(next) {
      for (const key in next) st[key] = next[key];
      render();
    },
    render,
    themeChanged() {
      measureLines();
      st.pinsKey = '';
      barKey = '';
      render();
    },
    setText(value) {
      if (S.getValue(input) !== value) {
        S.setValue(input, value);
        const end = value.length;
        if (hadSelection) S.setSelectionRange(input, end, end);
      }
      updateSkin();
      growAll();
    },
    setSkin(tpl) {
      skin.set(tpl);
      setClass(compose, skin.active ? 'g-skinned' : '');
      updateSkin();
      render();
    },
    setGuidanceText(value) {
      if (S.getValue(guideInput) !== value) S.setValue(guideInput, value);
      growAll();
    },
    insertSurround,
    setSendHover(on) {
      setClass(sendWrap, on ? 'gc-send-wrap gc-candidate' : 'gc-send-wrap');
    },
    focus() {
      if (!st.locked) S.focusRaw(input);
    },
    blur() {
      S.blurRaw(input);
      S.blurRaw(guideInput);
    },
    report(out) {
      if (!st.show) return;
      out.composerHeight = S.getBoundingClientRect(root).height;
      const barMode = st.mode === 'search' || st.mode === 'selection';
      out.composer = ctx.rect(barMode ? barPill.el : pill.el);
      if (barMode) return;
      out.send = ctx.rect(sendWrap);
      out.row = ctx.rect(pins);
      const list = st.pins || [];
      const rects = [];
      for (let i = 0; i < list.length; i++) {
        const el = ctx.pinEls && ctx.pinEls[list[i].key];
        if (el) rects[rects.length] = { key: list[i].key, r: ctx.rect(el) };
      }
      out.pins = rects;
    },
  };
}
