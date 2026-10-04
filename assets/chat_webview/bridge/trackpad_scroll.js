/* Windows precision-touchpad scrolling for the chat WebView.
 *
 * Flutter's win32 embedder reports precision-touchpad scrolling as pan/zoom
 * pointer events (PointerPanZoomStart/Update/End), not as PointerScrollEvent,
 * and flutter_inappwebview_windows only forwards the latter to WebView2. The
 * page therefore never sees a `wheel` event from a touchpad — only from a
 * mouse wheel (flutter_inappwebview #2503 / #2511, both closed as not
 * planned). ChatWebViewTrackpadScroll on the Flutter side captures the pan and
 * calls bridge.trackpadScroll(), which lands here.
 *
 * The pan is replayed as a synthetic `wheel` event at the cursor so every
 * existing wheel handler (the #chat-container handler in ./index.js, the edit
 * textarea handler in ./edit_controller.js) reacts exactly as it does to a
 * real mouse wheel — one scroll path, not two.
 */

/* Pixel-mode wheel scale used by the page's own wheel handlers: they scroll by
 * `deltaY * 0.3`. Deltas arrive here already in CSS pixels, so they are
 * divided by the same factor to survive the round trip and track the finger
 * 1:1. Keep in sync with `e.deltaY * 0.3` in ./index.js and
 * EditController._scaledWheelDelta in ./edit_controller.js. */
export const WHEEL_PIXEL_SCALE = 0.3;

const SCROLLABLE_OVERFLOW = /^(auto|scroll|overlay)$/;

export class TrackpadScroll {
  /** @param containerFn returns the chat scroll container (may be null early). */
  constructor(containerFn) {
    this._containerFn = containerFn;
  }

  /* Scroll by (dx, dy) CSS pixels, wheel sign convention: positive dy moves
   * the content up (scrollTop grows), like a wheel scrolled towards the user.
   * (x, y) are client coordinates of the cursor. */
  scrollBy(dx, dy, x, y) {
    dx = Number(dx) || 0;
    dy = Number(dy) || 0;
    if (dx === 0 && dy === 0) return;

    const container = this._containerFn ? this._containerFn() : null;
    const hasPoint = Number.isFinite(x) && Number.isFinite(y);
    const target = (hasPoint ? document.elementFromPoint(x, y) : null) || container;
    if (!target) return;

    // dispatchEvent returns false when a listener called preventDefault(),
    // which is how both page handlers signal "I scrolled this myself".
    const consumed = !target.dispatchEvent(new WheelEvent('wheel', {
      deltaX: dx / WHEEL_PIXEL_SCALE,
      deltaY: dy / WHEEL_PIXEL_SCALE,
      deltaMode: 0,
      clientX: hasPoint ? x : 0,
      clientY: hasPoint ? y : 0,
      bubbles: true,
      cancelable: true,
      composed: true,
    }));
    if (consumed) return;

    // Synthetic events are untrusted, so the browser performs no default
    // scrolling for them. Nothing claimed the event — do the default action
    // ourselves on the nearest scrollable ancestor.
    this._scrollNearest(target, dx, dy, container);
  }

  _scrollNearest(target, dx, dy, container) {
    let el = target;
    while (el && el !== document.body && el !== document.documentElement) {
      if (this._canScroll(el, dx, dy)) {
        el.scrollLeft += dx;
        el.scrollTop += dy;
        return;
      }
      el = el.parentElement;
    }
    if (container) {
      container.scrollLeft += dx;
      container.scrollTop += dy;
    }
  }

  _canScroll(el, dx, dy) {
    const style = window.getComputedStyle(el);
    if (dy !== 0 && SCROLLABLE_OVERFLOW.test(style.overflowY)) {
      const max = el.scrollHeight - el.clientHeight;
      if (max > 1 && ((dy < 0 && el.scrollTop > 0) ||
                      (dy > 0 && el.scrollTop < max - 1))) {
        return true;
      }
    }
    if (dx !== 0 && SCROLLABLE_OVERFLOW.test(style.overflowX)) {
      const max = el.scrollWidth - el.clientWidth;
      if (max > 1 && ((dx < 0 && el.scrollLeft > 0) ||
                      (dx > 0 && el.scrollLeft < max - 1))) {
        return true;
      }
    }
    return false;
  }
}
