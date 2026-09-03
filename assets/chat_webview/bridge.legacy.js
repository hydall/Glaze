/* ============================================================
 * Bridge — communication with Flutter side.
 * Selectors follow ChatMessage.vue's class naming (.message-section, .msg-*).
 * Flutter callHandler contract is preserved — useMessageActions lives in Dart.
 * ============================================================ */

class GenTimer {
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

class MessageUpdateBatcher {
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

class SelectionManager {
  constructor(sendToFlutter) {
    this._sendToFlutter = sendToFlutter;
    this._selectionMode = false;
    this._selectedIds = new Set();
    this._selectedText = '';
    this._barCreated = false;
  }

  get selectionMode() { return this._selectionMode; }

  getSelectedIds() { return [...this._selectedIds]; }

  setSelectionMode(enabled) {
    if (enabled && document.querySelector('.message-section.editing')) return;
    this._selectionMode = !!enabled;
    if (!enabled) this._selectedIds.clear();
    document.querySelectorAll('.message-section').forEach(msgEl => {
      msgEl.classList.toggle('selection-mode', this._selectionMode);
      msgEl.classList.toggle('selected', this._selectedIds.has(msgEl.dataset.messageId));
    });
  }

  toggleMessageSelection(messageId) {
    if (this._selectedIds.has(messageId)) this._selectedIds.delete(messageId);
    else this._selectedIds.add(messageId);
    const msgEl = document.querySelector(`[data-message-id="${messageId}"]`);
    if (msgEl) {
      msgEl.classList.toggle('selected', this._selectedIds.has(messageId));
    }
  }

  exitIfEmpty() {
    if (this._selectedIds.size === 0) this.setSelectionMode(false);
  }

  handleClick(e) {
    if (!this._selectionMode) return false;
    const section = e.target.closest('.message-section');
    if (!section) return false;
    e.preventDefault();
    e.stopPropagation();
    const id = section.dataset.messageId;
    this.toggleMessageSelection(id);
    this._sendToFlutter('onSelectionChange', [JSON.stringify(this.getSelectedIds())]);
    this.exitIfEmpty();
    return true;
  }

  handleContextMenu(e) {
    if (e.target.closest('.message-section.editing')) return false;
    const section = e.target.closest('.message-section');
    if (!section) return false;

    const id = section.dataset.messageId;
    const isSelected = this._selectedIds.has(id);
    const onBody = !!e.target.closest('.msg-body');

    if (this._selectionMode && isSelected && onBody) {
      return false;
    }

    e.preventDefault();

    if (this._selectionMode) {
      this.toggleMessageSelection(id);
      this._sendToFlutter('onSelectionChange', [JSON.stringify(this.getSelectedIds())]);
      this.exitIfEmpty();
    } else {
      if (document.querySelector('.message-section.editing')) return false;
      this.setSelectionMode(true);
      this.toggleMessageSelection(id);
      this._sendToFlutter('onSelectionChange', [JSON.stringify(this.getSelectedIds())]);
    }
    return true;
  }

  handleSelectionChange() {
    const editing = document.querySelector('.message-section.editing');
    if (editing) { this._hideSelectionBar(); return; }

    let selText = '';
    const sel = window.getSelection();
    if (sel && sel.toString().trim().length > 0) {
      selText = this._renderedSelectionText(sel);
    }
    if (!selText) {
      const hosts = document.querySelectorAll('.message-content');
      for (const el of hosts) {
        if (el.shadowRoot) {
          const shadowSel = el.shadowRoot.getSelection ? el.shadowRoot.getSelection() : null;
          if (shadowSel && shadowSel.toString().trim().length > 0) {
            selText = this._renderedSelectionText(shadowSel);
            break;
          }
        }
      }
    }
    if (selText) this._showSelectionBar(selText);
    else this._hideSelectionBar();
  }

  _renderedSelectionText(selection) {
    const host = document.createElement('div');
    host.style.cssText = 'position:fixed;left:-10000px;top:0;width:1000px;opacity:0;pointer-events:none;';
    const shadow = host.attachShadow({ mode: 'closed' });
    const content = document.createElement('div');
    for (let i = 0; i < selection.rangeCount; i++) {
      if (i > 0) content.appendChild(document.createElement('br'));
      content.appendChild(selection.getRangeAt(i).cloneContents());
    }
    shadow.appendChild(content);
    document.body.appendChild(host);
    const text = content.innerText.trim();
    host.remove();
    return text;
  }

  _showSelectionBar(text) {
    let bar = document.getElementById('selection-bar');
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'selection-bar';
      bar.className = 'selection-bar';
      bar.innerHTML = '<button class="sel-btn" data-action="copy">Copy</button><button class="sel-btn" data-action="quote">Quote</button>';
      bar.addEventListener('click', (e) => {
        const btn = e.target.closest('.sel-btn');
        if (!btn) return;
        const action = btn.dataset.action;
        this._sendToFlutter('onSelectionAction', [JSON.stringify({ action, text: this._selectedText })]);
        this._hideSelectionBar();
        window.getSelection().removeAllRanges();
      });
      document.body.appendChild(bar);
      this._barCreated = true;
    }
    this._selectedText = text;
    bar.style.display = 'flex';
  }

  _hideSelectionBar() {
    const bar = document.getElementById('selection-bar');
    if (bar) bar.style.display = 'none';
  }

  applyClassesToSection(section, classes) {
    if (this._selectionMode) classes.push('selection-mode');
    if (this._selectedIds.has(section.dataset.messageId || '')) classes.push('selected');
    return classes;
  }

  shouldHideActions() { return this._selectionMode; }

  hideSelectionBar() { this._hideSelectionBar(); }
}

class EditController {
  constructor(sendToFlutter) {
    this._sendToFlutter = sendToFlutter;
  }

  startEdit(messageId, scrollTopFn) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return;

    const scrollPos = scrollTopFn();
    section.classList.add('editing');

    // Mirrors bridge/edit_controller.js: edit the stored text, never the
    // rendered one, so a display-only regex is not saved over its own source.
    const editSource = section.dataset.sourceText ?? section.dataset.rawText ?? '';
    const rawText = editSource.replace(/^<think\b[^>]*>[\s\S]*?<\/think>\s*/, '');
    const reasoning = section.dataset.reasoning || '';
    let editText = rawText;
    if (reasoning) editText = '<' + 'think>\n' + reasoning + '\n</' + 'think>\n' + rawText;

    const body = section.querySelector('.msg-body');
    if (!body) return;

    body.dataset.originalHtml = body.innerHTML;
    body.innerHTML = '';
    const textarea = document.createElement('textarea');
    textarea.className = 'edit-textarea';
    textarea.rows = 1;
    textarea.value = editText;
    textarea.dataset.originalText = editText;
    body.appendChild(textarea);

    textarea.addEventListener('wheel', (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.deltaMode === 0) {
        textarea.scrollTop += e.deltaY * 0.3;
      } else if (e.deltaMode === 1) {
        textarea.scrollTop += e.deltaY * 16;
      } else {
        textarea.scrollTop += e.deltaY * textarea.clientHeight;
      }
    }, { passive: false });

    // Modern Chromium (123+) sizes textareas to content via `field-sizing: content`.
    // Old WebViews don't — fall back to JS-driven auto-grow on input.
    const supportsFieldSizing = typeof CSS !== 'undefined'
      && CSS.supports && CSS.supports('field-sizing', 'content');
    if (!supportsFieldSizing) {
      const autoGrow = () => {
        textarea.style.height = 'auto';
        textarea.style.height = textarea.scrollHeight + 'px';
      };
      textarea.addEventListener('input', autoGrow);
      autoGrow();
    }

    textarea.focus();

    const footer = section.querySelector('.msg-footer');
    if (footer) {
      footer.dataset.originalHtml = footer.innerHTML;
      footer.innerHTML = '';

      const metaCol = document.createElement('div');
      metaCol.className = 'msg-meta';
      footer.appendChild(metaCol);

      const center = document.createElement('div');
      center.className = 'msg-center-controls';
      footer.appendChild(center);

      const editBox = document.createElement('div');
      editBox.className = 'edit-buttons';
      editBox.innerHTML = `
        <div class="edit-btn cancel" data-action="edit-cancel" data-message-id="${messageId}" title="Cancel">
          <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
        </div>
        <div class="edit-btn save" data-action="edit-save" data-message-id="${messageId}" title="Save">
          <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
        </div>
      `;
      footer.appendChild(editBox);
    }

    scrollTopFn(scrollPos);
  }

  stopEdit(messageId) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return;
    section.classList.remove('editing');

    const body = section.querySelector('.msg-body');
    if (body && body.dataset.originalHtml !== undefined) {
      body.innerHTML = body.dataset.originalHtml;
      delete body.dataset.originalHtml;
    }
    const footer = section.querySelector('.msg-footer');
    if (footer && footer.dataset.originalHtml !== undefined) {
      footer.innerHTML = footer.dataset.originalHtml;
      delete footer.dataset.originalHtml;
    }
  }

  handleSave(el) {
    const section = el.closest('.message-section');
    const ta = section ? section.querySelector('.edit-textarea') : null;
    this._sendToFlutter('onEditSave', [el.dataset.messageId, ta ? ta.value : '']);
  }

  handleCancel(el) {
    this._sendToFlutter('onEditCancel', [el.dataset.messageId]);
  }

  isEditing(section) {
    return section && section.classList.contains('editing');
  }
}

