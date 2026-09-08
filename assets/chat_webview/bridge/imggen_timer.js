/* Live elapsed-time ticker for Imagen loading blocks.
 *
 * Ported from Glaze ShadowContent.vue (updateTimers). Each `[IMG:GEN]`
 * loading block rendered by the formatter carries a
 * `.imggen-loading-timer[data-start]` element. Message content lives inside
 * per-message shadow roots, so we walk every `.message-content` host and
 * update its timer text. Plain-text variant (no RollingNumber / Teleport).
 *
 * Self-managing: `ensureRunning()` starts the interval if needed; each tick
 * stops itself once no loading timers remain on screen, so it stays idle
 * when no image is generating.
 */
export class ImgGenTimer {
  constructor(intervalMs = 100) {
    this._interval = null;
    this._intervalMs = intervalMs;
  }

  ensureRunning() {
    if (this._interval) return;
    // Run one immediate tick so the timer doesn't sit at 0.0s for a frame.
    if (this._tick() === 0) return;
    this._interval = setInterval(() => this._tick(), this._intervalMs);
  }

  stop() {
    if (this._interval) {
      clearInterval(this._interval);
      this._interval = null;
    }
  }

  // Returns the number of timer elements updated this tick.
  _tick() {
    const hosts = document.querySelectorAll('.message-content');
    const now = Date.now();
    let found = 0;
    hosts.forEach((host) => {
      const root = host.shadowRoot;
      if (!root) return;
      const timers = root.querySelectorAll('.imggen-loading-timer[data-start]');
      timers.forEach((el) => {
        found++;
        const start = parseInt(el.dataset.start, 10);
        if (!start) return;
        el.textContent = ((now - start) / 1000).toFixed(1) + 's';
      });
    });
    if (found === 0) this.stop();
    return found;
  }
}
