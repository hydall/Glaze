/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

/* Everything inside `.msg-content-stack` that belongs to the variation being
 * switched, in DOM order. The reasoning box and the in-game clock are siblings
 * of the body, not children of it, so a transform applied to `.msg-body` alone
 * leaves them pinned and the message visibly tears in half mid-swipe. The
 * footer is deliberately absent: its switcher and actions button stay put so
 * they remain usable while the content moves. */
const SWIPE_TARGET_SELECTORS = ['.msg-reasoning', '.msg-game-time', '.msg-body'];

function swipeTargets(section) {
  if (!section) return [];
  const targets = [];
  for (const selector of SWIPE_TARGET_SELECTORS) {
    const el = section.querySelector(selector);
    if (el) targets.push(el);
  }
  return targets;
}

/* Apply the same inline styles to every element the gesture is moving. */
function styleAll(targets, styles) {
  for (const el of targets) Object.assign(el.style, styles);
}

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
    let activeTargets = [];
    let activeSection = null;
    let scrollingVertical = false;
    let axisLocked = false;
    const self = this;

    // Minimum net finger travel before we commit the gesture to an axis. Until
    // this is reached we stay hands-off so the WebView's native vertical scroll
    // can engage — critical on iOS, where calling preventDefault() on an early
    // touchmove cancels scrolling for the rest of the gesture.
    const AXIS_LOCK_SLOP = 12;

    const reset = (targets) => {
      styleAll(targets, { transition: 'transform 0.3s ease', transform: '' });
      setTimeout(() => styleAll(targets, { transition: '' }), 300);
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
      // A touch that starts on the reasoning box drags the whole variation,
      // not just the reply underneath it.
      const targets = swipeTargets(section);
      if (targets.length === 0) return;
      const t = e.touches ? e.touches[0] : e;
      startX = t.clientX;
      startY = t.clientY;
      scrollingVertical = false;
      axisLocked = false;
      activeSection = section;
      activeTargets = targets;
      styleAll(targets, { transition: 'none' });
    };

    const onMove = (e) => {
      if (activeTargets.length === 0 || !activeSection) return;
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
          styleAll(activeTargets, { transform: '' });
          return;
        }
        axisLocked = true;
      }

      const swipeId = parseInt(activeSection.dataset.swipeId || '0', 10);
      const swipeTotal = parseInt(activeSection.dataset.swipeTotal || '1', 10);
      const isLast = activeSection.dataset.isLast === 'true';
      const greetingTotal = parseInt(activeSection.dataset.greetingTotal || '0', 10);
      const greetingId = parseInt(activeSection.dataset.greetingId || '0', 10);
      const isFirstMsg = activeSection.dataset.messageIndex === '0';
      const canSwitchGreeting = isFirstMsg && greetingTotal > 1;

      const blockLastRegen = isLast && self._disableRegen();
      // Greetings navigate their own list and no longer wrap, so they get the
      // same hard edges as the swipes: nothing to switch to → no drag.
      if (canSwitchGreeting) {
        if (dx < 0 && greetingId >= greetingTotal - 1) return;
        if (dx > 0 && greetingId <= 0) return;
      } else {
        if (dx < 0 && (blockLastRegen || !isLast) && swipeId >= swipeTotal - 1) return;
        if (dx > 0 && swipeId <= 0) return;
      }

      if (e.cancelable) e.preventDefault();
      styleAll(activeTargets, { transform: `translateX(${dx}px)` });
    };

    const onEnd = (e) => {
      if (activeTargets.length === 0 || !activeSection) return;
      const targets = activeTargets;
      const section = activeSection;
      activeTargets = [];
      activeSection = null;
      if (scrollingVertical) {
        styleAll(targets, { transform: '', transition: '' });
        return;
      }

      const t = e.changedTouches ? e.changedTouches[0] : e;
      const dx = t.clientX - startX;

      const swipeId = parseInt(section.dataset.swipeId || '0', 10);
      const swipeTotal = parseInt(section.dataset.swipeTotal || '1', 10);
      const isLast = section.dataset.isLast === 'true';
      const greetingTotal = parseInt(section.dataset.greetingTotal || '0', 10);
      const greetingId = parseInt(section.dataset.greetingId || '0', 10);
      const isFirstMsg = section.dataset.messageIndex === '0';
      const canSwitchGreeting = isFirstMsg && greetingTotal > 1;
      const msgId = section.dataset.messageId;

      if (canSwitchGreeting) {
        if (dx < -THRESHOLD && greetingId < greetingTotal - 1) {
          self.animateVariantSwap(msgId, 'next', () => self._sendToFlutter('onChangeGreeting', [msgId, 1]), dx);
        } else if (dx > THRESHOLD && greetingId > 0) {
          self.animateVariantSwap(msgId, 'prev', () => self._sendToFlutter('onChangeGreeting', [msgId, -1]), dx);
        } else {
          reset(targets);
        }
        return;
      }

      if (dx < -THRESHOLD) {
        if (swipeId < swipeTotal - 1) {
          self.animateVariantSwap(msgId, 'next', () => self._sendToFlutter('onSwipe', [JSON.stringify({ id: msgId, direction: 'right' })]), dx);
        } else if (isLast && !self._disableRegen()) {
          styleAll(targets, { transition: 'transform 0.1s', transform: 'translateX(-20px)' });
          setTimeout(() => {
            styleAll(targets, { transform: '', transition: '' });
            self._sendToFlutter('onRegenerate', [msgId, 'new_variant']);
          }, 100);
        } else {
          reset(targets);
        }
      } else if (dx > THRESHOLD) {
        if (swipeId > 0) {
          self.animateVariantSwap(msgId, 'prev', () => self._sendToFlutter('onSwipe', [JSON.stringify({ id: msgId, direction: 'left' })]), dx);
        } else {
          reset(targets);
        }
      } else {
        reset(targets);
      }
    };

    const container = this._getContainer();
    container.addEventListener('touchstart', onStart, { passive: true });
    container.addEventListener('touchmove', onMove, { passive: false });
    container.addEventListener('touchend', onEnd);
    container.addEventListener('touchcancel', onEnd);
  }

  /* Slide + fade animation for variant switching.  Used by both the prev/next
   * buttons and the touch-swipe gesture.  Every element of the variation moves
   * together — reasoning box, in-game clock and reply body — and each has its
   * own height locked through the swap and then animated to its new natural
   * height, so the page doesn't jump when variants differ in length (including
   * when one variant reasoned and the next did not).
   *
   * `currentX` lets the touch path pass the drag's current offset so the exit
   * continues the gesture outward instead of snapping back toward center. */
  animateVariantSwap(messageId, dir, after, currentX = 0) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    const targets = swipeTargets(section);
    if (targets.length === 0) { after(); return; }

    // Tapping the arrow again before the previous swap settled used to leave
    // two runs fighting over the same inline styles: the older run's cleanup
    // timer would fire mid-flight and strip the newer run's transition, or the
    // newer run would measure a height that was still locked — either way the
    // bubble could stay faded out or keep a frozen height. Tear the previous
    // run down (timers, observer, inline styles) before starting a new one.
    //
    // The run is owned by the section rather than by the body: the set of
    // moving elements changes between variations (a reasoning box appears or
    // goes away), so the body is not a stable place to find the run that has
    // to be aborted.
    if (section._variantSwap) {
      section._variantSwap.abort();
      section._variantSwap = null;
    }

    // dir: 'next' → exit to left, enter from right.  'prev' → mirror.
    const sign = dir === 'next' ? -1 : (dir === 'prev' ? 1 : 0);
    // Exit: continue past current drag position; click case uses a small hint.
    const outX = currentX !== 0 ? currentX + sign * 40 : sign * 28;
    // Entrance always slides in from a fixed offset on the opposite side.
    const inX = sign * -28;

    // Lock each element's current height so the (async) content swap doesn't
    // reflow the page. Measured with any leftover lock cleared, so a swap that
    // starts on top of an aborted one still reads the real content height.
    const startHeights = targets.map((el) => el.offsetHeight);
    targets.forEach((el, i) => {
      el.style.height = `${startHeights[i]}px`;
      el.style.overflow = 'hidden';
    });
    styleAll(targets, {
      transition: 'opacity 0.12s ease, transform 0.12s ease',
      opacity: '0',
      ...(outX ? { transform: `translateX(${outX}px)` } : {}),
    });

    // Everything this run schedules, so a superseding run can tear it down.
    const run = {
      timers: [],
      mo: null,
      done: false,
      sent: false,
      send: () => {
        if (run.sent) return;
        run.sent = true;
        after();
      },
      abort: () => {
        run.done = true;
        run.timers.forEach(clearTimeout);
        run.timers.length = 0;
        if (run.mo) run.mo.disconnect();
        // The switch request itself is not the animation's to drop: a second
        // tap that lands inside the 130 ms exit window must still reach Dart,
        // in order, or one of the two steps is silently swallowed.
        run.send();
        // Hand the elements back in a neutral state; the new run re-locks
        // whichever ones the incoming variation has.
        styleAll(targets, {
          transition: '',
          transform: '',
          height: '',
          overflow: '',
          opacity: '1',
        });
      },
    };
    section._variantSwap = run;

    const schedule = (fn, ms) => {
      const t = setTimeout(() => {
        run.timers = run.timers.filter(id => id !== t);
        fn();
      }, ms);
      run.timers.push(t);
      return t;
    };

    schedule(() => {
      const finish = () => {
        if (run.done) return;
        run.done = true;
        run.mo.disconnect();
        run.timers.forEach(clearTimeout);
        run.timers.length = 0;

        // Measure each element's new natural height, then put the lock back so
        // the animation has something to transition from. Measuring all of
        // them before restoring any avoids a second reflow per element.
        const targetHeights = targets.map((el) => {
          el.style.height = 'auto';
          return el.offsetHeight;
        });
        targets.forEach((el, i) => {
          el.style.height = `${startHeights[i]}px`;
        });

        requestAnimationFrame(() => {
          // A newer swap took over between the frame request and this callback.
          if (section._variantSwap !== run) return;
          targets.forEach((el, i) => {
            el.style.transition = 'opacity 0.22s ease, transform 0.22s ease, height 0.22s ease';
            el.style.opacity = '1';
            el.style.transform = '';
            el.style.height = `${targetHeights[i]}px`;
          });
          schedule(() => {
            styleAll(targets, {
              transition: '',
              transform: '',
              height: '',
              overflow: '',
            });
            if (section._variantSwap === run) section._variantSwap = null;
          }, 240);
        });
      };

      // The renderer rewrites section dataset (rawText / swipeId / etc) when
      // Flutter's updateMessage arrives — that's our cue to animate in.
      run.mo = new MutationObserver(finish);
      run.mo.observe(section, { attributes: true });
      // Fallback in case the update is a no-op or attribute setter is skipped.
      schedule(finish, 300);

      run.send();
      styleAll(targets, {
        transition: 'none',
        ...(inX ? { transform: `translateX(${inX}px)` } : {}),
      });
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
