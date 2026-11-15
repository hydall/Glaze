// The cards under the chat header: the context coverage card (what the next
// prompt carries from memory books and lorebooks) and the live status cards
// (POST-cleaner, Studio cycle, post-generation tasks).
//
// They used to be Flutter widgets laid over the WebView. Drawn here, they sit
// in the page's own stacking order — under the header, which they slide away
// with on scroll, and under the composer and the drawer.
//
// Flutter keeps every decision: what each card says, its colours, when it
// shows and goes, which tab and filter are picked. It sends the cards fully
// resolved — strings translated, colours picked — and a tap comes back as an
// intent. The only state kept here is what is pure presentation: which rows
// of a list are opened, and where each list is scrolled to.
//
// Sections:
//  * `coverage`: the coverage card, or null — see render() below for its
//    fields.
//  * `statusCleaner`, `statusStudio`, `statusPostGen`: one status card each,
//    or null: `{ label, icon, accent, spinner, action: { id, icon, tip,
//    color, size } }`.
//
// The layout report carries `coverageHeight`: the card's collapsed height,
// which the message list keeps clear of at the top — and where the coverage
// card (`coverage`) and the status cards (`status`) are.

import * as S from './safe.js';
import { ICON as I } from './icons.js';
import { h, css, px, rgba, text, setClass, classes, icon, onTap, attachTooltip, clear } from './ui.js';

const STATUS_SLOTS = ['statusCleaner', 'statusStudio', 'statusPostGen'];

// The gap between the header and the first card, as kContextCardHeaderGap.
const HEADER_GAP = 8;
const HEADER_HEIGHT = 56;

/** A spinner: a faint ring and an accent arc going round. */
export function spinner(parent, size, color) {
  const box = h('span', 'gc-spin', parent);
  css(box, 'width', px(size));
  css(box, 'height', px(size));
  const svg = S.createSvg('svg');
  S.setAttribute(svg, 'viewBox', '0 0 24 24');
  S.setAttribute(svg, 'width', S.stringFn(size));
  S.setAttribute(svg, 'height', S.stringFn(size));
  const track = S.createSvg('circle');
  const arc = S.createSvg('circle');
  each([track, arc], (c) => {
    S.setAttribute(c, 'cx', '12');
    S.setAttribute(c, 'cy', '12');
    S.setAttribute(c, 'r', '9.5');
    S.setAttribute(c, 'fill', 'none');
    S.setAttribute(c, 'stroke-width', '3');
    S.appendChild(svg, c);
  });
  S.setAttribute(track, 'stroke', rgba(color, 0.18));
  S.setAttribute(arc, 'stroke', rgba(color));
  S.setAttribute(arc, 'stroke-linecap', 'round');
  S.setAttribute(arc, 'class', 'gc-spin-arc');
  S.appendChild(box, svg);
  return box;
}

function str(v) {
  return v == null ? '' : S.stringFn(v);
}

function list(v) {
  return S.isArray(v) ? v : [];
}

/** Calls [fn] on each item of [v] (an array, or nothing), by index. */
function each(v, fn) {
  const a = list(v);
  for (let i = 0; i < a.length; i++) fn(a[i], i);
}

