/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

import { TARGET_ATTRIBUTE } from '../renderer/target_toggle.js';

export class InteractionDispatch {
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

    // Use composedPath() so clicks that originate inside a Shadow DOM
    // (message content — img-regen / img-retry / img-find / img-stop and the
    // result <img> live in the shadow root) are still matched. e.target is
    // retargeted to the shadow host at the document level, so
    // e.target.closest('[data-action]') never sees those buttons.
    const actionEl = this._closestActionInPath(e);
    if (actionEl) {
      const action = actionEl.dataset.action;
      const handler = this._actionMap[action];
      if (handler) {
        handler.call(this, e, actionEl);
        return;
      }
    }

    // Imagen loading block: click anywhere (except action buttons handled
    // above) toggles the expanded prompt overlay. Ported from Glaze
    // useMessageImageGen.js handleContentClick.
    const loadingBlock = this._findInPath(e, 'imggen-loading');
    if (loadingBlock) {
      e.stopPropagation();
      loadingBlock.classList.toggle('expanded');
      return;
    }

    // composedPath() again: a link written by the message (a markdown link, or
    // the anchor an ST-style card toggles its panels with) lives in the
    // message shadow root, where e.target is retargeted to the host and
    // e.target.closest('a') never sees it.
    const link = this._closestLinkInPath(e);
    if (link) {
      e.preventDefault();
      const href = link.getAttribute('href') || '';
      if (href.startsWith('#')) {
        this._toggleFragmentTarget(link, href.slice(1));
        return;
      }
      bridge._sendToFlutter('onLinkClick', [link.href]);
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

  // Returns the first element with a [data-action] attribute along the
  // event's composed path (pierces Shadow DOM boundaries), or null.
  _closestActionInPath(e) {
    const path = (e.composedPath && e.composedPath()) || [];
    for (const node of path) {
      if (node && node.nodeType === 1 && node.dataset && node.dataset.action) {
        return node;
      }
    }
    return e.target && e.target.closest
        ? e.target.closest('[data-action]')
        : null;
  }

  // Returns the first <a href> along the event's composed path (pierces Shadow
  // DOM boundaries), or null.
  _closestLinkInPath(e) {
    const path = (e.composedPath && e.composedPath()) || [];
    for (const node of path) {
      if (node && node.nodeType === 1 && node.localName === 'a' &&
          node.hasAttribute('href')) {
        return node;
      }
    }
    return e.target && e.target.closest ? e.target.closest('a[href]') : null;
  }

  // Stands in for fragment navigation inside the root the link lives in (a
  // message shadow root, normally). The browser cannot do it there — a URL
  // fragment only resolves against the document tree — so the element the link
  // points at is marked instead, and the card's own `:target` rules, re-keyed
  // on that attribute at render time (renderer/target_toggle.js), light up.
  // Document semantics are kept: at most one target per root, and an empty
  // fragment (the `href="#"` a card closes its panel with) clears it.
  _toggleFragmentTarget(link, rawId) {
    const root = link.getRootNode ? link.getRootNode() : document;
    if (!root || !root.querySelectorAll) return;
    for (const marked of root.querySelectorAll(`[${TARGET_ATTRIBUTE}]`)) {
      marked.removeAttribute(TARGET_ATTRIBUTE);
    }
    let id = rawId;
    try { id = decodeURIComponent(rawId); } catch (_) { /* keep it raw */ }
    if (!id || id === 'top') return;
    let target = null;
    try { target = root.querySelector(`#${CSS.escape(id)}`); } catch (_) { target = null; }
    if (target) target.setAttribute(TARGET_ATTRIBUTE, '');
  }

  // Returns the first element along the event's composed path (pierces
  // Shadow DOM) that carries the given CSS class, or null.
  _findInPath(e, className) {
    const path = (e.composedPath && e.composedPath()) || [];
    for (const node of path) {
      if (node && node.nodeType === 1 && node.classList && node.classList.contains(className)) {
        return node;
      }
    }
    return null;
  }

  /* Reads the variation state a switcher arrow needs off the message section.
   * Every arrow consults this before animating: the slide/fade in
   * `animateVariantSwap` is driven by Flutter pushing an `updateMessage` back,
   * so firing it for a request Dart will refuse (edge of the list, or a
   * generation in flight) leaves the bubble faded out until the fallback timer
   * expires. `busy` covers the generation window, where every swipe/agent-swipe
   * handler in ChatSwipeController bails out. */
  _swipeState(messageId) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    const num = (value, fallback) => {
      const parsed = parseInt(value, 10);
      return Number.isNaN(parsed) ? fallback : parsed;
    };
    return {
      section,
      swipeId: section ? num(section.dataset.swipeId, 0) : 0,
      swipeTotal: section ? num(section.dataset.swipeTotal, 1) : 1,
      agentSwipeId: section ? num(section.dataset.agentSwipeId, 0) : 0,
      agentSwipeTotal: section ? num(section.dataset.agentSwipeTotal, 1) : 1,
      greetingId: section ? num(section.dataset.greetingId, 0) : 0,
      greetingTotal: section ? num(section.dataset.greetingTotal, 1) : 1,
      isLast: section ? section.dataset.isLast === 'true' : false,
      busy: !!(this.bridge.isGenerating || this.bridge.isPostGenRunning || this.bridge.isGeneratingImage),
    };
  }

  // `imgIndex` is the position of the block inside its message, stamped by the
  // formatter. -1 means "not an image gen block" (markdown images) and tells
  // Flutter to fall back to the whole-message behaviour.
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

