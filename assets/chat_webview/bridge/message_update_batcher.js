/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

export class MessageUpdateBatcher {
  constructor() {
    this._pending = new Map();
    this._rafScheduled = false;
  }

  enqueue(id, updateFn) {
    this._pending.set(id, updateFn);
    if (!this._rafScheduled) {
      this._rafScheduled = true;
      requestAnimationFrame(() => this.flush());
    }
  }

  flush() {
    const batch = new Map(this._pending);
    this._pending.clear();
    this._rafScheduled = false;
    for (const [id, fn] of batch) {
      fn(id);
    }
  }

  hasPending() {
    return this._pending.size > 0;
  }
}