export function createCards(ctx) {
  const root = h('div', 'gc-cards', ctx.root);
  const coverageSlot = h('div', 'gc-cov-slot', root);
  const statusEls = S.dict();
  const statusButtons = S.dict();
  const status = S.dict();
  each(STATUS_SLOTS, (slot) => {
    statusEls[slot] = h('div', 'gc-hidden', root);
    status[slot] = null;
  });

  let coverage = null;
  let card = null;
  let head = null;
  // Opened rows by list, and the list each set belongs to: a new memory run
  // closes them all, as the Flutter section did.
  const opened = S.dict();
  const scrollTops = S.dict();
  let listEl = null;
  let listKey = '';
  let filterEl = null;
  let filterScroll = 0;

  /* ---------- Status cards ---------- */

  function renderStatus(slot) {
    const el = statusEls[slot];
    const spec = status[slot];
    clear(el);
    statusButtons[slot] = null;
    if (!spec || typeof spec !== 'object') {
      setClass(el, 'gc-hidden');
      return;
    }
    const theme = ctx.theme;
    const accent = spec.accent || theme.accent;
    setClass(el, 'gc-status gc-live');
    css(el, 'background-color', rgba(theme.surface || theme.fillSurface, 0.92));
    css(el, 'border-color', rgba(accent, 0.35));
    if (spec.spinner) spinner(el, 18, accent);
    else css(icon(spec.icon, 18, el), 'color', rgba(accent));
    text(h('div', 'gc-status-label', el), str(spec.label));
    const action = spec.action;
    if (action && action.id) {
      const btn = h('button', 'gc-status-btn', el);
      statusButtons[slot] = btn;
      S.setAttribute(btn, 'type', 'button');
      const size = action.size || 18;
      css(btn, 'color', rgba(action.color || theme.onSurfaceVariant));
      icon(action.icon, size, btn);
      const id = str(action.id);
      onTap(btn, () => ctx.send('statusAction', { id }));
      attachTooltip(btn, ctx, () => str(action.tip));
    }
  }

  /* ---------- Coverage card ---------- */

  function rememberScroll() {
    if (listEl && listKey) scrollTops[listKey] = S.getScrollTop(listEl);
    if (filterEl) filterScroll = S.getScrollLeft(filterEl);
  }

  function iconBtn(parent, spec, onPress) {
    const btn = h('button', 'gc-cov-iconbtn', parent);
    S.setAttribute(btn, 'type', 'button');
    icon(spec.icon, spec.size || 18, btn);
    onTap(btn, onPress);
    attachTooltip(btn, ctx, () => str(spec.tip));
    return btn;
  }

  function line(parent, l, className) {
    const el = h('div', className || 'gc-cov-line', parent);
    text(el, str(l.t));
    if (l.c) css(el, 'color', rgba(l.c));
    if (l.b) css(el, 'font-weight', '600');
    if (l.bb) css(el, 'font-weight', '700');
    return el;
  }

  function toggleRow(key) {
    const set = opened[listKey] || (opened[listKey] = S.dict());
    if (set[key]) delete set[key];
    else set[key] = true;
    render();
  }

  function isOpen(key) {
    const set = opened[listKey];
    return !!(set && set[key]);
  }

  /** A memory candidate: verdict icon, title, the short reason, cost and score. */
  function memoryRow(parent, row) {
    const theme = ctx.theme;
    const key = str(row.k);
    const open = isOpen(key);
    const wrap = h('div', 'gc-mem-row', parent);
    const tap = h('div', 'gc-mem-tap gc-live gc-click', wrap);
    onTap(tap, () => toggleRow(key));
    const lead = row.lead || {};
    css(icon(lead.icon, 16, tap), 'color', rgba(lead.color || theme.onSurfaceVariant));
    const texts = h('div', 'gc-mem-texts', tap);
    const title = h('div', open ? 'gc-mem-title gc-clamp4' : 'gc-mem-title gc-ellipsis', texts);
    text(title, str(row.title));
    each(row.sub, (l) => line(texts, l, 'gc-mem-sub gc-ellipsis'));
    css(icon(open ? I.expand_less_rounded : I.expand_more_rounded, 16, tap), 'color', rgba(theme.onSurfaceVariant));
    text(h('div', 'gc-mem-trail', tap), str(row.trail));
    if (!open) return;
    const details = h('div', 'gc-mem-details', wrap);
    each(row.details, (l) => line(details, l));
  }

  /** A lorebook entry: status rail, title, cost; why it is (not) in, on tap. */
  function entryRow(parent, row) {
    const theme = ctx.theme;
    const key = str(row.k);
    const open = isOpen(key);
    const tile = h('div', 'gc-lb-row gc-live gc-click', parent);
    css(tile, 'background-color', rgba(row.bg));
    onTap(tile, () => toggleRow(key));
    css(h('div', 'gc-lb-rail', tile), 'background-color', rgba(row.rail));
    const body = h('div', 'gc-lb-body', tile);
    const top = h('div', 'gc-lb-top', body);
    const title = h('div', 'gc-lb-title gc-ellipsis', top);
    text(title, str(row.title));
    css(title, 'color', rgba(row.titleColor || theme.onSurface));
    text(h('div', 'gc-lb-tok', top), str(row.trail));
    css(icon(open ? I.expand_less_rounded : I.expand_more_rounded, 16, top), 'color', rgba(theme.onSurfaceVariant));
    const sub = list(row.sub);
    if (sub.length) {
      const subEl = h('div', 'gc-lb-sub', body);
      for (let i = 0; i < sub.length; i++) {
        if (i > 0) css(text2(subEl, ' · '), 'color', rgba(theme.onSurfaceVariant, 0.85));
        line(subEl, sub[i], 'gc-lb-subpart gc-ellipsis');
      }
    }
    if (!open) return;
    const reasons = h('div', 'gc-lb-reasons', body);
    each(row.details, (l) => line(reasons, l));
    each(row.badges, (group) => {
      const wrap = h('div', 'gc-lb-badges', body);
      each(group, (b) => {
        const badge = h('span', 'gc-badge', wrap);
        text(badge, str(b.t));
        css(badge, 'color', rgba(b.c));
        css(badge, 'background-color', rgba(b.c, 0.14));
      });
    });
  }

  function text2(parent, value) {
    const el = h('span', 'gc-lb-sep', parent);
    text(el, value);
    return el;
  }

  function scroller(parent, key, maxHeight) {
    const el = h('div', 'gc-cov-list gc-live', parent);
    css(el, 'max-height', px(maxHeight));
    listEl = el;
    listKey = key;
    return el;
  }

  function memoryBody(parent, b) {
    const theme = ctx.theme;
    if (b.warning) {
      const warn = h('div', 'gc-cov-warn', parent);
      const c = b.warnColor || [255, 171, 64, 1];
      css(warn, 'background-color', rgba(c, 0.14));
      css(warn, 'border-color', rgba(c, 0.5));
      css(icon(I.warning_amber_rounded, 16, warn), 'color', rgba(c));
      text(h('div', 'gc-cov-warn-text', warn), str(b.warning));
    }
    const top = h('div', 'gc-cov-chiprow', parent);
    const chips = h('div', 'gc-cov-chips', top);
    each(b.chips, (label) => {
      const chip = h('span', 'gc-cov-chip', chips);
      text(chip, str(label));
      css(chip, 'background-color', rgba(theme.accent, 0.12));
    });
    if (b.graph) iconBtn(top, b.graph, () => ctx.send('coverageAction', { id: 'graph' }));
    const rows = list(b.rows);
    if (!rows.length) return;
    const el = scroller(parent, `m:${str(b.key)}`, 280);
    css(el, 'margin-top', '8px');
    each(rows, (row) => memoryRow(el, row));
  }

  function lorebookBody(parent, b) {
    const theme = ctx.theme;
    const kind = b.kind;
    if (kind === 'loading') {
      const box = h('div', 'gc-cov-loading', parent);
      spinner(box, 28, theme.accent);
      return;
    }
    if (kind === 'error' || kind === 'empty') {
      const msg = h('div', kind === 'error' ? 'gc-cov-msg gc-clamp3' : 'gc-cov-msg', parent);
      text(msg, str(b.text));
      css(msg, 'color', rgba(b.color || theme.onSurfaceVariant));
      return;
    }
    const stats = h('div', 'gc-cov-stats', parent);
    each(b.stats, (s) => {
      const stat = h('div', 'gc-cov-stat', stats);
      css(h('span', 'gc-cov-dot', stat), 'background-color', rgba(s.color));
      text(h('span', 'gc-cov-statv', stat), str(s.value));
      text(h('span', 'gc-cov-statl', stat), str(s.label));
    });
    const bar = h('div', 'gc-cov-filters gc-live', parent);
    filterEl = bar;
    const filters = list(b.filters);
    for (let i = 0; i < filters.length; i++) {
      const on = i === b.filter;
      const chip = h('button', on ? 'gc-cov-filter gc-on' : 'gc-cov-filter', bar);
      S.setAttribute(chip, 'type', 'button');
      text(chip, str(filters[i]));
      const index = i;
      onTap(chip, () => {
        rememberScroll();
        ctx.send('coverageFilter', { i: index });
      });
    }
    const el = scroller(parent, `l:${str(b.filter)}`, 240);
    const rows = list(b.rows);
    if (!rows.length) {
      const msg = h('div', 'gc-cov-msg gc-cov-msg-list', el);
      text(msg, str(b.empty));
      return;
    }
    each(rows, (row) => entryRow(el, row));
  }

  /**
   * The card. `coverage`: `{ hidden, expanded, title, pills: [{ icon, value,
   * total, color }], tabs: [{ label, icon }], tab, label, actions: [{ id,
   * icon, tip, size }], body }`. `body` is the memory section (`kind:
   * 'memory'`) or the lorebook one (`'lorebook'`, `'loading'`, `'error'`,
   * `'empty'`).
   */
  function render() {
    rememberScroll();
    listEl = null;
    filterEl = null;
    clear(coverageSlot);
    card = null;
    head = null;
    const c = coverage;
    if (!c || typeof c !== 'object') return;
    const theme = ctx.theme;
    card = h('div', 'gc-cov gc-live', coverageSlot);
    css(card, 'background-color', rgba(theme.surface || theme.fillSurface, 0.94));
    css(card, 'border-color', rgba(theme.accent, 0.22));

    head = h('div', 'gc-cov-head gc-click', card);
    onTap(head, () => ctx.send('coverageToggle'));
    css(icon(I.layers_outlined, 18, head), 'color', rgba(theme.accent));
    const title = h('div', 'gc-cov-title', head);
    text(title, str(c.title));
    h('div', 'gc-cov-spacer', head);
    each(c.pills, (p) => {
      const pill = h('div', 'gc-cov-pill', head);
      css(pill, 'background-color', rgba(p.color, 0.12));
      css(icon(p.icon, 12, pill), 'color', rgba(p.color));
      text(h('span', 'gc-cov-pillv', pill), str(p.value));
      text(h('span', 'gc-cov-pillt', pill), `/${str(p.total)}`);
    });
    css(icon(c.expanded ? I.expand_less_rounded : I.expand_more_rounded, 20, head), 'color', rgba(theme.onSurfaceVariant));

    if (c.expanded) {
      const body = h('div', 'gc-cov-body', card);
      const bar = h('div', 'gc-cov-toolbar', body);
      const tabs = list(c.tabs);
      if (tabs.length > 1) {
        const strip = h('div', 'gc-cov-tabs', bar);
        for (let i = 0; i < tabs.length; i++) {
          const on = i === c.tab;
          const tab = h('button', on ? 'gc-cov-tab gc-on' : 'gc-cov-tab', strip);
          S.setAttribute(tab, 'type', 'button');
          icon(tabs[i].icon, 16, tab);
          text(h('span', 'gc-cov-tabl', tab), str(tabs[i].label));
          const index = i;
          onTap(tab, () => ctx.send('coverageTab', { i: index }));
        }
      } else {
        text(h('div', 'gc-cov-label', bar), str(c.label));
      }
      each(c.actions, (a) => {
        const id = str(a.id);
        iconBtn(bar, a, () => ctx.send('coverageAction', { id }));
      });
      const b = c.body || {};
      if (b.kind === 'memory') memoryBody(body, b);
      else lorebookBody(body, b);
    }

    if (listEl && listKey && scrollTops[listKey]) S.setScrollTop(listEl, scrollTops[listKey]);
    if (filterEl && filterScroll) S.setScrollLeft(filterEl, filterScroll);
    if (listEl) {
      const el = listEl;
      const key = listKey;
      S.on(el, 'scroll', () => { scrollTops[key] = S.getScrollTop(el); }, { passive: true });
    }
    place();
  }

  /** Where the cards sit: under the header, inside the chat column. */
  function place() {
    const layout = ctx.layout;
    const top = (layout.safeTop || 0) + 10 + HEADER_HEIGHT + HEADER_GAP;
    const side = px(12 + (layout.gutter || 0));
    css(root, 'top', px(top));
    css(root, 'left', side);
    css(root, 'right', side);
    if (!card) return;
    // Hides with the header: the same curve, and the same distance in pixels
    // as the header travels (one and a half times its slot), so the two go
    // and come back as one.
    const hidden = !!(coverage && coverage.hidden);
    css(card, 'transform', hidden ? `translateY(${-1.5 * top}px)` : 'none');
    css(card, 'opacity', hidden ? '0' : '1');
    css(card, 'pointer-events', hidden ? 'none' : null);
  }

  return {
    root,
    sections: STATUS_SLOTS,
    apply(section, value) {
      if (section === 'coverage') {
        // A new memory run: its rows start closed.
        const prev = coverage && coverage.body && coverage.body.key;
        const next = value && value.body && value.body.key;
        if (prev && next && prev !== next) delete opened[`m:${str(prev)}`];
        coverage = value && typeof value === 'object' ? value : null;
        render();
        return;
      }
      if (S.hasOwn(status, section)) {
        status[section] = value && typeof value === 'object' ? value : null;
        renderStatus(section);
      }
    },
    themeChanged() {
      render();
      each(STATUS_SLOTS, renderStatus);
    },
    place,
    report(out) {
      if (head) {
        out.coverageHeight = S.mathRound(S.getBoundingClientRect(head).height + 2);
        out.coverage = ctx.rect(card);
      }
      const shown = [];
      each(STATUS_SLOTS, (slot) => {
        if (!status[slot]) return;
        const btn = statusButtons[slot];
        S.put(shown, { slot, r: ctx.rect(statusEls[slot]), action: btn ? ctx.rect(btn) : null });
      });
      if (shown.length) out.status = shown;
    },
  };
}
