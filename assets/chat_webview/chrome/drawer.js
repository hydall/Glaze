// The chat drawer on a phone: two tabs (Tools, Actions) of cards in a
// three-column grid under a tab strip, an edit pencil and a drag handle.
// Mirrors ChatDrawerPanel + MagicDrawerPanel + QuickRepliesPanel. Flutter
// owns the cards — what is in each tab, in which order, what a card's status
// line says and what a tap does; this draws them and reports taps, edits and
// drags back.

import * as S from './safe.js';
import { ICON } from './icons.js';
import {
  h, css, px, text, setClass, classes, icon, drawIcon, onTap, attachTooltip, clear,
} from './ui.js';
import { mount } from './template.js';

const HANDLE_DISTANCE = 48;
const HANDLE_VELOCITY = 300; // px/s
const SWIPE_DISTANCE = 40;

export function createDrawer(ctx, composer) {
  const st = {
    show: false,
    tab: 0,
    editing: false,
    tabs: [],
    tools: { loading: false, cards: [], add: null },
    actions: { loading: false, cards: [], add: null },
    tips: {},
    effects: true,
  };
  const keys = ['', ''];
  // A theme's own card and tab (template.js): drawn inside the drawer's own
  // card and tab, which keep the taps, the drag and the edit badges.
  const skin = { card: null, tab: null };

  const root = h('div', 'gc-drw gc-hidden', ctx.root);
  const body = h('div', 'gc-drw-body', root);
  const panes = [h('div', 'gc-drw-tab', body), h('div', 'gc-drw-tab', body)];
  const grids = [h('div', 'gc-grid', panes[0]), h('div', 'gc-grid', panes[1])];
  const loaders = [h('div', 'gc-drw-loading gc-hidden', body), h('div', 'gc-drw-loading gc-hidden', body)];
  h('div', 'gc-spinner', loaders[0]);
  h('div', 'gc-spinner', loaders[1]);
  const edge = h('div', 'gc-drw-edge', root);
  h('div', 'gc-drw-tint', root);

  const head = h('div', 'gc-drw-head', root);
  const tabsEl = h('div', 'gc-tabs', head);
  const tabEls = [];
  const edit = h('button', 'gc-edit', head);
  const editMark = icon(ICON.edit_outlined, 18, edit);
  attachTooltip(edit, ctx, () => (st.editing ? st.tips.done : st.tips.edit) || '');
  onTap(edit, () => ctx.send('drawerEditToggle'));

  // The handle is above the header so its vertical swipe wins where the two
  // overlap; it lets taps through to the tabs (pointer events only, no click
  // handler).
  const handle = h('div', 'gc-handle', root);
  let handleStart = null;
  S.on(handle, 'pointerdown', (e) => {
    if (!e.isTrusted) return;
    handleStart = { y: S.clientY(e), t: S.now(), id: S.pointerId(e) };
    try { S.setPointerCapture(handle, handleStart.id); } catch (_) {}
  });
  S.on(handle, 'pointerup', (e) => {
    const start = handleStart;
    handleStart = null;
    if (!start || !e.isTrusted) return;
    const dy = S.clientY(e) - start.y;
    const dt = S.mathMax(1, S.now() - start.t) / 1000;
    if (dy > HANDLE_DISTANCE || (dy > 4 && dy / dt > HANDLE_VELOCITY)) {
      ctx.send('drawerClose');
      return;
    }
    // Not a swipe: a tap meant for the tab under the handle.
    if (S.mathAbs(dy) < 6) tapTabAt(S.clientX(e), S.clientY(e));
  });
  S.on(handle, 'pointercancel', () => { handleStart = null; });

  function tapTabAt(x, y) {
    const er = S.getBoundingClientRect(edit);
    if (x >= er.left && x <= er.right && y >= er.top && y <= er.bottom) {
      ctx.send('drawerEditToggle');
      return;
    }
    for (let i = 0; i < tabEls.length; i++) {
      const r = S.getBoundingClientRect(tabEls[i]);
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        selectTab(i);
        return;
      }
    }
  }

  // A horizontal swipe on the strip moves to the next / previous tab.
  let swipe = null;
  S.on(tabsEl, 'pointerdown', (e) => {
    if (!e.isTrusted) return;
    swipe = { x: S.clientX(e), y: S.clientY(e) };
  });
  S.on(tabsEl, 'pointerup', (e) => {
    const start = swipe;
    swipe = null;
    if (!start || !e.isTrusted) return;
    const dx = S.clientX(e) - start.x;
    const dy = S.clientY(e) - start.y;
    if (S.mathAbs(dx) < SWIPE_DISTANCE || S.mathAbs(dx) < S.mathAbs(dy)) return;
    const next = st.tab + (dx < 0 ? 1 : -1);
    if (next >= 0 && next < st.tabs.length) selectTab(next);
  });

  function selectTab(i) {
    if (i === st.tab) return;
    st.tab = i;
    renderTabs();
    ctx.send('drawerTab', { i });
  }

  let tabsKey = '';
  function renderTabs() {
    const key = S.jsonStringify([st.tabs, st.tab]);
    if (key !== tabsKey) {
      tabsKey = key;
      clear(tabsEl);
      tabEls.length = 0;
      for (let i = 0; i < st.tabs.length; i++) {
        const t = st.tabs[i];
        const tab = h('div', classes('gc-tab', { 'gc-active': i === st.tab, 'g-skinned': !!skin.tab }), tabsEl);
        S.put(tabEls, tab);
        if (skin.tab) {
          mount(skin.tab, { label: t.label || '', icon: t.icon || null, active: i === st.tab, index: i }, tab, null, {});
        } else {
          const inner = h('div', 'gc-tab-inner', tab);
          icon(t.icon, 17, inner);
          const label = h('span', 'gc-tab-label', inner);
          text(label, t.label);
        }
        onTap(tab, () => selectTab(i));
      }
    }
    for (let i = 0; i < panes.length; i++) {
      const active = i === st.tab;
      css(panes[i], 'visibility', active ? 'visible' : 'hidden');
      css(panes[i], 'pointer-events', active ? 'auto' : 'none');
      const loading = (i === 0 ? st.tools : st.actions).loading;
      setClass(loaders[i], active && loading ? 'gc-drw-loading' : 'gc-drw-loading gc-hidden');
    }
    setClass(edit, classes('gc-edit', { 'gc-on': st.editing }));
    drawIcon(editMark, st.editing ? ICON.check : ICON.edit_outlined, 18);
  }

  function badge(parent, kind, onPress) {
    const b = h('button', 'gc-badge', parent);
    const color = kind === 'hide' ? '#607D8B' : '#FF3B30';
    css(b, 'width', '24px');
    css(b, 'height', '24px');
    css(b, 'background', color);
    css(b, 'box-shadow', kind === 'hide'
      ? '0 4px 8px rgba(96,125,139,0.3)'
      : '0 4px 8px rgba(255,59,48,0.3)');
    icon(kind === 'hide' ? ICON.visibility_off : ICON.close, 24 * 0.58, b);
    attachTooltip(b, ctx, () => (kind === 'hide' ? st.tips.hide : st.tips.delete) || '');
    onTap(b, onPress);
    return b;
  }

  function card(grid, item, opts) {
    const el = h('div', 'gc-card', grid);
    const cardState = { pressed: false, hovered: false, ghosted: false };
    const paint = () => setClass(el, classes('gc-card', {
      'gc-editing': st.editing && !opts.add,
      'gc-pressed': cardState.pressed,
      'gc-hovered': cardState.hovered,
      'gc-ghosted': cardState.ghosted,
      'gc-add': !!opts.add,
      'g-skinned': !!skin.card,
    }));
    paint();
    if (skin.card) {
      mount(skin.card, {
        label: item.label || '',
        status: item.status == null ? '' : item.status,
        icon: item.icon || null,
        statusIcon: item.statusIcon || null,
        kind: opts.add ? 'add' : item.kind || '',
        key: item.key || '',
        add: !!opts.add,
        editing: st.editing,
        tab: st.tab === 0 ? 'tools' : 'actions',
      }, el, null, {});
    } else {
      const row = h('div', 'gc-card-row', el);
      icon(item.icon, 20, row);
      const texts = h('div', 'gc-card-texts', row);
      const label = h('div', 'gc-card-label', texts);
      text(label, item.label);
      if (item.status != null && item.status !== '') {
        const status = h('div', 'gc-card-status', texts);
        if (item.statusIcon) icon(item.statusIcon, 10, status);
        text(h('span', 'gc-st', status), item.status);
      }
    }
    if (st.editing && item.badge) {
      badge(el, item.badge, () => opts.onBadge && opts.onBadge());
    }
    S.on(el, 'pointerdown', (e) => {
      if (!e.isTrusted || opts.add) return;
      cardState.pressed = true;
      paint();
    });
    const unpress = () => {
      if (!cardState.pressed) return;
      cardState.pressed = false;
      paint();
    };
    S.on(el, 'pointerup', unpress);
    S.on(el, 'pointercancel', unpress);
    S.on(el, 'pointerleave', unpress);
    onTap(el, () => opts.onTap());
    if (opts.drag) {
      ctx.drag.source(el, {
        payload: () => item.key,
        longPress: true,
        enabled: () => true,
        start: () => {
          unpress();
          setClass(panes[st.tab], 'gc-drw-tab gc-dragging');
          if (!st.editing) ctx.send('drawerEditStart');
        },
        end: () => setClass(panes[st.tab], 'gc-drw-tab'),
        ghosted: (on) => {
          cardState.ghosted = on;
          paint();
        },
      });
    }
    if (opts.accepts) {
      ctx.drag.target(el, {
        group: opts.group,
        depth: 2,
        accepts: opts.accepts,
        enter: () => { cardState.hovered = true; paint(); },
        leave: () => { cardState.hovered = false; paint(); },
        drop: opts.drop,
      });
    }
    return el;
  }

  function renderTools() {
    const data = st.tools;
    const key = S.jsonStringify([data, st.editing, ctx.layout.safeBottom]);
    if (key === keys[0]) return;
    keys[0] = key;
    const grid = grids[0];
    clear(grid);
    ctx.drag.removeGroup('tools');
    css(grid, 'padding-bottom', px(16 + ctx.layout.safeBottom));
    const cards = data.cards || [];
    const toolKeys = {};
    for (let i = 0; i < cards.length; i++) if (cards[i].kind === 'tool') toolKeys[cards[i].key] = true;
    for (let i = 0; i < cards.length; i++) {
      const item = cards[i];
      const isTool = item.kind === 'tool';
      card(grid, item, {
        onTap: () => ctx.send(isTool ? 'toolTap' : 'pluginTap', { id: item.id, key: item.key }),
        onBadge: () => ctx.send('toolDelete', { id: item.id }),
        drag: isTool,
        group: 'tools',
        accepts: isTool
          ? (payload) => payload !== item.key && toolKeys[payload] === true
          : null,
        drop: (payload) => ctx.send('toolMove', { moving: payload, target: item.key }),
      });
    }
    if (data.add) {
      card(grid, { icon: ICON.add, label: data.add.label }, {
        add: true,
        onTap: () => ctx.send('toolAdd'),
      });
    }
  }

  function renderActions() {
    const data = st.actions;
    const key = S.jsonStringify([data, st.editing, ctx.layout.safeBottom]);
    if (key === keys[1]) return;
    keys[1] = key;
    const grid = grids[1];
    clear(grid);
    ctx.drag.removeGroup('actions');
    css(grid, 'padding-bottom', px(16 + ctx.layout.safeBottom));
    const cards = data.cards || [];
    const replyKeys = {};
    for (let i = 0; i < cards.length; i++) if (cards[i].kind === 'reply') replyKeys[cards[i].key] = true;
    for (let i = 0; i < cards.length; i++) {
      const item = cards[i];
      const kind = item.kind;
      card(grid, item, {
        onTap: () => {
          if (kind === 'action') {
            // An insert card types where the caret was and brings the
            // keyboard back — inside this tap, or the keyboard stays down.
            if (item.insert && !st.editing) composer.insertSurround(item.insert);
            ctx.send('actionTap', { id: item.id });
          } else if (kind === 'reply') {
            ctx.send('replyTap', { id: item.id });
          } else {
            ctx.send('pluginTap', { id: item.id, key: item.key });
          }
        },
        onBadge: () => ctx.send(item.badge === 'hide' ? 'actionHide' : 'replyDelete', { id: item.id }),
        drag: kind === 'action' || kind === 'reply',
        group: 'actions',
        // The fixed block of composer actions is not a drop target: it has a
        // home order, and the only move it takes is up into the row.
        accepts: kind === 'reply'
          ? (payload) => payload !== item.key && replyKeys[payload] === true
          : null,
        drop: (payload) => ctx.send('replyMove', { moving: payload, target: item.key }),
      });
    }
    if (data.add) {
      card(grid, { icon: ICON.add, label: data.add.label }, {
        add: true,
        onTap: () => ctx.send('actionsAdd'),
      });
    }
  }

  function render() {
    const layout = ctx.layout;
    const d = layout.drawer || {};
    const visible = st.show && d.show;
    setClass(root, classes(visible ? 'gc-drw' : 'gc-drw gc-hidden', { 'g-skinned': !!(skin.card || skin.tab) }));
    // Build the tabs and cards while the drawer is still shut. Doing it here,
    // on the frame the drawer opens, made the first open draw the slide first
    // and the cards a beat later — or, when the page's main thread was busy,
    // made the whole open look like a flat background with no animation.
    ctx.drag.whenIdle(() => {
      renderTabs();
      renderTools();
      renderActions();
    });
    if (!visible) return;
    // The height comes from the last keyboard, which can be taller than the
    // page (some Android keyboards report the full window). Let the drawer
    // outgrow the viewport and its own header, tabs and cards end up above the
    // screen, leaving nothing but its background. Keep it below the status
    // bar; a taller request is clamped, not trusted.
    const viewport = S.mathMax(0, layout.viewportH || S.viewportHeight() || 0);
    const safeTop = S.mathMax(0, layout.safeTop || 0);
    const available = viewport > 0
      ? S.mathMax(0, viewport - safeTop)
      : Number.POSITIVE_INFINITY;
    const height = S.mathMin(S.mathMax(0, d.height || 0), available);
    css(root, 'left', px(layout.gutter));
    css(root, 'right', px(layout.gutter));
    css(root, 'height', px(height));
    css(root, 'bottom', px(-height * (1 - d.progress) - ctx.shrink()));
    setClass(edge, st.effects && !ctx.theme.batterySaver ? 'gc-drw-edge' : 'gc-drw-edge gc-flat');
  }

  return {
    apply(next) {
      for (const key in next) st[key] = next[key];
      render();
    },
    render,
    themeChanged() {
      keys[0] = '';
      keys[1] = '';
      tabsKey = '';
      render();
    },
    setSkin(card, tab) {
      skin.card = card && !card.empty ? card : null;
      skin.tab = tab && !tab.empty ? tab : null;
      setClass(root, classes(st.show && (ctx.layout.drawer || {}).show ? 'gc-drw' : 'gc-drw gc-hidden', { 'g-skinned': !!(skin.card || skin.tab) }));
      keys[0] = '';
      keys[1] = '';
      tabsKey = '';
      render();
    },
    report(out) {
      const d = ctx.layout.drawer || {};
      if (st.show && d.show) out.drawer = ctx.rect(root);
    },
  };
}
