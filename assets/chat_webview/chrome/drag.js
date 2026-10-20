// Drag and drop between the drawer's grids and the composer's row — what
// LongPressDraggable / Draggable / DragTarget<ComposerPin> did in Flutter.
//
// A payload is a pin key (`tool:inspector`, `reply:qr-1`, `action:attach`).
// Targets are hit-tested at the pointer, innermost first; the first one that
// accepts the payload is the active one, as in Flutter's drag avatar.

import * as S from './safe.js';
import { h, css, px, detach, suppressTaps } from './ui.js';

const SLOP = 18; // kTouchSlop
const LONG_PRESS_MS = 300;
const cloneNode = Function.prototype.call.bind(Node.prototype.cloneNode);

export function createDrag(ctx) {
  const targets = []; // {el, group, depth, accepts, enter, leave, drop}
  let drag = null; // the drag in flight
  let pending = null; // a press that may still become one
  const deferred = []; // renders held back until the drag ends

  // Scrolling has to be stopped for a drag that has started; a passive-false
  // listener on the chrome's root is the one place to do it.
  S.on(ctx.root, 'touchmove', (e) => {
    if (drag) S.preventDefault(e);
  }, { passive: false });

  // Plain index loops throughout: an array method patched by a message
  // script would be handed these arrays, and with them the chrome's nodes.
  function removeGroup(group) {
    let w = 0;
    for (let i = 0; i < targets.length; i++) {
      if (targets[i].group !== group) targets[w++] = targets[i];
    }
    targets.length = w;
  }

  function target(el, opts) {
    targets[targets.length] = {
      el,
      group: opts.group,
      depth: opts.depth || 0,
      accepts: opts.accepts,
      enter: opts.enter || (() => {}),
      leave: opts.leave || (() => {}),
      drop: opts.drop,
    };
  }

  function hit(x, y, payload) {
    let best = null;
    for (let i = 0; i < targets.length; i++) {
      const t = targets[i];
      if (!S.getIsConnected(t.el)) continue;
      const r = S.getBoundingClientRect(t.el);
      if (r.width <= 0 || r.height <= 0) continue;
      if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
      if (!t.accepts(payload)) continue;
      if (!best || t.depth > best.depth) best = t;
    }
    return best;
  }

  function begin(p, x, y) {
    const opts = p.opts;
    const r = S.getBoundingClientRect(p.el);
    const ghost = h('div', 'gc-ghost', ctx.root);
    const copy = cloneNode(opts.ghostSource ? opts.ghostSource() : p.el, true);
    S.appendChild(ghost, copy);
    css(ghost, 'width', px(r.width));
    css(ghost, 'height', px(r.height));
    drag = {
      payload: opts.payload(),
      el: p.el,
      opts,
      ghost,
      dx: x - r.left,
      dy: y - r.top,
      top: r.top,
      active: null,
      pointerId: p.pointerId,
    };
    if (opts.ghosted) opts.ghosted(true);
    if (opts.start) opts.start();
    ctx.send('haptic', { kind: 'medium' });
    move(x, y);
  }

  function move(x, y) {
    if (!drag) return;
    const left = x - drag.dx;
    const top = drag.opts.axis === 'x' ? drag.top : y - drag.dy;
    css(drag.ghost, 'left', px(left));
    css(drag.ghost, 'top', px(top));
    // Hit-tested where the ghost's grab point is, which on a horizontal-only
    // drag is level with the row rather than under the finger.
    const hy = drag.opts.axis === 'x' ? drag.top + drag.dy : y;
    const next = hit(x, hy, drag.payload);
    if (next !== drag.active) {
      if (drag.active) drag.active.leave();
      drag.active = next;
      if (next) next.enter();
    }
  }

  function end(dropIt) {
    const d = drag;
    drag = null;
    if (!d) return;
    detach(d.ghost);
    if (d.active) {
      d.active.leave();
      if (dropIt) d.active.drop(d.payload);
    }
    if (d.opts.ghosted) d.opts.ghosted(false);
    if (d.opts.end) d.opts.end();
    const run = [];
    for (let i = 0; i < deferred.length; i++) run[i] = deferred[i];
    deferred.length = 0;
    for (let i = 0; i < run.length; i++) run[i]();
  }

  function cancelPending() {
    if (!pending) return;
    S.clearTimer(pending.timer);
    pending = null;
  }

  /**
   * Makes [el] draggable. `longPress` waits 300ms without moving more than the
   * touch slop (LongPressDraggable); otherwise the drag starts once the
   * pointer has moved past the slop (Draggable). `enabled()` is asked on
   * every press.
   */
  function source(el, opts) {
    S.on(el, 'pointerdown', (e) => {
      if (!e.isTrusted || drag || !opts.enabled()) return;
      if (S.pointerType(e) === 'mouse' && S.mouseButton(e) !== 0) return;
      cancelPending();
      const x = S.clientX(e);
      const y = S.clientY(e);
      pending = { el, opts, x, y, pointerId: S.pointerId(e), timer: 0 };
      if (opts.longPress) {
        const p = pending;
        p.timer = S.setTimer(() => {
          if (pending !== p) return;
          pending = null;
          try { S.setPointerCapture(el, p.pointerId); } catch (_) {}
          begin(p, p.lastX == null ? p.x : p.lastX, p.lastY == null ? p.y : p.lastY);
        }, LONG_PRESS_MS);
      }
    });
    S.on(el, 'pointermove', (e) => {
      if (!e.isTrusted) return;
      const x = S.clientX(e);
      const y = S.clientY(e);
      if (drag && drag.el === el) {
        move(x, y);
        return;
      }
      const p = pending;
      if (!p || p.el !== el) return;
      p.lastX = x;
      p.lastY = y;
      const moved = S.mathMax(S.mathAbs(x - p.x), S.mathAbs(y - p.y));
      if (moved <= SLOP) return;
      if (p.opts.longPress) {
        cancelPending();
        return;
      }
      pending = null;
      try { S.setPointerCapture(el, p.pointerId); } catch (_) {}
      begin(p, x, y);
    });
    S.on(el, 'pointerup', (e) => {
      if (drag && drag.el === el) {
        // The drop ends the gesture; the click that may follow is not a tap.
        S.preventDefault(e);
        end(true);
        suppressTaps();
        return;
      }
      cancelPending();
    });
    S.on(el, 'pointercancel', () => {
      if (drag && drag.el === el) end(false);
      cancelPending();
    });
    // A long press on touch would otherwise open the page's context menu.
    S.on(el, 'contextmenu', (e) => {
      if (opts.longPress) S.preventDefault(e);
    });
  }

  return {
    source,
    target,
    removeGroup,
    get active() {
      return !!drag;
    },
    get payload() {
      return drag ? drag.payload : null;
    },
    /** Runs [fn] now, or once the drag in flight has ended. */
    whenIdle(fn) {
      if (drag) deferred[deferred.length] = fn;
      else fn();
    },
    cancel() {
      cancelPending();
      end(false);
    },
  };
}