  // Pages one image block through the images it carries. The swap happens
  // here — the pictures are already in the page — and Flutter is told only so
  // the choice survives a reload. Like a message swipe, the ends are hard: the
  // first image does not wrap around to the last.
  _stepImageVariant(e, el, direction) {
    const wrapper = e.composedPath().find(
      (node) => node.classList?.contains('imggen-result-wrapper'),
    );
    if (!wrapper) return;
    const variants = (wrapper.dataset.variants || '').split(';;').filter(Boolean);
    if (variants.length < 2) return;

    const current = parseInt(wrapper.dataset.variantIndex, 10);
    const from = Number.isInteger(current) ? current : 0;
    const next = from + direction;
    if (next < 0 || next >= variants.length) return;

    const img = wrapper.querySelector('img.imggen-result');
    const src = variants[next];
    if (img) {
      img.src = src;
      img.dataset.src = src;
      // A retry counter from the previous image must not carry over.
      delete img.dataset.retryAttempt;
    }
    const options = wrapper.querySelector('.imggen-options-btn');
    if (options) options.dataset.src = src;
    const count = wrapper.querySelector('.imggen-variant-count');
    if (count) count.textContent = `${next + 1}/${variants.length}`;
    wrapper.dataset.variantIndex = String(next);

    const section = e.composedPath().find((node) => node.dataset?.messageId);
    const messageId = section ? section.dataset.messageId : '';
    const rawIndex = parseInt(el.dataset.imgIndex, 10);
    if (!messageId || !Number.isInteger(rawIndex) || rawIndex < 0) return;
    this.bridge._sendToFlutter('onImgVariant', [JSON.stringify({
      messageId,
      imgIndex: rawIndex,
      variantIndex: next,
    })]);
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
        // First variation → hard edge, no wrap to the last one and no
        // animation. Dart answers such a request with a no-op, so animating
        // would fade the bubble out and hold it blank until the 300 ms
        // fallback timer put it back — the "stuck message" symptom.
        const { swipeId, busy } = this._swipeState(id);
        if (busy || swipeId <= 0) return;
        bridge._swipeHandler.animateVariantSwap(id, 'prev', () =>
          bridge._sendToFlutter('onSwipe', [JSON.stringify({ id, direction: 'left' })])
        );
      },
      'swipe-right': (e, el) => {
        const id = el.dataset.messageId;
        // Mirror the touch-swipe gesture (swipe_gesture_handler.onEnd): when the
        // next arrow is pressed while already on the last variation of the last
        // message, kick off a regeneration into a fresh swipe instead of a no-op
        // — unless swipe-regeneration is disabled in settings.
        const { swipeId, swipeTotal, isLast, busy } = this._swipeState(id);
        if (busy) return;
        if (swipeId >= swipeTotal - 1) {
          if (isLast && !bridge.disableSwipeRegeneration) {
            bridge._sendToFlutter('onRegenerate', [id, 'new_variant']);
          }
          return;
        }
        bridge._swipeHandler.animateVariantSwap(id, 'next', () =>
          bridge._sendToFlutter('onSwipe', [JSON.stringify({ id, direction: 'right' })])
        );
      },
      'agent-swipe-left': (e, el) => {
        const id = el.dataset.messageId;
        const { agentSwipeId, busy } = this._swipeState(id);
        if (busy || agentSwipeId <= 0) return;
        bridge._swipeHandler.animateVariantSwap(id, 'prev', () =>
          bridge._sendToFlutter('onAgentSwipe', [JSON.stringify({ id, direction: 'left' })])
        );
      },
      'agent-swipe-right': (e, el) => {
        const id = el.dataset.messageId;
        const { agentSwipeId, agentSwipeTotal, busy } = this._swipeState(id);
        if (busy || agentSwipeId >= agentSwipeTotal - 1) return;
        bridge._swipeHandler.animateVariantSwap(id, 'next', () =>
          bridge._sendToFlutter('onAgentSwipe', [JSON.stringify({ id, direction: 'right' })])
        );
      },
      'greeting-prev': (e, el) => {
        const id = el.dataset.messageId;
        const { greetingId, busy } = this._swipeState(id);
        if (busy || greetingId <= 0) return;
        bridge._swipeHandler.animateVariantSwap(id, 'prev', () =>
          bridge._sendToFlutter('onChangeGreeting', [id, -1])
        );
      },
      'greeting-next': (e, el) => {
        const id = el.dataset.messageId;
        const { greetingId, greetingTotal, busy } = this._swipeState(id);
        if (busy || greetingId >= greetingTotal - 1) return;
        bridge._swipeHandler.animateVariantSwap(id, 'next', () =>
          bridge._sendToFlutter('onChangeGreeting', [id, 1])
        );
      },
      'stop': (e, el) => bridge._sendToFlutter('onStop', []),
      'regenerate': (e, el) => bridge._sendToFlutter('onRegenerate', [el.dataset.messageId, el.dataset.mode || 'magic']),
      'toggle-guided': (e, el) => bridge._swipeHandler.toggleGuidedSwipe(el.dataset.messageId),
      'rerun-cleaner': (e, el) => bridge._sendToFlutter('onRerunCleaner', [el.dataset.messageId]),
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
      'img-variant-prev': (e, el) => this._stepImageVariant(e, el, -1),
      'img-variant-next': (e, el) => this._stepImageVariant(e, el, 1),
      'img-options': (e, el) => {
        const { instr, messageId, imgIndex } = this._extractImgInstruction(el, e.composedPath());
        bridge._sendToFlutter('onImgOptions', [JSON.stringify({
          src: el.dataset.src || '',
          instruction: instr,
          messageId,
          imgIndex,
        })]);
      },
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
