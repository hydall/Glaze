/* Desktop scroll input relayed into the chat WebView by Flutter.
 *
 * On Windows the page gets neither input the way a browser would:
 *
 * - A precision touchpad produces no `wheel` event at all. Flutter's win32
 *   embedder reports its scrolling as pan/zoom pointer events
 *   (PointerPanZoomStart/Update/End), and flutter_inappwebview_windows forwards
 *   only PointerScrollEvent to WebView2 (flutter_inappwebview #2503 / #2511,
 *   both closed as not planned). What the embedder does report is one sum per
 *   frame of the pad's raw samples — jittery, three pixels one frame and ten
 *   the next under a steady finger — and nothing once the fingers leave: the
 *   glide a flick has everywhere else is the framework's own doing in a
 *   Flutter list, and the page has no framework.
 * - A mouse wheel does arrive, but shrunk. The plugin hands WebView2 Flutter's
 *   scroll delta — logical pixels, already divided by the device pixel ratio —
 *   as if it were wheel units (120 per notch), so one notch lands as a fraction
 *   of one: 0.83 at 100% scaling and three lines per notch, 0.43 at 125% and
 *   two. The page then moved by that fraction, in a single jump.
 *
 * ChatWebViewScrollRelay on the Flutter side captures both and hands them to
 * the Bridge, which lands them here: pan()/panStart()/panEnd() for the
 * touchpad, wheel() for a notch already converted back to the CSS pixels a
 * browser would scroll. Every step is replayed as a synthetic `wheel` event at
 * the cursor so the existing wheel handlers (the #chat-container handler in
 * ./index.js, the edit textarea handler in ./edit_controller.js) react exactly
 * as they do to a real wheel — one scroll path, not three. A pan is evened out
 * over a frame or two so the content follows the finger without the jitter,
 * and carried on from the speed the fingers left at; a notch is spread over
 * the frames that follow, the way a browser animates a wheel.
 *
 * While the wheel is relayed, the trusted `wheel` the plugin still forwards for
 * the same notch is swallowed at the document — see relayNativeWheel() — or
 * every notch would scroll twice.
 *
 * The chat chrome (chrome/index.js — the composer's field above all) draws in
 * a closed shadow root, where `document.elementFromPoint` cannot look: it
 * returns the chrome's host, and a step would go on to the chat underneath.
 * So the chrome (`window.__glazeChrome`) is asked first whether the cursor is
 * over a field or scroller of its; if so the step is its, whether or not it
 * can take it — the field at its end swallows the step, as a text field in
 * any editor does, rather than passing it on to the chat behind. Only a point
 * where the chrome has nothing reaches the page.
 */

/* Pixel-mode wheel scale used by the page's own wheel handlers: they scroll by
 * `deltaY * WHEEL_PIXEL_SCALE`. Deltas arrive here already in CSS pixels, so
 * they are divided by the same factor to survive the round trip and track the
 * finger 1:1. Shared with the container handler in ./index.js and
 * EditController._scaledWheelDelta in ./edit_controller.js so all three stay
 * in step. `1` is the browser's native pixel-mode rate — one CSS pixel of
 * scroll per wheel delta unit — instead of the older, slower 0.3. */
export const WHEEL_PIXEL_SCALE = 1;

/* How a wheel notch closes in on its target: each frame scrolls
 * 1 − e^(−dt/τ) of what is left, with τ = this many milliseconds. 70 puts a
 * notch 95% of the way in about 200 ms, close to Chromium's own wheel
 * animation. Notches that arrive while one is still moving add to what is
 * left rather than queue behind it, so a fast spin stays fast. */
export const WHEEL_SMOOTHING_MS = 70;

/* The same filter for a touchpad pan, with a τ of about one frame: a steady
 * finger whose frames come in as 3, 10, 5, 5, 7 px comes out at 5, 8, 6, 6,
 * 7 — the jitter halved — and the content sits a frame behind the finger,
 * what a browser's own input resampling costs. 40 ms evened the stream out
 * further but trailed the finger by two frames more, and that was felt. */
export const PAN_SMOOTHING_MS = 20;

/* Once a frame brings no pan — the fingers paused or left — what the pan still
 * owes is let out with this constant instead, so the content stops with the
 * fingers rather than a few frames after them. Only the arrival of input is
 * smoothed, not its end. */
export const PAN_RELEASE_MS = 12;

