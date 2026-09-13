/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

/* How fast, and for how long, a freshly started clock hunts for the bubble it
 * belongs to. The send window starts the clock and the typing bubble is
 * appended later in that same dispatch, so the first paint has nothing to write
 * on; 3s is far past any dispatch, and after that the bubble is not coming and
 * the regular interval is enough on its own. */
const PRIME_INTERVAL_MS = 100;
const PRIME_MAX_TICKS = 30;

export class GenTimer {
  constructor(renderer) {
    this.renderer = renderer;
    this._interval = null;
    this._prime = null;
    this._primeTicksLeft = 0;
    this._start = null;
  }

  _format(startTime) {
    const elapsedSeconds = (Date.now() - startTime) / 1000;
    const battery = !!(window.bridge && window.bridge.batterySaver);
    return (battery ? elapsedSeconds.toFixed(0) : elapsedSeconds.toFixed(1)) + 's';
  }

  /* Starts the clock only if it is not already ticking. The send window puts
   * the typing bubble up before the generation is published, and both edges
   * reconcile through _syncGenerationTimer — restarting on the second one
   * would reset a timer the user has already been watching count. */
  ensureRunning() {
    if (this._interval) return;
    this.start();
  }

  start() {
    this.stop();
    this._start = Date.now();
    const battery = !!(window.bridge && window.bridge.batterySaver);
    const intervalMs = battery ? 1000 : 100;
    /* Paint before the first interval elapses. setInterval only fires after a
     * whole period, which in battery saver left the placeholder sitting there
     * with no clock on it for a full second. */
    const painted = this._tick();
    this._interval = setInterval(() => this._tick(), intervalMs);
    if (!painted) this._startPriming();
  }

  /* Writes the elapsed time onto the streaming bubble, creating its badge on
   * the first paint. Returns whether the bubble was there to write on — the
   * clock can start a frame or two before it is appended. */
  _tick() {
    const timeStr = this._format(this._start);
    const streamingEl = document.querySelector('[data-message-id="__streaming__"]')
      || document.querySelector('.message-section.char .msg-body .typing-container')?.closest('.message-section');
    if (!streamingEl) return false;

    let wrapper = streamingEl.querySelector('.gen-time-wrapper');

    if (!wrapper) {
      const layout = streamingEl.classList.contains('layout-bubble') ? 'bubble' : 'default';
      const statContainer = streamingEl.querySelector(layout === 'bubble' ? '.bubble-meta' : '.msg-meta');
      if (statContainer) {
        /* Assembled from _buildGenTime rather than _createGenStat: that helper
         * drops a clock reading '0s', because a finished message with no
         * recorded generation time has none to show — and '0s' is exactly what
         * a clock reads on the tick that creates it. Going through it left an
         * empty gen-stat behind and appended a second one a tick later. */
        const stat = document.createElement('div');
        stat.className = 'gen-stat';
        stat.appendChild(
          this.renderer._buildGenTime(timeStr, layout === 'bubble' ? '2px' : '4px'),
        );
        if (layout === 'bubble') stat.style.marginRight = 'auto';
        statContainer.appendChild(stat);
        wrapper = stat.querySelector('.gen-time-wrapper');
      }
    }

    if (wrapper && wrapper.rollingNumber) {
      wrapper.rollingNumber.setValue(timeStr);
      return true;
    }
    const badge = streamingEl.querySelector('.gen-time-badge');
    if (badge) {
      badge.textContent = timeStr;
      return true;
    }
    return false;
  }

  /* Runs at the fast cadence until the bubble shows up, then gets out of the
   * way. Without it battery saver waits out its full second regardless of the
   * immediate paint, because the bubble is not in the DOM yet when it runs. */
  _startPriming() {
    this._primeTicksLeft = PRIME_MAX_TICKS;
    this._prime = setInterval(() => {
      this._primeTicksLeft -= 1;
      if (this._tick() || this._primeTicksLeft <= 0) this._stopPriming();
    }, PRIME_INTERVAL_MS);
  }

  _stopPriming() {
    if (this._prime) {
      clearInterval(this._prime);
      this._prime = null;
    }
    this._primeTicksLeft = 0;
  }

  stop() {
    this._stopPriming();
    if (this._interval) {
      clearInterval(this._interval);
      this._interval = null;
    }
    this._start = null;
  }
}