class SwipeGestureHandler {
  constructor(sendToFlutter, getContainer, isGeneratingFn, disableRegenFn) {
    this._sendToFlutter = sendToFlutter;
    this._getContainer = getContainer;
    this._isGenerating = isGeneratingFn;
    this._disableRegen = disableRegenFn || (() => false);
  }

  setup() {
    const THRESHOLD = 100;
    let startX = 0;
    let startY = 0;
    let activeBody = null;
    let activeSection = null;
    let scrollingVertical = false;
    const self = this;

    const reset = (body) => {
      body.style.transition = 'transform 0.3s ease';
      body.style.transform = '';
      setTimeout(() => { body.style.transition = ''; }, 300);
    };

    const onStart = (e) => {
      if (self._isGenerating()) return;

      const path = e.composedPath ? e.composedPath() : (e.path || []);
      const isScrollableX = path.some(el => {
        if (el.nodeType === Node.ELEMENT_NODE) {
          const style = window.getComputedStyle(el);
          if (style.overflowX === 'auto' || style.overflowX === 'scroll') {
            if (el.scrollWidth > el.clientWidth) return true;
          }
        }
        return false;
      });
      if (isScrollableX) return;

      const section = e.target.closest?.('.message-section.char');
      if (!section) return;
      if (section.classList.contains('editing') || section.classList.contains('selection-mode')) return;
      const body = section.querySelector('.msg-body');
      if (!body) return;
      const t = e.touches ? e.touches[0] : e;
      startX = t.clientX;
      startY = t.clientY;
      scrollingVertical = false;
      activeSection = section;
      activeBody = body;
      body.style.transition = 'none';
    };

    const onMove = (e) => {
      if (!activeBody || !activeSection) return;
      const t = e.touches ? e.touches[0] : e;
      const dx = t.clientX - startX;
      const dy = t.clientY - startY;
      if (scrollingVertical) return;
      if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 10) {
        scrollingVertical = true;
        activeBody.style.transform = '';
        return;
      }

      const swipeId = parseInt(activeSection.dataset.swipeId || '0', 10);
      const swipeTotal = parseInt(activeSection.dataset.swipeTotal || '1', 10);
      const isLast = activeSection.dataset.isLast === 'true';
      const greetingTotal = parseInt(activeSection.dataset.greetingTotal || '0', 10);
      const isFirstMsg = activeSection.dataset.messageIndex === '0';
      const canSwitchGreeting = isFirstMsg && greetingTotal > 1;

      const blockLastRegen = isLast && self._disableRegen();
      if (dx < 0 && !canSwitchGreeting && (blockLastRegen || !isLast) && swipeId >= swipeTotal - 1) return;
      if (dx > 0 && !canSwitchGreeting && swipeId <= 0) return;

      if (e.cancelable) e.preventDefault();
      activeBody.style.transform = `translateX(${dx}px)`;
    };

    const onEnd = (e) => {
      if (!activeBody || !activeSection) return;
      const body = activeBody;
      const section = activeSection;
      activeBody = null;
      activeSection = null;
      if (scrollingVertical) { body.style.transform = ''; body.style.transition = ''; return; }

      const t = e.changedTouches ? e.changedTouches[0] : e;
      const dx = t.clientX - startX;

      const swipeId = parseInt(section.dataset.swipeId || '0', 10);
      const swipeTotal = parseInt(section.dataset.swipeTotal || '1', 10);
      const isLast = section.dataset.isLast === 'true';
      const greetingTotal = parseInt(section.dataset.greetingTotal || '0', 10);
      const isFirstMsg = section.dataset.messageIndex === '0';
      const canSwitchGreeting = isFirstMsg && greetingTotal > 1;
      const msgId = section.dataset.messageId;

      if (canSwitchGreeting) {
        if (dx < -THRESHOLD) {
          self.animateVariantSwap(msgId, 'next', () => self._sendToFlutter('onChangeGreeting', [msgId, 1]), dx);
        } else if (dx > THRESHOLD) {
          self.animateVariantSwap(msgId, 'prev', () => self._sendToFlutter('onChangeGreeting', [msgId, -1]), dx);
        } else {
          reset(body);
        }
        return;
      }

      if (dx < -THRESHOLD) {
        if (swipeId < swipeTotal - 1) {
          self.animateVariantSwap(msgId, 'next', () => self._sendToFlutter('onSwipe', [JSON.stringify({ id: msgId, direction: 'right' })]), dx);
        } else if (isLast && !self._disableRegen()) {
          body.style.transition = 'transform 0.1s';
          body.style.transform = 'translateX(-20px)';
          setTimeout(() => {
            body.style.transform = '';
            body.style.transition = '';
            self._sendToFlutter('onRegenerate', [msgId, 'new_variant']);
          }, 100);
        } else {
          reset(body);
        }
      } else if (dx > THRESHOLD) {
        if (swipeId > 0) {
          self.animateVariantSwap(msgId, 'prev', () => self._sendToFlutter('onSwipe', [JSON.stringify({ id: msgId, direction: 'left' })]), dx);
        } else {
          reset(body);
        }
      } else {
        reset(body);
      }
    };

    const container = this._getContainer();
    container.addEventListener('touchstart', onStart, { passive: true });
    container.addEventListener('touchmove', onMove, { passive: false });
    container.addEventListener('touchend', onEnd);
    container.addEventListener('touchcancel', onEnd);
  }

  /* Slide + fade animation for variant switching.  Used by both the prev/next
   * buttons and the touch-swipe gesture.  The body's height is locked through
   * the swap and then animated to the new content's natural height, so the
   * page doesn't jump when variants have different lengths.
   *
   * `currentX` lets the touch path pass the drag's current offset so the exit
   * continues the gesture outward instead of snapping back toward center. */
  animateVariantSwap(messageId, dir, after, currentX = 0) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    const body = section?.querySelector('.msg-body');
    if (!body) { after(); return; }

    // dir: 'next' → exit to left, enter from right.  'prev' → mirror.
    const sign = dir === 'next' ? -1 : (dir === 'prev' ? 1 : 0);
    // Exit: continue past current drag position; click case uses a small hint.
    const outX = currentX !== 0 ? currentX + sign * 40 : sign * 28;
    // Entrance always slides in from a fixed offset on the opposite side.
    const inX = sign * -28;

    // Lock current height so the (async) content swap doesn't reflow the page.
    const startHeight = body.offsetHeight;
    body.style.height = `${startHeight}px`;
    body.style.overflow = 'hidden';
    body.style.transition = 'opacity 0.12s ease, transform 0.12s ease';
    body.style.opacity = '0';
    if (outX) body.style.transform = `translateX(${outX}px)`;

    setTimeout(() => {
      let done = false;
      let fallback;
      const finish = () => {
        if (done) return;
        done = true;
        mo.disconnect();
        clearTimeout(fallback);

        // Measure new content's natural height
        body.style.height = 'auto';
        const targetHeight = body.offsetHeight;
        body.style.height = `${startHeight}px`;

        requestAnimationFrame(() => {
          body.style.transition = 'opacity 0.22s ease, transform 0.22s ease, height 0.22s ease';
          body.style.opacity = '1';
          body.style.transform = '';
          body.style.height = `${targetHeight}px`;
          setTimeout(() => {
            body.style.transition = '';
            body.style.transform = '';
            body.style.height = '';
            body.style.overflow = '';
          }, 240);
        });
      };

      // The renderer rewrites section dataset (rawText / swipeId / etc) when
      // Flutter's updateMessage arrives — that's our cue to animate in.
      const mo = new MutationObserver(finish);
      mo.observe(section, { attributes: true });
      // Fallback in case the update is a no-op or attribute setter is skipped.
      fallback = setTimeout(finish, 300);

      after();
      body.style.transition = 'none';
      if (inX) body.style.transform = `translateX(${inX}px)`;
    }, 130);
  }

  toggleGuidedSwipe(messageId) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return;

    const btn = section.querySelector('.msg-guided-swipe-btn');
    const existing = section.querySelector('.guided-swipe-container');
    if (existing) {
      existing.remove();
      btn?.classList.remove('active');
      return;
    }

    const container = document.createElement('div');
    container.className = 'guided-swipe-container';

    const main = document.createElement('div');
    main.className = 'guidance-main';
    main.innerHTML = `<div class="guidance-header">GUIDED SWIPE</div>`;
    const textarea = document.createElement('textarea');
    textarea.className = 'guided-swipe-textarea';
    textarea.placeholder = 'Enter OOC instruction for swipe...';
    textarea.rows = 1;
    main.appendChild(textarea);
    container.appendChild(main);

    const self = this;
    const actions = document.createElement('div');
    actions.className = 'guided-swipe-actions';

    const cancel = document.createElement('div');
    cancel.className = 'guided-btn cancel';
    cancel.innerHTML = '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>';
    cancel.addEventListener('click', () => {
      container.remove();
      btn?.classList.remove('active');
    });
    actions.appendChild(cancel);

    const confirm = document.createElement('div');
    confirm.className = 'guided-btn confirm';
    confirm.innerHTML = '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>';
    confirm.addEventListener('click', () => {
      const guidance = textarea.value.trim();
      if (guidance) self._sendToFlutter('onGuidedSwipe', [messageId, guidance]);
      container.remove();
      btn?.classList.remove('active');
    });
    actions.appendChild(confirm);

    container.appendChild(actions);

    const stack = section.querySelector('.msg-content-stack');
    if (stack && stack.parentNode === section) {
      section.insertBefore(container, stack.nextSibling);
    } else {
      section.appendChild(container);
    }

    btn?.classList.add('active');
    textarea.focus();
  }
}

class InteractionDispatch {
  constructor(bridge) {
    this.bridge = bridge;
  }