/* After the fingers leave the pad the content keeps the speed they had and
 * loses 1 − e^(−dt/τ) of it per frame with τ = this many milliseconds, so a
 * hard flick glides for about two seconds — the same shape Flutter's own
 * lists give a flick. The speed is capped and small ones are not a flick at
 * all, as in ScrollPhysics (8000 and 50 px/s). */
export const FLING_DECAY_MS = 350;
export const FLING_MAX_PX_PER_MS = 8;
export const FLING_MIN_PX_PER_MS = 0.05;
const FLING_STOP_PX_PER_MS = 0.01;

const SCROLLABLE_OVERFLOW = /^(auto|scroll|overlay)$/;

function prefersReducedMotion() {
  return typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/* The element under (x, y), looking into open shadow roots: message content
 * renders inside one, and `document.elementFromPoint` stops at its host, so a
 * wheel listener or scroller inside a message would never see the relay. */
function deepElementFromPoint(x, y) {
  let el = document.elementFromPoint(x, y);
  while (el && el.shadowRoot) {
    const inner = el.shadowRoot.elementFromPoint(x, y);
    if (!inner || inner === el) break;
    el = inner;
  }
  return el;
}

/* The parent in the flattened tree: out of a shadow root, its host. */
function composedParent(el) {
  if (el.parentElement) return el.parentElement;
  const root = el.getRootNode();
  return root instanceof ShadowRoot ? root.host : null;
}

export class ScrollRelay {
  /** @param containerFn returns the chat scroll container (may be null early). */
  constructor(containerFn) {
    this._containerFn = containerFn;
    // What is still owed, in CSS pixels: wheel notches and pans apart, since
    // they close in at different rates.
    this._owedWheelX = 0;
    this._owedWheelY = 0;
    this._owedPanX = 0;
    this._owedPanY = 0;
    // A flick in flight: speed in CSS pixels per millisecond, and what of it
    // did not fill a whole device pixel last frame.
    this._flingVX = 0;
    this._flingVY = 0;
    this._flingCarryX = 0;
    this._flingCarryY = 0;
    // Where the cursor was when the last input came in.
    this._cursorX = NaN;
    this._cursorY = NaN;
    this._frameId = 0;
    this._frameAt = 0;
    this._panFedThisFrame = false;
    this._nativeWheelRelayed = false;
    this._frame = this._frame.bind(this);
    // The chrome module runs before the bridge, so its hook is there by now.
    this._chrome = ScrollRelay._chromeHook();
    this._swallowNativeWheel = (e) => {
      if (!e.isTrusted) return;
      e.preventDefault();
      e.stopImmediatePropagation();
    };
  }

  /* The chrome's scroll hook, when the page has one with all three parts. */
  static _chromeHook() {
    const chrome = window.__glazeChrome;
    return chrome && typeof chrome.ownsScrollAt === 'function' &&
      typeof chrome.scrollAt === 'function' &&
      typeof chrome.canScrollAt === 'function' ? chrome : null;
  }

  /* Flutter relays the mouse wheel through wheel() from now on: drop the
   * trusted copy of every notch the plugin still forwards. Off until told,
   * so a page without the relay — every other platform — keeps its native
   * wheel. Synthetic events are untouched; they are the relay. */
  relayNativeWheel(on) {
    on = !!on;
    if (on === this._nativeWheelRelayed) return;
    this._nativeWheelRelayed = on;
    if (on) {
      document.addEventListener('wheel', this._swallowNativeWheel, {
        capture: true,
        passive: false,
      });
    } else {
      document.removeEventListener('wheel', this._swallowNativeWheel, {
        capture: true,
      });
    }
  }

  get nativeWheelRelayed() {
    return this._nativeWheelRelayed;
  }

  /* Scroll by (dx, dy) CSS pixels at once, wheel sign convention: positive dy
   * moves the content up (scrollTop grows), like a wheel scrolled towards the
   * user. (x, y) are client coordinates of the cursor. */
  scrollBy(dx, dy, x, y) {
    dx = Number(dx) || 0;
    dy = Number(dy) || 0;
    if (dx === 0 && dy === 0) return;

    const container = this._containerFn ? this._containerFn() : null;
    const hasPoint = Number.isFinite(x) && Number.isFinite(y);
    // The chrome first: a field of its own under the cursor takes the step,
    // whether or not it can still move.
    if (hasPoint && this._chrome && this._chrome.ownsScrollAt(x, y)) {
      this._chrome.scrollAt(x, y, dx, dy);
      return;
    }
    const target = (hasPoint ? deepElementFromPoint(x, y) : null) || container;
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

  /* A mouse wheel notch of (dx, dy) CSS pixels, wheel sign convention, spread
   * over the frames that follow. (x, y) are client coordinates of the cursor. */
  wheel(dx, dy, x, y) {
    dx = Number(dx) || 0;
    dy = Number(dy) || 0;
    if (dx === 0 && dy === 0) return;
    this._moveCursor(x, y);
    // The wheel takes over from a flick.
    this._stopFling();
    if (prefersReducedMotion()) {
      this.scrollBy(dx, dy, this._cursorX, this._cursorY);
      return;
    }
    // A notch the other way starts over: what the last one had left would
    // only pull against it.
    if (dx * this._owedWheelX < 0) this._owedWheelX = 0;
    if (dy * this._owedWheelY < 0) this._owedWheelY = 0;
    this._owedWheelX += dx;
    this._owedWheelY += dy;
    this._wake();
  }

  /* A frame's worth of touchpad pan, (dx, dy) CSS pixels in wheel sign
   * convention, followed a frame or two behind. */
  pan(dx, dy, x, y) {
    dx = Number(dx) || 0;
    dy = Number(dy) || 0;
    if (dx === 0 && dy === 0) return;
    this._moveCursor(x, y);
    // Fingers on the pad are in charge; nothing glides under them.
    this._stopFling();
    if (prefersReducedMotion()) {
      this.scrollBy(dx, dy, this._cursorX, this._cursorY);
      return;
    }
    if (dx * this._owedPanX < 0) this._owedPanX = 0;
    if (dy * this._owedPanY < 0) this._owedPanY = 0;
    this._owedPanX += dx;
    this._owedPanY += dy;
    this._panFedThisFrame = true;
    this._wake();
  }

  /* The fingers touched the pad: whatever still glides from the last flick
   * stops where it is, as a touch stops a Flutter list. */
  panStart() {
    this._stopFling();
  }

  /* The fingers left the pad at (vx, vy) CSS pixels per second, wheel sign
   * convention: carry the motion on and let it die away. */
  panEnd(vx, vy) {
    vx = (Number(vx) || 0) / 1000;
    vy = (Number(vy) || 0) / 1000;
    if (prefersReducedMotion()) return;
    const clamp = (v) => Math.sign(v) * Math.min(Math.abs(v), FLING_MAX_PX_PER_MS);
    vx = Math.abs(vx) < FLING_MIN_PX_PER_MS ? 0 : clamp(vx);
    vy = Math.abs(vy) < FLING_MIN_PX_PER_MS ? 0 : clamp(vy);
    if (vx === 0 && vy === 0) return;
    this._flingVX = vx;
    this._flingVY = vy;
    this._flingCarryX = 0;
    this._flingCarryY = 0;
    this._wake();
  }

  /* Drops everything still owed or gliding and the frame that would move it. */
  stop() {
    this._owedWheelX = 0;
    this._owedWheelY = 0;
    this._owedPanX = 0;
    this._owedPanY = 0;
    this._panFedThisFrame = false;
    this._stopFling();
    if (this._frameId) {
      cancelAnimationFrame(this._frameId);
      this._frameId = 0;
    }
  }

  /* What is still owed and in flight, for tests. */
  get pendingWheel() {
    return { dx: this._owedWheelX, dy: this._owedWheelY };
  }

  get pendingPan() {
    return { dx: this._owedPanX, dy: this._owedPanY };
  }

  get flingVelocity() {
    return { vx: this._flingVX, vy: this._flingVY };
  }

  _moveCursor(x, y) {
    if (Number.isFinite(x) && Number.isFinite(y)) {
      this._cursorX = x;
      this._cursorY = y;
    }
  }

  _stopFling() {
    this._flingVX = 0;
    this._flingVY = 0;
    this._flingCarryX = 0;
    this._flingCarryY = 0;
  }

  _wake() {
    if (this._frameId) return;
    this._frameAt = 0;
    this._frameId = requestAnimationFrame(this._frame);
  }

  _frame(now) {
    this._frameId = 0;
    // A frame that comes late (a hidden tab) counts as a long one, not as the
    // whole wait, or the chat would leap when it is shown again.
    const dt = this._frameAt ? Math.min(now - this._frameAt, 100) : 16;
    this._frameAt = now;
    const grain = 1 / (window.devicePixelRatio || 1);
    const wheelShare = 1 - Math.exp(-dt / WHEEL_SMOOTHING_MS);
    const panTau = this._panFedThisFrame ? PAN_SMOOTHING_MS : PAN_RELEASE_MS;
    this._panFedThisFrame = false;
    const panShare = 1 - Math.exp(-dt / panTau);
    const flingDecay = Math.exp(-dt / FLING_DECAY_MS);

    const wheelX = this._stepOf(this._owedWheelX, wheelShare, grain);
    const wheelY = this._stepOf(this._owedWheelY, wheelShare, grain);
    const panX = this._stepOf(this._owedPanX, panShare, grain);
    const panY = this._stepOf(this._owedPanY, panShare, grain);
    this._flingCarryX += this._flingVX * dt;
    this._flingCarryY += this._flingVY * dt;
    const flingX = Math.round(this._flingCarryX / grain) * grain;
    const flingY = Math.round(this._flingCarryY / grain) * grain;
    this._flingCarryX -= flingX;
    this._flingCarryY -= flingY;
    this._flingVX *= flingDecay;
    this._flingVY *= flingDecay;
    if (Math.abs(this._flingVX) < FLING_STOP_PX_PER_MS) {
      this._flingVX = 0;
      this._flingCarryX = 0;
    }
    if (Math.abs(this._flingVY) < FLING_STOP_PX_PER_MS) {
      this._flingVY = 0;
      this._flingCarryY = 0;
    }

    let stepX = wheelX + panX + flingX;
    let stepY = wheelY + panY + flingY;
    // At an edge, what cannot scroll is dropped rather than saved up: a notch
    // or a flick past the end of the chat must not come back as movement the
    // moment the input turns the other way.
    if (stepX !== 0 && !this._canScrollAt(stepX, 0)) {
      this._owedWheelX = 0;
      this._owedPanX = 0;
      this._flingVX = 0;
      this._flingCarryX = 0;
      stepX = 0;
    } else {
      this._owedWheelX -= wheelX;
      this._owedPanX -= panX;
    }
    if (stepY !== 0 && !this._canScrollAt(0, stepY)) {
      this._owedWheelY = 0;
      this._owedPanY = 0;
      this._flingVY = 0;
      this._flingCarryY = 0;
      stepY = 0;
    } else {
      this._owedWheelY -= wheelY;
      this._owedPanY -= panY;
    }
    if (stepX !== 0 || stepY !== 0) {
      this.scrollBy(stepX, stepY, this._cursorX, this._cursorY);
    }
    if (this._owedWheelX !== 0 || this._owedWheelY !== 0 ||
        this._owedPanX !== 0 || this._owedPanY !== 0 ||
        this._flingVX !== 0 || this._flingVY !== 0) {
      this._frameId = requestAnimationFrame(this._frame);
    }
  }

  /* This frame's share of what is left, on the grid of whole device pixels
   * the browser keeps scroll offsets on: a fraction of one is rounded away by
   * the scroller, and twenty frames of rounding left a notch a few pixels
   * short. The tail goes a device pixel a frame, and the last one in a piece. */
  _stepOf(pending, share, grain) {
    if (Math.abs(pending) <= grain) return pending;
    const step = Math.round((pending * share) / grain) * grain;
    return step !== 0 ? step : Math.sign(pending) * grain;
  }

  /* Whether anything under the cursor — or, failing that, the chat container —
   * can still scroll in the direction of (dx, dy). */
  _canScrollAt(dx, dy) {
    const container = this._containerFn ? this._containerFn() : null;
    const hasPoint = Number.isFinite(this._cursorX) && Number.isFinite(this._cursorY);
    // Over a field of the chrome the answer is the field's: at its end, what
    // is owed is dropped there, as at the end of the chat.
    if (hasPoint && this._chrome &&
        this._chrome.ownsScrollAt(this._cursorX, this._cursorY)) {
      return this._chrome.canScrollAt(this._cursorX, this._cursorY, dx, dy);
    }
    let el = hasPoint ? deepElementFromPoint(this._cursorX, this._cursorY) : null;
    while (el && el !== document.body && el !== document.documentElement) {
      if (this._canScroll(el, dx, dy)) return true;
      el = composedParent(el);
    }
    return !!container && this._canScroll(container, dx, dy);
  }

  _scrollNearest(target, dx, dy, container) {
    let el = target;
    while (el && el !== document.body && el !== document.documentElement) {
      if (this._canScroll(el, dx, dy)) {
        el.scrollLeft += dx;
        el.scrollTop += dy;
        return;
      }
      el = composedParent(el);
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
