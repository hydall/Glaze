/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

export class SwipeGestureHandler {
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
    let axisLocked = false;
    const self = this;

    // Minimum net finger travel before we commit the gesture to an axis. Until
    // this is reached we stay hands-off so the WebView's native vertical scroll
    // can engage — critical on iOS, where calling preventDefault() on an early
    // touchmove cancels scrolling for the rest of the gesture.
    const AXIS_LOCK_SLOP = 12;

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
      axisLocked = false;
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

      // Decide the gesture axis once, only after a deliberate amount of travel.
      // Ties and vertical-dominant drags become scrolls (native), so grabbing a
      // message that has swipe variations no longer traps a vertical scroll in
      // the horizontal swipe path.
      if (!axisLocked) {
        const absX = Math.abs(dx);
        const absY = Math.abs(dy);
        if (absX < AXIS_LOCK_SLOP && absY < AXIS_LOCK_SLOP) return;
        if (absY >= absX) {
          scrollingVertical = true;
          activeBody.style.transform = '';
          return;
        }
        axisLocked = true;
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