  handleClick(e) {
    const bridge = this.bridge;

    if (bridge._selectionManager.handleClick(e)) return;

    const reasoningHdr = e.target.closest('[data-action="toggle-reasoning"]');
    if (reasoningHdr) {
      const block = reasoningHdr.closest('.msg-reasoning');
      if (block) block.classList.toggle('collapsed');
      return;
    }

    const actionEl = e.target.closest('[data-action]');
    if (actionEl) {
      const action = actionEl.dataset.action;
      const handler = this._actionMap[action];
      if (handler) {
        handler.call(this, e, actionEl);
        return;
      }
    }

    const link = e.target.closest('a');
    if (link) {
      e.preventDefault();
      bridge._sendToFlutter('onLinkClick', [link.href]);
      return;
    }

    const stopBtn = e.target.closest('.stop-btn');
    if (stopBtn) {
      bridge._sendToFlutter('onStop', []);
      return;
    }

    const regenBtn = e.target.closest('.msg-regenerate');
    if (regenBtn) {
      const id = regenBtn.dataset.messageId;
      const mode = regenBtn.dataset.mode || 'magic';
      bridge._sendToFlutter('onRegenerate', [id, mode]);
      return;
    }

    const guidedBtn = e.target.closest('.msg-guided-swipe-btn');
    if (guidedBtn) {
      bridge._swipeHandler.toggleGuidedSwipe(guidedBtn.dataset.messageId);
      return;
    }

    const actionsBtn = e.target.closest('.msg-actions-btn');
    if (actionsBtn) {
      const id = actionsBtn.dataset.messageId;
      const section = document.querySelector(`[data-message-id="${id}"]`);
      if (section) {
        const isUser = section.classList.contains('user');
        const isSystem = section.classList.contains('system');
        const content = bridge._extractText(section);
        bridge._sendToFlutter('onMessageContext', [JSON.stringify({ id, isUser, isSystem, content })]);
      }
      return;
    }

    const errorCopyBtn = e.target.closest('.error-copy-btn');
    if (errorCopyBtn) {
      const id = errorCopyBtn.dataset.messageId;
      const section = document.querySelector(`[data-message-id="${id}"]`);
      if (section) {
        const raw = section.dataset.rawText || '';
        try { navigator.clipboard.writeText(raw); }
        catch (_) {
          const ta = document.createElement('textarea');
          ta.value = raw;
          document.body.appendChild(ta);
          ta.select();
          document.execCommand('copy');
          ta.remove();
        }
        errorCopyBtn.dataset.copied = '1';
        setTimeout(() => { delete errorCopyBtn.dataset.copied; }, 1200);
      }
      return;
    }

    const avatar = e.target.closest('.msg-avatar');
    if (avatar) {
      const img = avatar.querySelector('img');
      if (img && img.src) bridge._sendToFlutter('onImageClick', [img.src]);
      return;
    }

    const img = e.target.closest('.msg-image-attachment img');
    if (img && img.src) {
      bridge._sendToFlutter('onImageClick', [img.src]);
      return;
    }

    bridge._selectionManager.hideSelectionBar();
  }

  _extractImgInstruction(el, path) {
    const sec = path.find(e => e.dataset?.messageId);
    const messageId = sec ? sec.dataset.messageId : '';
    let instr = '';
    try { instr = decodeURIComponent(el.dataset.instruction || ''); }
    catch (_) { instr = el.dataset.instruction || ''; }
    const raw = parseInt(el.dataset.imgIndex, 10);
    const imgIndex = Number.isInteger(raw) && raw >= 0 ? raw : -1;
    return { instr, messageId, imgIndex };
  }

  get _actionMap() {
    const bridge = this.bridge;
    return {
      'memory-click': (e, el) => bridge._sendToFlutter('onMemoryClick', [el.dataset.messageId]),
      'inject-click': (e, el) => bridge._sendToFlutter('onInjectClick', [el.dataset.messageId]),
      'ext-blocks-run-all': (e, el) => bridge._sendToFlutter('onExtBlocksRunAll', [el.dataset.messageId]),
      'ext-block-stop': (e, el) => bridge._sendToFlutter('onExtBlockStop', [el.dataset.blockId, el.dataset.messageId]),
      'ext-block-regen': (e, el) => bridge._sendToFlutter('onExtBlockRegen', [el.dataset.blockId, el.dataset.messageId]),
      'ext-block-regen-image': (e, el) => bridge._sendToFlutter('onExtBlockRegenImage', [el.dataset.blockId, el.dataset.messageId]),
      'ext-block-edit': (e, el) => bridge._sendToFlutter('onExtBlockEdit', [el.dataset.blockId, el.dataset.messageId]),
      'ext-block-delete': (e, el) => bridge._sendToFlutter('onExtBlockDelete', [el.dataset.blockId, el.dataset.messageId]),
      'toggle-hidden': (e, el) => bridge._sendToFlutter('onToggleHidden', [el.dataset.messageId]),
      'toggle-image-hidden': (e, el) => {
        const section = el.closest('.message-section');
        bridge._sendToFlutter('onToggleImageHidden', [section ? section.dataset.messageId : '']);
      },
      'swipe-left': (e, el) => {
        const id = el.dataset.messageId;
        bridge._swipeHandler.animateVariantSwap(id, 'prev', () =>
          bridge._sendToFlutter('onSwipe', [JSON.stringify({ id, direction: 'left' })])
        );
      },
      'swipe-right': (e, el) => {
        const id = el.dataset.messageId;
        bridge._swipeHandler.animateVariantSwap(id, 'next', () =>
          bridge._sendToFlutter('onSwipe', [JSON.stringify({ id, direction: 'right' })])
        );
      },
      'greeting-prev': (e, el) => {
        const id = el.dataset.messageId;
        bridge._swipeHandler.animateVariantSwap(id, 'prev', () =>
          bridge._sendToFlutter('onChangeGreeting', [id, -1])
        );
      },
      'greeting-next': (e, el) => {
        const id = el.dataset.messageId;
        bridge._swipeHandler.animateVariantSwap(id, 'next', () =>
          bridge._sendToFlutter('onChangeGreeting', [id, 1])
        );
      },
      'stop': (e, el) => bridge._sendToFlutter('onStop', []),
      'regenerate': (e, el) => bridge._sendToFlutter('onRegenerate', [el.dataset.messageId, el.dataset.mode || 'magic']),
      'toggle-guided': (e, el) => bridge._swipeHandler.toggleGuidedSwipe(el.dataset.messageId),
      'edit-save': (e, el) => bridge._editController.handleSave(el),
      'edit-cancel': (e, el) => bridge._editController.handleCancel(el),
      'open-actions': (e, el) => {
        const id = el.dataset.messageId;
        const section = document.querySelector(`[data-message-id="${id}"]`);
        if (section) {
          const isUser = section.classList.contains('user');
          const isSystem = section.classList.contains('system');
          const content = bridge._extractText(section);
          bridge._sendToFlutter('onMessageContext', [JSON.stringify({ id, isUser, isSystem, content })]);
        }
      },
      'img-retry': (e, el) => {
        const { instr, messageId, imgIndex } = this._extractImgInstruction(el, e.composedPath());
        bridge._sendToFlutter('onImgRetry', [instr, messageId, imgIndex]);
      },
      'img-enable-retry': (e, el) => {
        const { instr, messageId, imgIndex } = this._extractImgInstruction(el, e.composedPath());
        bridge._sendToFlutter('onImgEnableRetry', [instr, messageId, imgIndex]);
      },
      'img-find': (e, el) => {
        const { instr, messageId, imgIndex } = this._extractImgInstruction(el, e.composedPath());
        bridge._sendToFlutter('onImgFind', [instr, messageId, imgIndex]);
      },
      'img-regen': (e, el) => {
        const { instr, messageId, imgIndex } = this._extractImgInstruction(el, e.composedPath());
        bridge._sendToFlutter('onImgRegen', [instr, messageId, imgIndex]);
      },
      'img-stop': (e, el) => bridge._sendToFlutter('onImgCancel', []),
      'image-click': (e, el) => {
        const src = el.dataset.src || (el.tagName === 'IMG' ? el.src : '');
        if (src) bridge._sendToFlutter('onImageClick', [src]);
      },
      'img-download': (e, el) => {
        const src = el.dataset.src || '';
        if (src) bridge._sendToFlutter('onImgDownload', [src]);
      },
    };
  }
}

class Bridge {
  constructor(renderer, virtualList) {
    this.renderer = renderer;
    this.virtualList = virtualList;
    this._pendingRequests = new Map();
    this._requestCounter = 0;
    this.isGenerating = false;
    this.isGeneratingImage = false;
    this._genTimer = new GenTimer(renderer);
    this._updateBatcher = new MessageUpdateBatcher();
    this._selectionManager = new SelectionManager((name, args) => this._sendToFlutter(name, args));
    this._editController = new EditController((name, args) => this._sendToFlutter(name, args));
    this._interaction = new InteractionDispatch(this);
    this._charName = null;
    this._personaName = null;
    this._charAvatarUrl = null;
    this._personaAvatarUrl = null;
    this.batterySaver = false;
    this.disableSwipeRegeneration = false;
    renderer.selectionManager = this._selectionManager;
    this._swipeHandler = new SwipeGestureHandler(
      (name, args) => this._sendToFlutter(name, args),
      () => this.virtualList.container,
      () => this.isGenerating,
      () => this.disableSwipeRegeneration,
    );
    this._setupScrollListener();
    this._setupInteractionListener();
    this._setupGlazeRequestRelay();
    this._setupImageClickForward();
    this._swipeHandler.setup();
  }

