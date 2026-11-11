// The composer's strip on a phone held sideways: a full-height glass column
// down one side of the screen — the side the app's tab rail is on — like the
// tab rail itself. It holds the composer's pinned buttons, spread evenly; when
// the drawer opens it holds the drawer instead, and the two cross-fade.
//
// It owns no buttons of its own: the composer moves its pins into `pins` and
// the drawer moves its root into `drawer` (composer.js `arrange`, drawer.js
// `render`), so their taps, drags and reports carry over unchanged. Flutter
// says where it goes in the layout's `strip` ({ side, edge, width }); without
// one there is no strip and both stay where they are on an upright phone.

import * as S from './safe.js';
import { h, css, px, setClass, glass, applyNoise } from './ui.js';

export function createStrip(ctx) {
  const surface = glass('gc-strip gc-hidden', ctx.root);
  const pins = h('div', 'gc-strip-slot', surface.content);
  const drawer = h('div', 'gc-strip-slot', surface.content);
  let shown = false;

  /**
   * Places the strip for [layout] and cross-fades its two slots by the
   * drawer's progress. [visible] is false while the composer is hidden or
   * shows its search / selection bar.
   */
  function place(visible) {
    const layout = ctx.layout;
    const s = layout.strip;
    const on = !!(s && visible);
    if (on !== shown) {
      shown = on;
      setClass(surface.el, on ? 'gc-glass gc-strip' : 'gc-glass gc-strip gc-hidden');
    }
    if (!on) return;
    const left = s.side === 'left';
    const bottom = S.mathMax(0, (layout.inset || 0) - ctx.shrink());
    css(surface.el, 'top', px((layout.safeTop || 0) + 10));
    css(surface.el, 'bottom', px(bottom + 10));
    css(surface.el, 'width', px(s.width || 76));
    css(surface.el, left ? 'left' : 'right', px(s.edge || 10));
    css(surface.el, left ? 'right' : 'left', '');
    css(surface.el, 'border-radius', px(20 * ctx.theme.cornerScale));
    const d = layout.drawer || {};
    const t = d.show ? S.mathMin(1, S.mathMax(0, d.progress || 0)) : 0;
    css(pins, 'opacity', String(1 - t));
    css(pins, 'visibility', t >= 1 ? 'hidden' : 'visible');
    css(drawer, 'opacity', String(t));
    css(drawer, 'visibility', t <= 0 ? 'hidden' : 'visible');
    const r = S.getBoundingClientRect(surface.el);
    applyNoise(surface, ctx.theme, r.width, r.height);
  }

  return {
    pins,
    drawer,
    place,
    /** Whether the layout asks for a strip at all. */
    active: () => !!ctx.layout.strip,
    report(out) {
      if (shown) out.strip = ctx.rect(surface.el);
    },
  };
}
