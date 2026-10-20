// The chat header: back button, the character block (avatar, name, session)
// and search. Mirrors GlazeAppBar + ChatHeader: a 56px glass pill inset by
// 16/10/16 under the status bar, or edge to edge with square corners on
// desktop ("flush"). Every action is handed to Flutter as an intent; the only
// thing decided here is focusing the search field, which has to happen inside
// the tap that opened it or the soft keyboard does not come up.

import * as S from './safe.js';
import { ICON as I } from './icons.js';
import { h, css, px, text, rgba, setClass, classes, icon, glass, attachGlow, applyNoise, onTap, attachTooltip } from './ui.js';

const ICON = {
  back: I.arrow_back_ios_new_rounded,
  search: I.search,
  searchRounded: I.search_rounded,
  close: I.close,
  closeRounded: I.close_rounded,
};

export function createHeader(ctx) {
  const state = {
    show: false,
    hidden: false,
    flush: false,
    radius: 20,
    title: '',
    session: '',
    avatar: null,
    search: null,
  };
  // What the user did here before Flutter answered: the field opened by a tap
  // stays open until Flutter's state says otherwise.
  let localOpen = null;

  const slot = h('div', 'gc-hdr-slot gc-hidden', ctx.root);
  const bar = glass('gc-hdr', slot);
  attachGlow(bar.el, ctx);

  const lead = h('div', 'gc-hdr-lead', bar.content);
  const back = h('button', 'gc-iconbtn', lead);
  icon(ICON.back, 20, back);
  onTap(back, () => ctx.send('back'));

  const titleBox = h('div', 'gc-hdr-title', bar.content);
  const actions = h('div', 'gc-hdr-actions', bar.content);

  // Character block. On desktop it hugs its content and is wrapped together
  // with the search toggle and the inline field that replaces it.
  const desk = h('div', 'gc-hdr-desk', titleBox);
  const charBlock = h('div', 'gc-char', desk);
  const avatar = h('div', 'gc-avatar', charBlock);
  onTap(avatar, () => {
    if (state.avatar && state.avatar.url) ctx.send('openAvatar');
  });
  const texts = h('div', 'gc-char-texts', charBlock);
  const name = h('div', 'gc-char-name', texts);
  const session = h('div', 'gc-char-session', texts);
  onTap(texts, () => ctx.send('openCharCard'));

  const deskToggle = h('button', 'gc-mini-btn', charBlock);
  css(deskToggle, 'margin-left', '8px');
  icon(ICON.searchRounded, 18, deskToggle);
  attachTooltip(deskToggle, ctx, () => (state.search && state.search.hint) || '');
  onTap(deskToggle, () => openDesktop());

  const deskField = h('div', 'gc-desk-field gc-hidden', desk);
  const deskInput = h('input', '', deskField);
  S.setAttribute(deskInput, 'type', 'text');
  S.setAttribute(deskInput, 'enterkeyhint', 'search');
  S.setAttribute(deskInput, 'autocomplete', 'off');
  S.setAttribute(deskInput, 'spellcheck', 'false');
  const deskClose = h('button', 'gc-mini-btn', deskField);
  icon(ICON.closeRounded, 18, deskClose);
  attachTooltip(deskClose, ctx, () => (state.search && state.search.closeHint) || '');
  onTap(deskClose, () => closeSearch());
  S.on(deskInput, 'input', (e) => {
    if (!e.isTrusted) return;
    ctx.send('searchQuery', { q: S.getInputValue(deskInput), inline: true });
  });
  S.on(deskInput, 'keydown', (e) => {
    if (!e.isTrusted) return;
    if (S.keyOf(e) === 'Escape') {
      S.preventDefault(e);
      closeSearch();
    }
  });

  // Mobile search: the field takes the whole title slot.
  const field = h('div', 'gc-hdr-searchfield gc-hidden', titleBox);
  const input = h('input', '', field);
  S.setAttribute(input, 'type', 'text');
  S.setAttribute(input, 'enterkeyhint', 'search');
  S.setAttribute(input, 'autocomplete', 'off');
  const clearBtn = h('button', 'gc-iconbtn gc-hidden', field);
  icon(ICON.close, 20, clearBtn);
  onTap(clearBtn, () => closeSearch());
  S.on(input, 'input', (e) => {
    if (!e.isTrusted) return;
    const q = S.getInputValue(input);
    setClass(clearBtn, q ? 'gc-iconbtn' : 'gc-iconbtn gc-hidden');
    ctx.send('searchQuery', { q, inline: false });
  });

  const searchBtn = h('button', 'gc-iconbtn', actions);
  icon(ICON.search, 24, searchBtn);
  onTap(searchBtn, () => openMobile());

  function openMobile() {
    localOpen = 'mobile';
    S.setInputValue(input, '');
    render();
    S.focusRaw(input);
    ctx.send('searchOpen');
  }

  function openDesktop() {
    localOpen = 'desktop';
    render();
    S.focusRaw(deskInput);
    ctx.send('searchInlineOpen');
  }

  function closeSearch() {
    localOpen = 'closed';
    S.setInputValue(input, '');
    S.setInputValue(deskInput, '');
    render();
    ctx.send('searchClose');
  }

  function searchOpen() {
    const s = state.search;
    if (!s) return false;
    if (localOpen === 'closed') return false;
    if (localOpen) return true;
    return !!s.open;
  }

  function render() {
    const theme = ctx.theme;
    const layout = ctx.layout;
    setClass(slot, classes('gc-hdr-slot', { 'gc-hidden': !state.show }));
    if (!state.show) return;
    const top = state.flush ? layout.safeTop : layout.safeTop + 10;
    css(slot, 'padding', state.flush
      ? `${px(top)} 0 0 0`
      : `${px(top)} 16px 0 16px`);
    // Hide-on-scroll slides the bar up by one and a half times the header's
    // whole slot (status bar included) while it fades. Animated on the bar
    // itself: an ancestor going translucent would cut the glass off from the
    // page behind it, and the blur would drop out mid-slide.
    css(bar.el, 'transform', state.hidden ? `translateY(${-1.5 * (top + 56)}px)` : 'none');
    css(bar.el, 'opacity', state.hidden ? '0' : '1');
    css(bar.el, 'pointer-events', state.hidden ? 'none' : null);
    const radius = state.flush ? 0 : state.radius * theme.cornerScale;
    css(bar.el, 'border-radius', px(radius));
    css(bar.el, '--gc-bw', '1px');
    css(bar.el, '--gc-bc', rgba(theme.outlineVariant));

    const s = state.search;
    const desktop = s && s.kind === 'desktop';
    const open = searchOpen();
    const mobileOpen = !desktop && open;

    // Character block.
    const a = state.avatar;
    const size = 34;
    css(avatar, 'width', px(size));
    css(avatar, 'height', px(size));
    css(avatar, 'border-radius', px((size / 2) * theme.avatarRoundness));
    const color = (a && a.color) || theme.accent;
    css(avatar, 'background-color', rgba(color, 0.2));
    css(avatar, 'color', rgba(color));
    css(avatar, 'font-size', '16px');
    if (a && a.url) {
      css(avatar, 'background-image', `url("${a.url}")`);
      text(avatar, '');
    } else {
      css(avatar, 'background-image', null);
      text(avatar, (a && a.initial) || '?');
    }
    css(avatar, 'cursor', a && a.url ? 'pointer' : 'default');
    text(name, state.title);
    text(session, state.session);
    css(name, 'font-size', px(16 * theme.fontScale));
    css(name, 'letter-spacing', px(theme.letterSpacing));
    css(session, 'font-size', px(12 * theme.fontScale));
    css(session, 'letter-spacing', px(theme.letterSpacing));

    setClass(charBlock, classes('gc-char', { 'gc-hug': desktop }));
    setClass(desk, classes('gc-hdr-desk', { 'gc-hidden': mobileOpen, 'gc-open': desktop && open }));
    css(desk, 'flex', desktop ? '0 1 auto' : '1 1 0');
    setClass(deskToggle, classes('gc-mini-btn', { 'gc-hidden': !desktop }));
    setClass(deskField, classes('gc-desk-field', { 'gc-hidden': !(desktop && open) }));
    S.setAttribute(deskInput, 'placeholder', (s && s.hint) || '');

    setClass(field, classes('gc-hdr-searchfield', { 'gc-hidden': !mobileOpen }));
    S.setAttribute(input, 'placeholder', (s && s.hint) || '');
    setClass(clearBtn, S.getInputValue(input) ? 'gc-iconbtn' : 'gc-iconbtn gc-hidden');

    // The search action sits at the end of the bar on a phone, and goes away
    // while the field is open — GlazeAppBar keeps its 4px tail either way.
    setClass(searchBtn, classes('gc-iconbtn', { 'gc-hidden': desktop || !s || mobileOpen }));

    const r = S.getBoundingClientRect(bar.el);
    applyNoise(bar, theme, r.width, r.height);
    ctx.scheduleReport();
  }

  return {
    apply(next) {
      for (const key in next) state[key] = next[key];
      // Flutter has caught up with whatever the user opened or closed here.
      const s = state.search;
      if (localOpen && s) {
        const wantOpen = localOpen !== 'closed';
        if (!!s.open === wantOpen) localOpen = null;
      }
      if (s && !s.open && !localOpen) {
        // Closed from Flutter (back gesture): drop what was typed.
        if (S.getInputValue(input)) S.setInputValue(input, '');
        if (S.getInputValue(deskInput)) S.setInputValue(deskInput, '');
      }
      render();
    },
    render,
    report(out) {
      if (!state.show) return;
      out.header = ctx.rect(bar.el);
      out.headerBlock = ctx.rect(charBlock);
      const s = state.search;
      if (s && s.kind === 'desktop') out.searchButton = ctx.rect(deskToggle);
      else if (s && !searchOpen()) out.searchButton = ctx.rect(searchBtn);
    },
    blurAll() {
      S.blurRaw(input);
      S.blurRaw(deskInput);
    },
  };
}
