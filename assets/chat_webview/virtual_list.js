class VirtualList {
  constructor(container) {
    this.container = container;
    this.messages = new Map();
    this.messageOrder = [];

    this._heightCache = new Map();
    this._prefixSums = [];
    this._dirty = true;

    this._renderStart = 0;
    this._renderEnd = 0;
    this._bufferSize = Infinity;

    this._topSpacer = document.createElement('div');
    this._topSpacer.className = 'vl-spacer vl-spacer-top';
    this._bottomSpacer = document.createElement('div');
    this._bottomSpacer.className = 'vl-spacer vl-spacer-bottom';
    this.container.appendChild(this._topSpacer);
    this.container.appendChild(this._bottomSpacer);

    this._rafId = null;
    this._isUserScroll = true;
    this._scrollToBottomPending = false;
    this._pendingScrollToId = null;

    this._resizeObserver = new ResizeObserver((entries) => {
      let needsUpdate = false;
      for (const entry of entries) {
        const id = entry.target.dataset.vlId;
        if (id != null) {
          const newH = entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height;
          if (newH > 0) {
            const oldH = this._heightCache.get(id);
            if (oldH == null || Math.abs(oldH - newH) > 1) {
              this._heightCache.set(id, newH);
              needsUpdate = true;
            }
          }
        }
      }
      if (needsUpdate) {
        this._rebuildPrefixSums();
        this._updateSpacers();
      }
    });

    this.container.addEventListener('scroll', () => {
      if (this._isUserScroll) {
        if (this._rafId == null) {
          this._rafId = requestAnimationFrame(() => {
            this._rafId = null;
            this._applyWindow();
          });
        }
      }
    }, { passive: true });
  }

  clear() {
    for (const el of this.messages.values()) {
      this._resizeObserver.unobserve(el);
      el.remove();
    }
    this.messages.clear();
    this.messageOrder = [];
    this._heightCache.clear();
    this._prefixSums = [];
    this._dirty = true;
    this._renderStart = 0;
    this._renderEnd = 0;
    this._topSpacer.style.height = '0px';
    this._bottomSpacer.style.height = '0px';
  }

  append(messageId, messageElement) {
    if (this.messages.has(messageId)) {
      this.update(messageId, messageElement);
      return;
    }
    messageElement.dataset.vlId = messageId;
    this.messages.set(messageId, messageElement);
    this.messageOrder.push(messageId);
    this._dirty = true;

    const idx = this.messageOrder.length - 1;
    this._heightCache.set(messageId, this._estimateHeight(messageElement));

    this._computeWindow();

    if (this._isInWindow(idx)) {
      this.container.insertBefore(messageElement, this._bottomSpacer);
      this._resizeObserver.observe(messageElement);
    }

    this._rebuildPrefixSums();
    this._updateSpacers();

    if (this._scrollToBottomPending) {
      this._scrollToBottomPending = false;
      requestAnimationFrame(() => this.scrollToBottom());
    }
    if (this._pendingScrollToId === messageId) {
      this._pendingScrollToId = null;
      requestAnimationFrame(() => this.scrollToMessage(messageId));
    }
  }

  prepend(messageId, messageElement) {
    if (this.messages.has(messageId)) {
      this.update(messageId, messageElement);
      return;
    }
    messageElement.dataset.vlId = messageId;
    this.messages.set(messageId, messageElement);
    this.messageOrder.unshift(messageId);
    this._dirty = true;

    this._heightCache.set(messageId, this._estimateHeight(messageElement));

    this._computeWindow();

    if (this._isInWindow(0)) {
      this.container.insertBefore(messageElement, this._topSpacer.nextSibling);
      this._resizeObserver.observe(messageElement);
    }

    this._rebuildPrefixSums();
    this._updateSpacers();
  }

  update(messageId, messageElement) {
    const existing = this.messages.get(messageId);
    if (existing) {
      this._resizeObserver.unobserve(existing);
    }
    messageElement.dataset.vlId = messageId;
    this.messages.set(messageId, messageElement);

    const idx = this.messageOrder.indexOf(messageId);
    if (idx >= 0 && this._isInWindow(idx)) {
      if (existing && existing.parentNode === this.container) {
        this.container.replaceChild(messageElement, existing);
      } else {
        this.container.insertBefore(messageElement, this._bottomSpacer);
      }
      this._resizeObserver.observe(messageElement);
    } else if (existing && existing.parentNode === this.container) {
      existing.remove();
    }
  }

  remove(messageId) {
    const el = this.messages.get(messageId);
    if (el) {
      this._resizeObserver.unobserve(el);
      el.remove();
      this.messages.delete(messageId);
      this._heightCache.delete(messageId);
      this.messageOrder = this.messageOrder.filter(id => id !== messageId);
      this._dirty = true;
      this._rebuildPrefixSums();
      this._updateSpacers();
    }
  }

  scrollToBottom() {
    this._isUserScroll = false;
    this.container.scrollTop = this.container.scrollHeight;
    requestAnimationFrame(() => {
      this.container.scrollTop = this.container.scrollHeight;
      requestAnimationFrame(() => {
        this.container.scrollTop = this.container.scrollHeight;
        this._isUserScroll = true;
      });
    });
  }

  scrollToTop() {
    this._isUserScroll = false;
    this.container.scrollTop = 0;
    requestAnimationFrame(() => { this._isUserScroll = true; });
  }

  scrollToMessage(messageId, highlight = false) {
    const idx = this.messageOrder.indexOf(messageId);
    if (idx < 0) return;

    this._ensureRendered(idx);

    requestAnimationFrame(() => {
      const el = this.messages.get(messageId);
      if (el && el.parentNode) {
        this._isUserScroll = false;
        el.scrollIntoView({ behavior: 'smooth', block: 'center' });
        requestAnimationFrame(() => { this._isUserScroll = true; });
        if (highlight) {
          el.classList.remove('message-flash-highlight');
          void el.offsetWidth;
          el.classList.add('message-flash-highlight');
          setTimeout(() => el.classList.remove('message-flash-highlight'), 2000);
        }
      }
    });
  }

  getMessageCount() {
    return this.messages.size;
  }

  hasMessage(messageId) {
    return this.messages.has(messageId);
  }

  isNearBottom(threshold = 100) {
    const { scrollTop, scrollHeight, clientHeight } = this.container;
    return scrollHeight - scrollTop - clientHeight < threshold;
  }

  isNearTop(threshold = 100) {
    return this.container.scrollTop < threshold;
  }

  _estimateHeight(el) {
    if (el.offsetHeight > 0) return el.offsetHeight;
    if (el.classList.contains('date-separator')) return 32;
    const role = el.classList.contains('message-user') ? 'user' :
                 el.classList.contains('message-system') ? 'system' : 'assistant';
    const content = el.querySelector('.message-content');
    if (content && content.shadowRoot) {
      const shadowDiv = content.shadowRoot.querySelector('.glaze-message');
      if (shadowDiv) {
        const textLen = (el.dataset.rawText || '').length;
        const hasCode = shadowDiv.querySelector('pre, .code-block-wrapper');
        const hasImg = shadowDiv.querySelector('img, .janitor-img-wrapper');
        if (hasImg) return 320;
        if (hasCode) return 250;
        if (textLen > 2000) return 500;
        if (textLen > 500) return 250;
        return 120;
      }
    }
    return role === 'system' ? 60 : 120;
  }

  _rebuildPrefixSums() {
    const n = this.messageOrder.length;
    this._prefixSums = new Array(n + 1);
    this._prefixSums[0] = 0;
    for (let i = 0; i < n; i++) {
      this._prefixSums[i + 1] = this._prefixSums[i] + (this._heightCache.get(this.messageOrder[i]) || 100);
    }
  }

  _getTotalHeight() {
    if (this._prefixSums.length === 0) return 0;
    return this._prefixSums[this._prefixSums.length - 1];
  }

  _findIndexAtOffset(offset) {
    let lo = 0, hi = this.messageOrder.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this._prefixSums[mid + 1] <= offset) lo = mid + 1;
      else hi = mid;
    }
    return Math.min(lo, this.messageOrder.length - 1);
  }

  _computeWindow() {
    const n = this.messageOrder.length;
    if (n === 0) {
      this._renderStart = 0;
      this._renderEnd = 0;
      return;
    }

    const scrollTop = this.container.scrollTop;
    const viewHeight = this.container.clientHeight;

    const startIdx = this._findIndexAtOffset(scrollTop);
    const endIdx = this._findIndexAtOffset(scrollTop + viewHeight);

    this._renderStart = Math.max(0, startIdx - this._bufferSize);
    this._renderEnd = Math.min(n, endIdx + this._bufferSize + 1);
  }

  _isInWindow(idx) {
    return idx >= this._renderStart && idx < this._renderEnd;
  }

  _applyWindow() {
    const oldStart = this._renderStart;
    const oldEnd = this._renderEnd;

    this._computeWindow();

    if (this._renderStart === oldStart && this._renderEnd === oldEnd && !this._dirty) return;
    this._dirty = false;

    const scrollTopBefore = this.container.scrollTop;

    for (let i = oldStart; i < oldEnd; i++) {
      if (i >= this._renderStart && i < this._renderEnd) continue;
      const id = this.messageOrder[i];
      const el = this.messages.get(id);
      if (el && el.parentNode === this.container) {
        this._resizeObserver.unobserve(el);
        el.remove();
      }
    }

    let insertBefore = this._bottomSpacer;
    for (let i = this._renderEnd - 1; i >= this._renderStart; i--) {
      const id = this.messageOrder[i];
      const el = this.messages.get(id);
      if (!el) continue;
      if (el.parentNode === this.container) continue;

      this.container.insertBefore(el, insertBefore);
      this._resizeObserver.observe(el);
      insertBefore = el;
    }

    this._updateSpacers();

    const scrollTopAfter = this.container.scrollTop;
    if (Math.abs(scrollTopAfter - scrollTopBefore) > 1) {
      this.container.scrollTop = scrollTopBefore;
    }
  }

  _updateSpacers() {
    const topH = this._renderStart < this._prefixSums.length
      ? this._prefixSums[this._renderStart]
      : 0;
    const totalH = this._getTotalHeight();
    const bottomStart = this._renderEnd < this._prefixSums.length
      ? this._prefixSums[this._renderEnd]
      : totalH;
    const bottomH = Math.max(0, totalH - bottomStart);

    this._topSpacer.style.height = `${topH}px`;
    this._bottomSpacer.style.height = `${bottomH}px`;
  }

  _ensureRendered(targetIdx) {
    const n = this.messageOrder.length;
    this._renderStart = Math.max(0, targetIdx - this._bufferSize);
    this._renderEnd = Math.min(n, targetIdx + this._bufferSize + 1);

    for (let i = this._renderStart; i < this._renderEnd; i++) {
      const id = this.messageOrder[i];
      const el = this.messages.get(id);
      if (!el || el.parentNode === this.container) continue;
      this.container.insertBefore(el, this._bottomSpacer);
      this._resizeObserver.observe(el);
    }

    this._updateSpacers();
  }

  _forceFullRender() {
    const n = this.messageOrder.length;
    this._renderStart = 0;
    this._renderEnd = n;

    for (let i = 0; i < n; i++) {
      const id = this.messageOrder[i];
      const el = this.messages.get(id);
      if (!el || el.parentNode === this.container) continue;
      this.container.insertBefore(el, this._bottomSpacer);
      this._resizeObserver.observe(el);
    }

    this._topSpacer.style.height = '0px';
    this._bottomSpacer.style.height = '0px';
  }

  setMessagesBatch(ids, elements) {
    for (const el of this.messages.values()) {
      this._resizeObserver.unobserve(el);
      el.remove();
    }
    this.messages.clear();
    this.messageOrder = [];
    this._heightCache.clear();
    this._prefixSums = [];
    this._dirty = true;

    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const el = elements[i];
      el.dataset.vlId = id;
      this.messages.set(id, el);
      this.messageOrder.push(id);
      this._heightCache.set(id, this._estimateHeight(el));
    }

    this._rebuildPrefixSums();
    this._computeWindow();

    const topH = this._renderStart < this._prefixSums.length
      ? this._prefixSums[this._renderStart]
      : 0;
    const totalH = this._getTotalHeight();
    const bottomStart = this._renderEnd < this._prefixSums.length
      ? this._prefixSums[this._renderEnd]
      : totalH;
    const bottomH = Math.max(0, totalH - bottomStart);

    for (let i = this._renderStart; i < this._renderEnd; i++) {
      const el = this.messages.get(this.messageOrder[i]);
      if (el) {
        this.container.insertBefore(el, this._bottomSpacer);
        this._resizeObserver.observe(el);
      }
    }

    this._updateSpacers();
  }

  pendingScrollToBottom() {
    this._scrollToBottomPending = true;
  }

  pendingScrollToMessage(messageId) {
    this._pendingScrollToId = messageId;
  }
}