  /* ---------- Identity (active char / persona) ---------- */
  setIdentity(opts) {
    opts = opts || {};
    if ('charName' in opts) this._charName = opts.charName || null;
    if ('personaName' in opts) this._personaName = opts.personaName || null;
    if ('charAvatarUrl' in opts) this._charAvatarUrl = opts.charAvatarUrl || null;
    if ('personaAvatarUrl' in opts) this._personaAvatarUrl = opts.personaAvatarUrl || null;
    this._refreshIdentityDom();
  }

  _refreshIdentityDom() {
    const sections = document.querySelectorAll('.message-section.user, .message-section.char');
    sections.forEach(section => {
      const isUser = section.classList.contains('user');
      const stored = section.dataset.personaName || '';
      const storedPersonaName = stored === 'You' ? '' : stored;
      // A message pinned to the persona it was sent as keeps that persona's
      // name and avatar — the letter included, when the persona was deleted.
      // Only unpinned messages follow the active identity.
      const pinned = section.dataset.avatarPinned === '1';
      // Per-message stored persona wins; otherwise use the active identity.
      const newName = isUser
        ? ((pinned ? stored : storedPersonaName) || this._personaName || 'You')
        : (this._charName || stored || 'Character');
      const newAvatarUrl = pinned
        ? (section.dataset.avatarUrl || null)
        : (isUser ? this._personaAvatarUrl : this._charAvatarUrl);

      const label = section.querySelector('.msg-name-label');
      if (label) label.textContent = newName;

      const avatar = section.querySelector('.msg-avatar');
      if (!avatar) return;
      const existingImg = avatar.querySelector('img');
      if (newAvatarUrl) {
        if (existingImg) {
          if (existingImg.src !== newAvatarUrl) existingImg.src = newAvatarUrl;
          existingImg.alt = newName;
        } else {
          avatar.textContent = '';
          const img = document.createElement('img');
          img.src = newAvatarUrl;
          img.alt = newName;
          avatar.appendChild(img);
        }
      } else {
        if (existingImg) existingImg.remove();
        avatar.textContent = (newName.charAt(0) || '?').toUpperCase();
      }
    });
  }

  setGenerating(value) {
    this.isGenerating = value;
    if (value) {
      this._genTimer.start();
    } else {
      this._genTimer.stop();
    }
  }

