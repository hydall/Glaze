/* ============================================================
 * <glaze-spinner> — port of lib/shared/widgets/glaze_spinner.dart
 *
 * The loading screen used to be a CSS border spinner with the stock cherry
 * accent as its fallback, so it showed in the wrong color until Flutter's
 * applyTheme() arrived and then switched. This draws the app's own spinner
 * and paints nothing until the theme's accent (`--primary-rgb`) is set.
 *
 * Geometry, timing and easing mirror _GlazeSpinnerPainter; keep them in step.
 * ============================================================ */

(() => {
  const SIZE = 36; // GlazeSpinner.defaultSize
  const CYCLE_MS = 1600;
  const MIN_SWEEP_TURNS = 0.08;
  const MAX_SWEEP_TURNS = 0.82;
  const TAU = Math.PI * 2;

  // Flutter's Curves.easeInOutCubic: Cubic(0.645, 0.045, 0.355, 1.0).
  const X1 = 0.645, Y1 = 0.045, X2 = 0.355, Y2 = 1.0;
  const bezier = (a, b, m) => 3 * a * (1 - m) * (1 - m) * m + 3 * b * (1 - m) * m * m + m * m * m;
  function easeInOutCubic(t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    let lo = 0, hi = 1;
    for (let i = 0; i < 24; i++) {
      const mid = (lo + hi) / 2;
      if (bezier(X1, X2, mid) < t) lo = mid; else hi = mid;
    }
    return bezier(Y1, Y2, (lo + hi) / 2);
  }
  const clamp01 = (v) => Math.min(1, Math.max(0, v));

  class GlazeSpinnerElement extends HTMLElement {
    connectedCallback() {
      if (!this._canvas) {
        this._canvas = document.createElement('canvas');
        this._canvas.style.width = `${SIZE}px`;
        this._canvas.style.height = `${SIZE}px`;
        this._canvas.style.display = 'block';
        this.appendChild(this._canvas);
      }
      this._start = performance.now();
      const tick = (now) => {
        this._frame = requestAnimationFrame(tick);
        this._paint(now);
      };
      this._frame = requestAnimationFrame(tick);
    }

    disconnectedCallback() {
      cancelAnimationFrame(this._frame);
      this._frame = 0;
    }

    _paint(now) {
      const canvas = this._canvas;
      const dpr = window.devicePixelRatio || 1;
      const px = Math.round(SIZE * dpr);
      if (canvas.width !== px) { canvas.width = px; canvas.height = px; }
      const ctx = canvas.getContext('2d');
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, SIZE, SIZE);

      // Inline on <html>, where applyTheme() puts it — no style recalc per frame.
      const rgb = document.documentElement.style.getPropertyValue('--primary-rgb').trim();
      if (!rgb) return;
      const color = (a) => `rgba(${rgb}, ${a})`;

      const t = ((now - this._start) % CYCLE_MS) / CYCLE_MS;
      const head = easeInOutCubic(clamp01(t * 2));
      const tail = easeInOutCubic(clamp01(t * 2 - 1));
      const sweep = (MIN_SWEEP_TURNS + (head - tail) * (MAX_SWEEP_TURNS - MIN_SWEEP_TURNS)) * TAU;
      const startAngle = -Math.PI / 2 + (tail + t) * TAU;

      const c = SIZE / 2;
      const width = Math.min(12, Math.max(1.8, SIZE * 0.115));
      const halo = width * 0.25;
      const radius = (SIZE - width) / 2 - halo;

      ctx.lineCap = 'round';
      ctx.lineWidth = width;
      ctx.strokeStyle = color(0.12);
      ctx.beginPath();
      ctx.arc(c, c, radius, 0, TAU);
      ctx.stroke();

      const arc = (w, alpha) => {
        ctx.lineWidth = w;
        // Pad the tail so its round cap stays transparent (see the painter).
        const pad = w / 2 / radius;
        const total = sweep + pad;
        const capStop = pad / total;
        if (typeof ctx.createConicGradient === 'function') {
          const g = ctx.createConicGradient(startAngle - pad, c, c);
          const at = (s) => (s * total) / TAU;
          g.addColorStop(0, color(0));
          g.addColorStop(at(capStop), color(0));
          g.addColorStop(at(capStop + (1 - capStop) * 0.3), color(alpha * 0.7));
          g.addColorStop(at(1), color(alpha));
          ctx.strokeStyle = g;
        } else {
          ctx.strokeStyle = color(alpha);
        }
        ctx.beginPath();
        ctx.arc(c, c, radius, startAngle, startAngle + sweep);
        ctx.stroke();
      };
      arc(width * 2.2, 0.08);
      arc(width * 1.5, 0.14);
      arc(width, 1);

      const angle = startAngle + sweep;
      const hx = c + Math.cos(angle) * radius;
      const hy = c + Math.sin(angle) * radius;
      const bloom = width * 2;
      const glow = ctx.createRadialGradient(hx, hy, 0, hx, hy, bloom);
      glow.addColorStop(0.2, color(0.35));
      glow.addColorStop(1, color(0));
      ctx.fillStyle = glow;
      ctx.beginPath();
      ctx.arc(hx, hy, bloom, 0, TAU);
      ctx.fill();
    }
  }

  if (!customElements.get('glaze-spinner')) {
    customElements.define('glaze-spinner', GlazeSpinnerElement);
  }
})();
