/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

export class GenTimer {
  constructor(renderer) {
    this.renderer = renderer;
    this._interval = null;
    this._start = null;
  }

  _format(startTime) {
    const elapsedSeconds = (Date.now() - startTime) / 1000;
    const battery = !!(window.bridge && window.bridge.batterySaver);
    return (battery ? elapsedSeconds.toFixed(0) : elapsedSeconds.toFixed(1)) + 's';
  }

  start() {
    this.stop();
    this._start = Date.now();
    const battery = !!(window.bridge && window.bridge.batterySaver);
    const intervalMs = battery ? 1000 : 100;
    this._interval = setInterval(() => {
      const timeStr = this._format(this._start);
      const streamingEl = document.querySelector('[data-message-id="__streaming__"]')
        || document.querySelector('.message-section.char .msg-body .typing-container')?.closest('.message-section');
      if (streamingEl) {
        let wrapper = streamingEl.querySelector('.gen-time-wrapper');

        if (!wrapper) {
          const layout = streamingEl.classList.contains('layout-bubble') ? 'bubble' : 'default';
          const statContainer = streamingEl.querySelector(layout === 'bubble' ? '.bubble-meta' : '.msg-meta');
          if (statContainer) {
            const stat = this.renderer._createGenStat(timeStr, 0, layout === 'bubble' ? '2px' : '4px');
            if (layout === 'bubble') stat.style.marginRight = 'auto';
            statContainer.appendChild(stat);
            wrapper = stat.querySelector('.gen-time-wrapper');
          }
        }

        if (wrapper && wrapper.rollingNumber) {
          wrapper.rollingNumber.setValue(timeStr);
        } else {
          const badge = streamingEl.querySelector('.gen-time-badge');
          if (badge) badge.textContent = timeStr;
        }
      }
    }, intervalMs);
  }

  stop() {
    if (this._interval) {
      clearInterval(this._interval);
      this._interval = null;
    }
    this._start = null;
  }
}