  /* ---------- Flutter transport ---------- */
  _sendToFlutter(name, args) {
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler(name, ...args);
    }
  }

  _requestToFlutter(name, args, timeoutMs = 60000) {
    return new Promise((resolve, reject) => {
      const requestId = `${name}_${++this._requestCounter}`;
      const timer = setTimeout(() => {
        this._pendingRequests.delete(requestId);
        reject(new Error(`Bridge request "${name}" timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this._pendingRequests.set(requestId, { resolve, reject, timer });
      this._sendToFlutter(name, [requestId, ...args]);
    });
  }

  _setupGlazeRequestRelay() {
    window.addEventListener('message', async (e) => {
      const data = e.data || {};
      if (!data || data.type !== 'glaze:request') return;
      if (!e.source) return;
      try {
        const result = await this._callGlazeBridge({
          id: data.id,
          method: data.method,
          params: data.params || {},
          context: data.context || {},
        });
        e.source.postMessage({ type: 'glaze:response', id: data.id, ok: true, result }, '*');
      } catch (error) {
        e.source.postMessage({
          type: 'glaze:response',
          id: data.id,
          ok: false,
          error: { code: error && error.code, message: String(error && error.message ? error.message : error) },
        }, '*');
      }
    });
  }

  async _callGlazeBridge(request) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      throw new Error('Flutter bridge is not available');
    }
    const response = await window.flutter_inappwebview.callHandler('glazeBridge', request);
    if (response && response.ok === false) {
      const error = response.error || {};
      const bridgeError = new Error(error.message || 'Glaze bridge error');
      bridgeError.code = error.code;
      throw bridgeError;
    }
    return response && Object.prototype.hasOwnProperty.call(response, 'result')
      ? response.result
      : response;
  }

  _resolveRequest(requestId, result) {
    const pending = this._pendingRequests.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timer);
    this._pendingRequests.delete(requestId);
    pending.resolve(result);
  }

  _rejectRequest(requestId, error) {
    const pending = this._pendingRequests.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timer);
    this._pendingRequests.delete(requestId);
    pending.reject(new Error(error));
  }

  /* ---------- Scroll / load-more ---------- */
  _setupScrollListener() {
    let loadMoreCooldown = false;
    let lastLoadTop = 0;
    let lastShowScrollToBottom = null;
    // Header hide-on-scroll (ported from Glaze/src/core/services/ui.js initHeaderScroll)
    let headerLastTop = 0;
    let headerHidden = false;
    let ticking = false;
    const container = this.virtualList.container;

    const emitScrollToBottomVisibility = () => {
      const distanceFromBottom =
        container.scrollHeight - container.scrollTop - container.clientHeight;
      const show = distanceFromBottom > 240;
      if (lastShowScrollToBottom === show) return;
      lastShowScrollToBottom = show;
      this._sendToFlutter('onScrollToBottomVisibility', [show]);
    };

    const updateHeader = () => {
      ticking = false;
      const st = container.scrollTop;
      // Streaming auto-follow must not hide the header, but an explicit upward
      // scroll should still restore an already-hidden header.
      if (this.isGenerating) {
        if (st < headerLastTop - 3 && headerHidden) {
          headerHidden = false;
          this._sendToFlutter('onHeaderScroll', [false]);
        }
        headerLastTop = st <= 0 ? 0 : st;
        return;
      }
      if (st < 0 || st + container.clientHeight > container.scrollHeight) {
        headerLastTop = st <= 0 ? 0 : st;
        return;
      }
      if (st > headerLastTop + 3 && st > 50) {
        if (!headerHidden) {
          headerHidden = true;
          this._sendToFlutter('onHeaderScroll', [true]);
        }
      } else if (st < headerLastTop - 3) {
        if (headerHidden) {
          headerHidden = false;
          this._sendToFlutter('onHeaderScroll', [false]);
        }
      }
      headerLastTop = st <= 0 ? 0 : st;
    };

    container.addEventListener('scroll', () => {
      // Load-more on upward scroll near top.
      if (!loadMoreCooldown && !this._suppressLoadMore) {
        const st = container.scrollTop;
        const scrollingUp = st < lastLoadTop;
        lastLoadTop = st;
        if (scrollingUp && this.virtualList.isNearTop(500)) {
          loadMoreCooldown = true;
          this._sendToFlutter('onLoadMore', []);
          setTimeout(() => { loadMoreCooldown = false; }, 500);
        }
      }
      // Header hide via rAF throttling.
      if (!ticking) {
        ticking = true;
        requestAnimationFrame(updateHeader);
      }
      emitScrollToBottomVisibility();
    }, { passive: true });

    requestAnimationFrame(emitScrollToBottomVisibility);
  }

  /* ---------- Interaction dispatch ---------- */
  _setupInteractionListener() {
    document.addEventListener('click', (e) => this._interaction.handleClick(e));

    document.addEventListener('selectionchange', () => this._selectionManager.handleSelectionChange());

    document.addEventListener('contextmenu', (e) => this._selectionManager.handleContextMenu(e));
  }

  _extractText(section) {
    const host = section.querySelector('.msg-body .message-content');
    if (host && host.shadowRoot) {
      const root = host.shadowRoot.querySelector('.glaze-message');
      if (root) return root.innerText || '';
    }
    return section.dataset.rawText || '';
  }

  /* ---------- Loading screen ---------- */
  _hideLoadingScreen() {
    const loading = document.getElementById('loading-screen');
    if (loading) {
      loading.style.opacity = '0';
      setTimeout(() => loading.remove(), 200);
    }
  }

  _showLoadingScreen() {
    let loading = document.getElementById('loading-screen');
    if (!loading) {
      loading = document.createElement('div');
      loading.id = 'loading-screen';
      loading.textContent = 'Loading...';
      document.body.insertBefore(loading, document.body.firstChild);
    }
    loading.style.opacity = '1';
    loading.style.display = 'flex';
  }

  /* ---------- Message list API ---------- */
  setMessages(messagesJson) {
    this.flush();
    this._suppressLoadMore = true;
    this._panelHost?.closeAll();
    const container = document.getElementById('chat-container') || document.body;
    if (![...container.classList].some(c => c.startsWith('layout-'))) {
      container.classList.add('layout-default');
    }

    this.renderer.resetDateTracking();
    const messages = JSON.parse(messagesJson);

    const ids = [];
    const elements = [];
    for (const msg of messages) {
      const rendered = this.renderer.renderMessage(msg);
      for (const el of rendered) {
        const id = el.dataset.messageId || `__date_${el.dataset.dateSeparator || Date.now()}`;
        ids.push(id);
        elements.push(el);
      }
    }

    this.virtualList.setMessagesBatch(ids, elements);
    this._hideLoadingScreen();
    setTimeout(() => { this._suppressLoadMore = false; }, 1000);
  }

  appendMessage(messageJson) {
    this.flush();
    const msg = JSON.parse(messageJson);
    const rendered = this.renderer.renderMessage(msg);
    for (const el of rendered) {
      const id = el.dataset.messageId || `__date_${el.dataset.dateSeparator || Date.now()}`;
      this.virtualList.append(id, el);
    }
    this.virtualList.scrollToBottom();
  }

  appendMessages(messagesJson) {
    this.flush();
    const messages = JSON.parse(messagesJson);
    messages.forEach(msg => {
      const rendered = this.renderer.renderMessage(msg);
      for (const el of rendered) {
        const id = el.dataset.messageId || `__date_${el.dataset.dateSeparator || Date.now()}`;
        this.virtualList.append(id, el);
      }
    });
  }

  prependMessages(messagesJson) {
    this.flush();
    this._suppressLoadMore = true;
    const messages = JSON.parse(messagesJson);
    const scrollBefore = this.virtualList.container.scrollHeight;
    for (let i = messages.length - 1; i >= 0; i--) {
      const msg = messages[i];
      const rendered = this.renderer.renderMessage(msg);
      for (let j = rendered.length - 1; j >= 0; j--) {
        const el = rendered[j];
        const id = el.dataset.messageId || `__date_${el.dataset.dateSeparator || Date.now()}`;
        this.virtualList.prepend(id, el);
      }
    }
    const scrollAfter = this.virtualList.container.scrollHeight;
    this.virtualList.container.scrollTop += scrollAfter - scrollBefore;
    this._hideLoadingScreen();
    setTimeout(() => { this._suppressLoadMore = false; }, 500);
  }

  updateMessage(messageJson) {
    const msg = JSON.parse(messageJson);
    this._updateBatcher.enqueue(msg.id, () => this._executeUpdateMessage(msg));
  }

  _executeUpdateMessage(msg) {
    const section = document.querySelector(`[data-message-id="${msg.id}"]`);
    if (!section) return;

    const animate = !!msg.swipeDirection;
    if (msg.swipeDirection) section.dataset.swipeDirection = msg.swipeDirection;

    if (msg.reasoning) section.dataset.reasoning = msg.reasoning;
    else if (msg.reasoning === null || msg.reasoning === '') delete section.dataset.reasoning;

    if (msg.text != null) section.dataset.rawText = msg.text;
    if (msg.sourceText != null) section.dataset.sourceText = msg.sourceText;
    else if (msg.text != null) delete section.dataset.sourceText;

    if (msg.isError !== undefined) section.classList.toggle('error', !!msg.isError);

    const isUser = section.classList.contains('user');
    this.renderer.updateMessageContent(
      section,
      msg.text != null ? msg.text : (section.dataset.rawText || ''),
      msg.reasoning ?? null,
      isUser,
      !!msg.isTyping,
      animate
    );

    if (msg.isHidden !== undefined) {
      section.classList.toggle('msg-hidden', !!msg.isHidden);
    }

    if (msg.swipeIndex !== undefined) section.dataset.swipeId = String(msg.swipeIndex);
    if (msg.swipeTotal !== undefined) section.dataset.swipeTotal = String(msg.swipeTotal);
    if (msg.greetingTotal !== undefined) section.dataset.greetingTotal = String(msg.greetingTotal);

    // Restore data-is-last on char sections after generation ends.
    // setLastMessage(null) clears it at generation start; without this
    // the swipe gesture handler sees isLast=false and blocks subsequent
    // left-swipe-to-regenerate gestures.
    if (msg.isLast !== undefined && !section.classList.contains('user')) {
      if (msg.isLast) section.dataset.isLast = 'true';
      else delete section.dataset.isLast;
    }

    this._syncMessageControls(section, msg);

    this.renderer.updateMessageMeta(section, msg);
  }

  flush() { this._updateBatcher.flush(); }

  _syncMessageControls(section, msg) {
    const center = section.querySelector('.msg-center-controls');
    if (!center) return;

    const isChar = section.classList.contains('char');
    const isEditing = section.classList.contains('editing');
    const isLast = section.dataset.isLast === 'true';
    const isError = msg.isError !== undefined ? !!msg.isError : section.classList.contains('error');
    const isGenerating = msg.isGenerating !== undefined ? !!msg.isGenerating : !!this.isGenerating;
    const swipeIndex = msg.swipeIndex !== undefined ? msg.swipeIndex : parseInt(section.dataset.swipeId || '0', 10);
    const swipeTotal = msg.swipeTotal !== undefined ? msg.swipeTotal : parseInt(section.dataset.swipeTotal || '0', 10);
    const greetingIndex = msg.greetingIndex !== undefined ? msg.greetingIndex : 0;
    const greetingTotal = msg.greetingTotal !== undefined ? msg.greetingTotal : parseInt(section.dataset.greetingTotal || '0', 10);
    const messageIndex = parseInt(section.dataset.messageIndex || '-1', 10);
    const hasSwipes = isChar && swipeTotal > 1;
    const hasGreetings = isChar && messageIndex === 0 && greetingTotal > 1;
    const showRegen = ((!isChar && isLast) || isError) && !isGenerating && !isEditing;

    center.innerHTML = '';

    if (hasSwipes) {
      center.appendChild(this.renderer._createSwitcher(section.dataset.messageId, swipeIndex || 0, swipeTotal, 'swipe'));
    } else if (hasGreetings) {
      center.appendChild(this.renderer._createSwitcher(section.dataset.messageId, greetingIndex || 0, greetingTotal, 'greeting'));
    }

    if (isChar && isLast && !isGenerating && !isEditing) {
      const guided = document.createElement('div');
      guided.className = 'msg-guided-swipe-btn';
      guided.dataset.action = 'toggle-guided';
      guided.dataset.messageId = section.dataset.messageId;
      guided.title = 'Guided swipe';
      guided.innerHTML = ICON.guided;
      center.appendChild(guided);
    }

    if (isChar && isLast && isGenerating) {
      const stop = document.createElement('button');
      stop.className = 'stop-btn';
      stop.dataset.action = 'stop';
      stop.dataset.messageId = section.dataset.messageId;
      stop.title = 'Stop';
      stop.innerHTML = ICON.stop;
      center.appendChild(stop);
    }

    if (showRegen) {
      const regen = document.createElement('div');
      regen.className = 'msg-regenerate';
      if (hasSwipes || hasGreetings) regen.classList.add('icon-only');
      regen.dataset.action = 'regenerate';
      regen.dataset.messageId = section.dataset.messageId;
      regen.dataset.mode = 'magic';
      regen.innerHTML = ICON.regen;
      if (!hasSwipes && !hasGreetings) {
        const span = document.createElement('span');
        span.textContent = 'Regenerate';
        regen.appendChild(span);
      }
      center.appendChild(regen);
    }
  }

  setLastMessage(newLastId) {
    // Clear previous last — char or user
    const prevLast = document.querySelector('.message-section[data-is-last="true"]');
    if (prevLast) {
      delete prevLast.dataset.isLast;
      const center = prevLast.querySelector('.msg-center-controls');
      if (center) {
        center.querySelector('.msg-regenerate')?.remove();
        center.querySelector('.msg-guided-swipe-btn')?.remove();
        center.querySelector('.stop-btn')?.remove();
      }
    }
    if (!newLastId) return;
    const newLast = document.querySelector(`[data-message-id="${newLastId}"]`);
    if (!newLast) return;
    newLast.dataset.isLast = 'true';

    // For user messages: inject regen button directly into DOM
    if (newLast.classList.contains('user')) {
      let center = newLast.querySelector('.msg-center-controls');
      if (!center) {
        center = document.createElement('div');
        center.className = 'msg-center-controls';
        const footer = newLast.querySelector('.msg-footer');
        if (footer) footer.appendChild(center);
      }
      if (!center.querySelector('.msg-regenerate')) {
        const regen = document.createElement('div');
        regen.className = 'msg-regenerate';
        regen.dataset.action = 'regenerate';
        regen.dataset.messageId = newLastId;
        regen.dataset.mode = 'magic';
        regen.innerHTML = (typeof ICON !== 'undefined' && ICON.regen) ? ICON.regen : '<svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>';
        const span = document.createElement('span');
        span.textContent = 'Regenerate';
        regen.appendChild(span);
        center.appendChild(regen);
      }
    }
    // For char messages: renderer rebuilds controls on next render; flag is enough.
  }

  removeMessage(messageId) {
    this.flush();
    if (this._panelHost) {
      for (const [panelId, panel] of [...this._panelHost._panels.entries()]) {
        if (panel.messageId === messageId) this._panelHost.close(panelId);
      }
    }
    const el = document.querySelector(`[data-message-id="${messageId}"]`);
    if (el && this.renderer) {
      this.renderer.animateRemoveSection(el, () => this.virtualList.remove(messageId));
    } else {
      this.virtualList.remove(messageId);
    }
  }

  clearAll() {
    this.flush();
    this._showLoadingScreen();
    this._panelHost?.closeAll();
    this.virtualList.clear();
  }

  scrollToBottom() {
    this.virtualList.scrollToBottom();
    requestAnimationFrame(() => {
      this._sendToFlutter('onScrollToBottomVisibility', [false]);
    });
  }
  scrollToMessage(messageId, highlight = false) { this.virtualList.scrollToMessage(messageId, highlight); }

  setSearch(query, activeIndex) { this.renderer.setSearch(query, activeIndex); }

  setChatFont(fontFamily, fontDataUrl, fontSize, letterSpacing) {
    const root = document.documentElement;
    if (fontSize != null) {
      root.style.setProperty('--font-size', fontSize + 'px');
      root.style.setProperty('--chat-font-size', fontSize + 'px');
    }
    if (letterSpacing != null) {
      root.style.setProperty('--letter-spacing', letterSpacing + 'px');
      root.style.setProperty('--chat-letter-spacing', letterSpacing + 'px');
    }

    let fontFace = document.getElementById('custom-font-face');
    if (fontDataUrl) {
      if (!fontFace) {
        fontFace = document.createElement('style');
        fontFace.id = 'custom-font-face';
        document.head.appendChild(fontFace);
      }
      fontFace.textContent = `@font-face { font-family: '${fontFamily || 'CustomChatFont'}'; src: url('${fontDataUrl}'); font-display: swap; }`;
      root.style.setProperty('--font-family', `'${fontFamily || 'CustomChatFont'}', sans-serif`);
    } else {
      if (fontFace) fontFace.remove();
      if (fontFamily) root.style.setProperty('--font-family', fontFamily);
      else root.style.removeProperty('--font-family');
    }
  }

  _normalizeLayout(layout) {
    const raw = String(layout || '').trim().toLowerCase();
    return (raw === 'bubble' || raw === 'bubbles') ? 'bubble' : 'default';
  }

  applyTheme(themeJson) {
    const theme = JSON.parse(themeJson);
    const container = document.getElementById('chat-container') || document.body;

    for (const [key, value] of Object.entries(theme)) {
      if (key === 'chat-layout') {
        const layout = this._normalizeLayout(value);
        container.classList.remove('layout-bubble', 'layout-default');
        container.classList.add(`layout-${layout}`);
        document.querySelectorAll('.message-section').forEach(el => {
          el.classList.remove('layout-bubble', 'layout-default');
          el.classList.add(`layout-${layout}`);
        });
        continue;
      }
      document.documentElement.style.setProperty(`--${key}`, value);
    }
  }

  setBottomPadding(px) {
    const container = document.getElementById('chat-container') || document.body;
    container.style.paddingBottom = px + 'px';
    requestAnimationFrame(() => {
      const distanceFromBottom =
        container.scrollHeight - container.scrollTop - container.clientHeight;
      this._sendToFlutter('onScrollToBottomVisibility', [distanceFromBottom > 240]);
    });
  }

  setTopPadding(px) {
    const container = document.getElementById('chat-container') || document.body;
    container.style.paddingTop = px + 'px';
  }

  setHeaderOverlay(topPx, heightPx) {
    const el = document.getElementById('header-blur-overlay');
    if (!el) return;
    if (heightPx > 0) {
      document.documentElement.style.setProperty('--header-overlay-top', topPx + 'px');
      document.documentElement.style.setProperty('--header-overlay-height', heightPx + 'px');
      el.style.display = 'block';
    } else {
      el.style.display = 'none';
    }
  }

  setInputOverlay(heightPx) {
    const el = document.getElementById('input-blur-overlay');
    if (!el) return;
    if (heightPx > 0) {
      document.documentElement.style.setProperty('--input-overlay-height', heightPx + 'px');
      el.style.display = 'block';
    } else {
      el.style.display = 'none';
    }
  }

  applyLayout(layout) {
    const normalized = this._normalizeLayout(layout);
    const container = document.getElementById('chat-container') || document.body;
    container.classList.remove('layout-bubble', 'layout-default');
    container.classList.add(`layout-${normalized}`);
    document.querySelectorAll('.message-section').forEach(el => {
      el.classList.remove('layout-bubble', 'layout-default');
      el.classList.add(`layout-${normalized}`);
    });
  }

  setMessageSettings(json) {
    let s;
    try { s = typeof json === 'string' ? JSON.parse(json) : (json || {}); }
    catch (_) { s = {}; }
    this.batterySaver = !!s.batterySaver;
    this.disableSwipeRegeneration = !!s.disableSwipeRegeneration;
    const container = document.getElementById('chat-container') || document.body;
    container.classList.toggle('battery-saver', this.batterySaver);
    container.classList.toggle('hide-message-id', !!s.hideMessageId);
    container.classList.toggle('hide-gen-time', !!s.hideGenerationTime);
    container.classList.toggle('hide-token-count', !!s.hideTokenCount);
  }

  /* ---------- Inline edit (toggle into .msg-body) ---------- */
  startEdit(messageId) {
    this._editController.startEdit(messageId, (pos) => {
      if (pos !== undefined) this.virtualList.container.scrollTop = pos;
      return this.virtualList.container.scrollTop;
    });
  }

  stopEdit(messageId) {
    this._editController.stopEdit(messageId);
  }

  setBackgroundImage(url, blur) {
    // Background is handled by Flutter layer behind the transparent WebView.
  }

  setBackgroundNoise(opacity, intensity) {
    let noise = document.getElementById('bg-noise-layer');
    if (!noise) {
      noise = document.createElement('div');
      noise.id = 'bg-noise-layer';
      const bg = document.getElementById('bg-layer');
      if (bg && bg.nextSibling) {
        document.body.insertBefore(noise, bg.nextSibling);
      } else {
        document.body.insertBefore(noise, document.body.firstChild);
      }
    }
    const op = Math.max(0, Math.min(1, opacity || 0));
    if (op <= 0) {
      noise.style.display = 'none';
      noise.style.backgroundImage = '';
      return;
    }
    const i = Math.max(0, Math.min(2, intensity == null ? 1 : intensity));
    noise.style.display = 'block';
    noise.style.opacity = op;
    noise.style.backgroundImage = `url("${this._noiseTile(i)}")`;
    noise.style.backgroundSize = '128px 128px';
  }

  _noiseTile(intensity) {
    if (!this._noiseCache) this._noiseCache = new Map();
    const key = intensity.toFixed(2);
    const hit = this._noiseCache.get(key);
    if (hit) return hit;
    const size = 128;
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = size;
    const ctx = canvas.getContext('2d');
    const img = ctx.createImageData(size, size);
    const data = img.data;
    for (let p = 0; p < data.length; p += 4) {
      const a = Math.min(1, Math.random() * intensity);
      data[p] = 255;
      data[p + 1] = 255;
      data[p + 2] = 255;
      data[p + 3] = Math.round(a * 255);
    }
    ctx.putImageData(img, 0, 0);
    const url = canvas.toDataURL('image/png');
    this._noiseCache.set(key, url);
    return url;
  }

  setPerformanceMode(enabled) {
    const container = document.getElementById('chat-container') || document.body;
    container.classList.toggle('perf-mode', !!enabled);
    /* Mirror .native-lite onto each message for class-scoped styles */
    document.querySelectorAll('.message-section').forEach(el => {
      el.classList.toggle('native-lite', !!enabled);
    });
  }

  animateGenTime(messageId, targetTime) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return;
    const badge = section.querySelector('.gen-time-badge');
    if (!badge) return;

    const match = targetTime.match(/([\d.]+)(.*)/);
    if (!match) { badge.textContent = targetTime; return; }
    const target = parseFloat(match[1]);
    const suffix = match[2] || '';
    if (isNaN(target)) { badge.textContent = targetTime; return; }

    const start = performance.now();
    const duration = 600;
    const tick = (now) => {
      const progress = Math.min((now - start) / duration, 1);
      const eased = 1 - Math.pow(1 - progress, 3);
      const current = (target * eased).toFixed(target % 1 !== 0 ? 1 : 0);
      badge.textContent = `${current}${suffix}`;
      if (progress < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  setSelectionMode(enabled) { this._selectionManager.setSelectionMode(enabled); }

  _setupImageClickForward() {
    this.virtualList.container.addEventListener('image-click', (e) => {
      this._sendToFlutter('onImageClick', [e.detail.src]);
    });
  }

  debugFormatter(text) {
    const formatted = this.renderer.formatter.format(text, false);
    document.title = 'DBG:' + formatted.substring(0, 200);
  }

  // ── Interactive panels (sandboxed iframe islands) ──────────────────────

  /**
   * Persistent, sandboxed iframe islands rendered under assistant messages.
   * Unlike `runSandboxedScript`, these stay alive for the entire lifetime
   * of the message so the user can interact with the panel (click, type,
   * fetch via glaze.* etc.) and call back into Dart through the standard
   * `glaze:request` postMessage relay.
   *
   * Security model:
   *   - iframe uses `sandbox="allow-scripts"` WITHOUT `allow-same-origin`
   *     → null origin blocks `window.parent` and `window.flutter_inappwebview`
   *   - All `glaze.*` calls go through the same parent reлай as
   *     `runSandboxedScript`, so cross-origin spoofing is impossible:
   *     parent only answers if `e.source === iframe.contentWindow`
   *   - Iframe HTML is constructed in two parts: a trusted SDK bootstrap
   *     (`window.__glazeSdkSource`) + caller-supplied HTML in a sandbox
   *     container. The user HTML is **not** injected via `innerHTML` on the
   *     parent side — only the iframe sees it.
   *   - ResizeObserver reports height back to Dart so the virtual list
   *     can keep the cached section height in sync.
   */
  initPanelHost() {
    if (this._panelHost) return;
    this._panelHost = new PanelHost(this);
  }

  openPanel(messageId, html, optionsJson) {
    this.initPanelHost();
    return this._panelHost.open(messageId, html, optionsJson || '{}');
  }

  closePanel(panelId) {
    this._panelHost?.close(panelId);
  }

  postToPanel(panelId, method, paramsJson) {
    return this._panelHost?.postToPanel(panelId, method, paramsJson || '{}');
  }

  // ── Ext Blocks panel ──────────────────────────────────────────────────────

  /**
   * Called from Flutter to show/update the inline ext-blocks panel under a
   * message. If `blocks` is empty the panel is removed.
   * @param {string} json  - JSON string: { messageId: string, blocks: Array }
   */
  showExtBlocksPanel(json) {
    let data;
    try { data = JSON.parse(json); } catch (_) { return; }
    const { messageId, blocks, canRunAll } = data;
    if (!messageId) return;

    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return;

    if (!blocks || blocks.length === 0) {
      section.querySelector('.ext-blocks-panel')?.remove();
      return;
    }

    let panel = section.querySelector('.ext-blocks-panel');
    if (!panel) {
      panel = document.createElement('div');
      panel.className = 'ext-blocks-panel';
      const content = section.querySelector('.msg-content') || section;
      content.appendChild(panel);
    }

    panel.innerHTML = '';

    if (canRunAll) {
      const toolbar = document.createElement('div');
      toolbar.className = 'ext-blocks-toolbar';
      const runAllBtn = document.createElement('button');
      runAllBtn.type = 'button';
      runAllBtn.className = 'ext-block-btn ext-blocks-run-all';
      runAllBtn.dataset.action = 'ext-blocks-run-all';
      runAllBtn.dataset.messageId = messageId;
      runAllBtn.textContent = '▶ Запустить блоки';
      toolbar.appendChild(runAllBtn);
      panel.appendChild(toolbar);
    }

    for (const block of blocks) {
      const item = document.createElement('div');
      item.className = `ext-block-item ${block.status || 'done'}`;
      item.dataset.blockId = block.blockId;

      const header = document.createElement('div');
      header.className = 'ext-block-header';

      const caret = document.createElement('span');
      caret.className = 'ext-block-caret';
      caret.textContent = '▸';
      header.appendChild(caret);

      const name = document.createElement('span');
      name.className = 'ext-block-name';
      name.textContent = block.blockName || block.blockId || '—';
      header.appendChild(name);

      const statusEl = document.createElement('span');
      statusEl.className = 'ext-block-status';
      statusEl.textContent = this._extBlockStatusLabel(block.status);
      header.appendChild(statusEl);

      // Buttons — no per-btnGroup listener so the click bubbles up to the
      // document-level delegation in `_interaction.handleClick` (which
      // dispatches via `_actionMap`). The header's own click listener has
      // a `closest('.ext-block-btn')` guard so it won't toggle collapse.
      const btnGroup = document.createElement('span');
      btnGroup.className = 'ext-block-actions';

      // Edit button — always present.
      const editBtn = document.createElement('button');
      editBtn.type = 'button';
      editBtn.className = 'ext-block-btn ext-block-btn-icon';
      editBtn.dataset.action = 'ext-block-edit';
      editBtn.dataset.blockId = block.blockId;
      editBtn.dataset.messageId = messageId;
      editBtn.title = 'Редактировать';
      editBtn.textContent = '✎';
      btnGroup.appendChild(editBtn);

      // Delete button — always present.
      const deleteBtn = document.createElement('button');
      deleteBtn.type = 'button';
      deleteBtn.className = 'ext-block-btn ext-block-btn-icon ext-block-btn-danger';
      deleteBtn.dataset.action = 'ext-block-delete';
      deleteBtn.dataset.blockId = block.blockId;
      deleteBtn.dataset.messageId = messageId;
      deleteBtn.title = 'Удалить';
      deleteBtn.textContent = '✕';
      btnGroup.appendChild(deleteBtn);

      if (block.status === 'running') {
        const stopBtn = document.createElement('button');
        stopBtn.type = 'button';
        stopBtn.className = 'ext-block-btn';
        stopBtn.dataset.action = 'ext-block-stop';
        stopBtn.dataset.blockId = block.blockId;
        stopBtn.dataset.messageId = messageId;
        stopBtn.textContent = '■ Стоп';
        btnGroup.appendChild(stopBtn);
      } else if (block.status === 'pending') {
        const startBtn = document.createElement('button');
        startBtn.type = 'button';
        startBtn.className = 'ext-block-btn';
        startBtn.dataset.action = 'ext-block-regen';
        startBtn.dataset.blockId = block.blockId;
        startBtn.dataset.messageId = messageId;
        startBtn.textContent = '▶ Запустить';
        btnGroup.appendChild(startBtn);
      } else {
        const canRegenImage = block.type === 'imageGen' && block.content && (
          /\[IMG:RESULT:/.test(block.content) ||
          /\[IMG:GEN:/.test(block.content) ||
          /data-iig-instruction/i.test(block.content)
        );
        if (canRegenImage) {
          const imgRegenBtn = document.createElement('button');
          imgRegenBtn.type = 'button';
          imgRegenBtn.className = 'ext-block-btn';
          imgRegenBtn.dataset.action = 'ext-block-regen-image';
          imgRegenBtn.dataset.blockId = block.blockId;
          imgRegenBtn.dataset.messageId = messageId;
          imgRegenBtn.textContent = '↺ Картинка';
          btnGroup.appendChild(imgRegenBtn);
        }
        const regenBtn = document.createElement('button');
        regenBtn.type = 'button';
        regenBtn.className = 'ext-block-btn';
        regenBtn.dataset.action = 'ext-block-regen';
        regenBtn.dataset.blockId = block.blockId;
        regenBtn.dataset.messageId = messageId;
        regenBtn.textContent = '↺ Перегенерировать';
        btnGroup.appendChild(regenBtn);
      }

      header.appendChild(btnGroup);
      header.addEventListener('click', (e) => {
        if (e.target.closest('.ext-block-btn')) return;
        item.classList.toggle('collapsed');
      });
      item.appendChild(header);

      // Content body (collapsible).
      const body = document.createElement('div');
      body.className = 'ext-block-body';
      this._fillExtBlockBody(body, block);
      item.appendChild(body);

      panel.appendChild(item);
    }
  }

  /**
   * Lightweight streaming update — only replaces one block's body + status.
   * Returns false if the panel or block row is not on screen yet.
   */
  patchExtBlockContent(json) {
    let data;
    try { data = JSON.parse(json); } catch (_) { return false; }
    const { messageId, blockId, content, status } = data;
    if (!messageId || !blockId) return false;

    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return false;
    const panel = section.querySelector('.ext-blocks-panel');
    if (!panel) return false;

    const item = panel.querySelector(`.ext-block-item[data-block-id="${blockId}"]`);
    if (!item) return false;

    item.className = `ext-block-item ${status || 'running'}`;
    const statusEl = item.querySelector('.ext-block-status');
    if (statusEl) statusEl.textContent = this._extBlockStatusLabel(status);

    const body = item.querySelector('.ext-block-body');
    if (!body) return false;
    body.innerHTML = '';
    this._fillExtBlockBody(body, { content, status });
    item.classList.remove('collapsed');
    return true;
  }

  _escapeAttr(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/"/g, '&quot;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  _extBlockImageSrc(payload) {
    let path = payload || '';
    const pipeIdx = path.indexOf('|');
    if (pipeIdx !== -1) path = path.substring(0, pipeIdx);
    if (path.startsWith('data:') || path.startsWith('file://') || path.startsWith('http://') || path.startsWith('https://')) return path;
    const normalized = path.replace(/\\/g, '/');
    return normalized.startsWith('/') ? `file://${normalized}` : `file:///${normalized}`;
  }

  _renderExtBlockImageHtml(payload) {
    const src = this._escapeAttr(this._extBlockImageSrc(payload));
    // loading="eager" (see bridge/chat_bridge_controller.js): lazy ext-block
    // images blink and collapse on iOS while the keyboard resizes the viewport.
    return `<span class="ext-block-image-wrapper img-result-wrapper"><img src="${src}" class="ext-block-image" loading="eager" decoding="sync" data-action="image-click" data-src="${src}"><button class="img-download-btn" data-action="img-download" data-src="${src}" title="Save image">⤓</button></span>`;
  }

  _fillExtBlockBody(body, block) {
    const hasContent = block.content && block.content.trim().length > 0;
    if (!hasContent && block.status !== 'pending') {
      const empty = document.createElement('div');
      empty.className = 'ext-block-content empty';
      empty.textContent = '(пусто)';
      body.appendChild(empty);
      return;
    }
    if (!hasContent) return;

    const imgResultRegex = /\[IMG:RESULT:([^\]]+)\]/;
    const hasImgResult = imgResultRegex.test(block.content);
    const hasHtmlMarkup = /<[a-z][\s\S]*>/i.test(block.content);

    if (hasImgResult && hasHtmlMarkup) {
      let html = block.content.replace(
        /\[IMG:RESULT:([^\]]+)\]/g,
        (match, payload) => this._renderExtBlockImageHtml(payload),
      );
      const htmlEl = document.createElement('div');
      htmlEl.className = 'ext-block-content';
      htmlEl.innerHTML = html;
      body.appendChild(htmlEl);
    } else if (hasImgResult) {
      const imgMatch = block.content.match(imgResultRegex);
      const wrapper = document.createElement('span');
      wrapper.innerHTML = this._renderExtBlockImageHtml(imgMatch[1]);
      body.appendChild(wrapper.firstElementChild);
    } else {
      const html = document.createElement('div');
      html.className = 'ext-block-content';
      html.innerHTML = block.content;
      body.appendChild(html);
    }
  }

  /**
   * Updates the panel if it's currently visible for this message.
   * Has the same signature as showExtBlocksPanel — just delegates.
   */
  updateExtBlocksPanel(json) {
    this.showExtBlocksPanel(json);
  }

  hideExtBlocksPanel(messageId) {
    if (!messageId) return;
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    section?.querySelector('.ext-blocks-panel')?.remove();
  }

  _extBlockStatusLabel(status) {
    switch (status) {
      case 'pending': return 'ожидает';
      case 'running': return 'генерация…';
      case 'error': return 'ошибка';
      case 'stopped': return 'остановлен';
      case 'done': return 'готово';
      default: return status || '—';
    }
  }

  /**
   * Called from Flutter to push a minimal updateMessageMeta call.
   * `json` is the same shape as a message object (at least { id, blockStatus }).
   */
  updateMessageMeta(json) {
    let msg;
    try { msg = JSON.parse(json); } catch (_) { return; }
    if (!msg.id) return;
    const section = document.querySelector(`[data-message-id="${msg.id}"]`);
    if (!section) return;
    this.renderer.updateMessageMeta(section, msg);
  }

  /**
   * Runs user-provided JS in a sandboxed iframe and returns a Promise<string>.
   *
   * Security model:
   *   - iframe uses sandbox="allow-scripts" WITHOUT allow-same-origin
   *   - This gives the iframe a null origin, blocking access to window.parent
   *     and window.flutter_inappwebview (cross-origin barrier)
   *   - Context is passed via srcdoc (not postMessage) to avoid the timing
   *     issue of the iframe not being ready yet
   *   - Only text data is passed: messages, character fields, previousOutput
   *   - API keys are never in JS context (they live in Dart/SQLite)
   *   - Source-check: e.source !== iframe.contentWindow guards against spoofing
   *   - Timeout: 55 s (Dart side gives 60 s — races without leaking)
   *
   * @param {string} script - User JS. Must return a string (via `return`).
   * @param {string} contextJson - JSON string with messages/character/previousOutput.
   * @returns {Promise<string>}
   */
  runSandboxedScript(script, contextJson) {
    return new Promise((resolve, reject) => {
      let iframe = null;

      const cleanup = () => {
        if (iframe) {
          iframe.remove();
          iframe = null;
        }
      };

      const timeoutId = setTimeout(() => {
        cleanup();
        reject(new Error('JS runner timeout (55s)'));
      }, 55000);

      // Escape script and contextJson for safe embedding in srcdoc attribute.
      // We use a JSON string as the JS literal so that any quotes/backslashes
      // inside the user script are properly escaped.
      const escapedScript = JSON.stringify(script);
      const escapedContext = contextJson;
      const sdkSource = JSON.stringify(window.__glazeSdkSource || '');

      const sandboxHtml = `<!DOCTYPE html><html><body><script>
(function() {
  var context;
  try { context = ${escapedContext}; } catch(e) { context = {}; }
  window.__glazeContext = context;
  var glazeSdkSource = ${sdkSource};
  if (glazeSdkSource) {
    (new Function(glazeSdkSource))();
  }
  var userScript = ${escapedScript};
  (new Function('context', '"use strict"; return (async function() { ' + userScript + ' })();'))(context)
    .then(function(r) {
      parent.postMessage({ ok: true, result: String(r !== undefined && r !== null ? r : '') }, '*');
    })
    .catch(function(e) {
      parent.postMessage({ ok: false, error: String(e && e.message ? e.message : e) }, '*');
    });
})();
<\/script></body></html>`;

      const handler = (e) => {
        if (!iframe || e.source !== iframe.contentWindow) return;
        if (e.data && e.data.type) return;
        clearTimeout(timeoutId);
        window.removeEventListener('message', handler);
        cleanup();
        if (e.data && e.data.ok) {
          resolve(e.data.result);
        } else {
          reject(new Error(e.data && e.data.error ? e.data.error : 'JS runner error'));
        }
      };

      window.addEventListener('message', handler);

      iframe = document.createElement('iframe');
      iframe.sandbox = 'allow-scripts';
      iframe.style.display = 'none';
      iframe.srcdoc = sandboxHtml;
      document.body.appendChild(iframe);
    });
  }
}

class PanelHost {
  constructor(bridge) {
    this.bridge = bridge;
    this._panels = new Map();
    this._nextId = 1;
    this._setupListener();
  }

  _setupListener() {
    this._onMessage = (e) => {
      if (!e.source) return;
      for (const [panelId, panel] of this._panels) {
        if (e.source !== panel.iframe.contentWindow) continue;
        const data = e.data || {};
        if (data.type === 'glaze:panel-ready') {
          panel.ready = true;
          this.bridge._sendToFlutter('onPanelEvent', [
            JSON.stringify({ panelId, event: 'ready' }),
          ]);
          return;
        }
        if (data.type === 'glaze:panel-resize') {
          const height = Math.max(0, Math.round(Number(data.height) || 0));
          panel.lastHeight = height;
          this.bridge._sendToFlutter('onPanelResize', [
            JSON.stringify({ panelId, height }),
          ]);
          return;
        }
        if (data.type === 'glaze:panel-action') {
          this.bridge._sendToFlutter('onPanelEvent', [
            JSON.stringify({
              panelId,
              event: data.event || 'action',
              payload: data.payload || {},
            }),
          ]);
          return;
        }
        if (data.type === 'glaze:panel-close') {
          this.close(panelId);
          return;
        }
        if (data.type === 'glaze:request') {
          this._relayGlazeRequest(panel, data);
          return;
        }
      }
    };
    window.addEventListener('message', this._onMessage);
  }

  async _relayGlazeRequest(panel, data) {
    try {
      const result = await this.bridge._callGlazeBridge({
        id: data.id,
        method: data.method,
        params: data.params || {},
        context: { ...(data.context || {}), panelId: panel.panelId, messageId: panel.messageId },
      });
      panel.iframe.contentWindow.postMessage(
        { type: 'glaze:response', id: data.id, ok: true, result },
        '*',
      );
    } catch (error) {
      panel.iframe.contentWindow.postMessage(
        {
          type: 'glaze:response',
          id: data.id,
          ok: false,
          error: {
            code: error && error.code,
            message: String(error && error.message ? error.message : error),
          },
        },
        '*',
      );
    }
  }

  open(messageId, html, optionsJson) {
    if (!messageId) return null;
    let options = {};
    try { options = JSON.parse(optionsJson || '{}'); } catch (_) { options = {}; }
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return null;

    const panelId = `panel_${this._nextId++}_${Date.now()}`;
    const host = document.createElement('div');
    host.className = 'interactive-panel';
    host.dataset.panelId = panelId;
    host.dataset.messageId = messageId;

    const placeholderHeight = Math.max(
      60,
      Math.min(2000, Number(options.minHeight) || 0),
    );
    host.style.minHeight = placeholderHeight + 'px';

    const content = section.querySelector('.msg-content') || section;
    content.appendChild(host);

    const iframe = document.createElement('iframe');
    iframe.className = 'interactive-panel-frame';
    iframe.sandbox = 'allow-scripts';
    iframe.setAttribute('aria-label', options.title || 'Interactive panel');
    iframe.style.border = '0';
    iframe.style.width = '100%';
    iframe.style.height = placeholderHeight + 'px';
    iframe.style.background = 'transparent';
    iframe.srcdoc = this._buildSrcdoc(html, options, panelId, messageId);

    host.appendChild(iframe);

    const panel = {
      panelId,
      messageId,
      host,
      iframe,
      ready: false,
      lastHeight: placeholderHeight,
      _resizeObserver: null,
    };
    this._panels.set(panelId, panel);

    if (typeof ResizeObserver !== 'undefined') {
      panel._resizeObserver = new ResizeObserver((entries) => {
        for (const entry of entries) {
          const rect = entry.contentRect;
          const height = Math.round(rect.height);
          if (height > 0 && Math.abs(height - panel.lastHeight) > 2) {
            panel.lastHeight = height;
            this.bridge._sendToFlutter('onPanelResize', [
              JSON.stringify({ panelId, height }),
            ]);
          }
        }
      });
      panel._resizeObserver.observe(host);
    }

    return panelId;
  }

  _buildSrcdoc(html, options, panelId, messageId) {
    const sdk = JSON.stringify(window.__glazeSdkSource || '');
    const userHtml = String(html == null ? '' : html);
    const context = JSON.stringify({
      messageId,
      panelId,
      title: options.title || '',
    });
    const bootstrap = `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
<div id="glaze-panel-root">${userHtml}</div>
<script>
(function() {
  window.__glazeContext = ${context};
  var sdk = ${sdk};
  if (sdk) {
    try { (new Function(sdk))(); } catch (e) { console.error('[glaze-panel] sdk load failed', e); }
  }
  function post(type, extra) {
    parent.postMessage(Object.assign({ type: 'glaze:' + type }, extra || {}), '*');
  }
  window.glazePanel = Object.freeze({
    ready: function() { post('panel-ready'); },
    close: function() { post('panel-close'); },
    reportHeight: function(h) { post('panel-resize', { height: Number(h) || 0 }); },
    sendAction: function(event, payload) { post('panel-action', { event: event || 'action', payload: payload || {} }); },
  });
  parent.postMessage({ type: 'glaze:panel-ready' }, '*');
})();
<\/script></body></html>`;
    return bootstrap;
  }

  close(panelId) {
    const panel = this._panels.get(panelId);
    if (!panel) return;
    if (panel._resizeObserver) {
      panel._resizeObserver.disconnect();
      panel._resizeObserver = null;
    }
    if (panel.host && panel.host.parentNode) {
      panel.host.parentNode.removeChild(panel.host);
    }
    this._panels.delete(panelId);
  }

  closeAll() {
    for (const panelId of [...this._panels.keys()]) {
      this.close(panelId);
    }
  }

  postToPanel(panelId, method, paramsJson) {
    const panel = this._panels.get(panelId);
    if (!panel || !panel.iframe || !panel.iframe.contentWindow) return false;
    let params = {};
    try { params = JSON.parse(paramsJson || '{}'); } catch (_) { params = {}; }
    panel.iframe.contentWindow.postMessage({
      type: 'glaze:panel-push',
      method,
      params,
    }, '*');
    return true;
  }
}
