/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

import { GenTimer } from './gen_timer.js';
import { ImgGenTimer } from './imggen_timer.js';
import { refreshImgGenPlaceholderState } from '../renderer/imggen_placeholder.js';
import { MessageUpdateBatcher } from './message_update_batcher.js';
import { SelectionManager } from './selection_manager.js';
import { EditController } from './edit_controller.js';
import { SwipeGestureHandler } from './swipe_gesture_handler.js';
import { TrackpadScroll } from './trackpad_scroll.js';
import { InteractionDispatch } from './interaction_dispatch.js';
import { PanelHost } from './panel_host.js';
import { sanitizeExtBlockHtml } from './html_sanitizer.js';
import { parseImageResultElement } from '../formatter/formatter.js';
import { ICON } from '../renderer/icon_library.js';
import { applyTypingPhase } from '../renderer/typing_phase.js';

/* Id of the virtual typing placeholder. It is not a persisted message: Flutter
 * owns one constant id for it and the page keeps it pinned to the tail, so a
 * persisted message that lands while it is up never slots in underneath. */
const STREAMING_ID = '__streaming__';

export class Bridge {
  constructor(renderer, virtualList) {
    this.renderer = renderer;
    this.virtualList = virtualList;
    this._pendingRequests = new Map();
    this._requestCounter = 0;
    this.isGenerating = false;
    this.isGeneratingImage = false;
    this.isPostGenRunning = false;
    // Label under the typing pencil, naming the phase the generation is
    // actually in. Empty = the renderer's default. See setGenerationPhase().
    this.generationPhaseText = '';
    // Placeholder element lifted out by clearAll, waiting for the setMessages
    // that follows it. See _keepingPlaceholderLast().
    this._parkedPlaceholder = null;
    // Scroll-hide header state. Lifted out of the _setupScrollListener closure
    // so the rest of the controller can reach it: _ensureHeaderReachable()
    // un-hides the header when the list shrinks out of scroll range, and
    // showHeader() clears it when a chat opens.
    this._headerHidden = false;
    // Last scroll offset the header tracker decided on, and the deadline until
    // which it only re-baselines instead of deciding. Both are instance fields
    // so showHeader() can reset them — see showHeader() for why that matters.
    this._headerLastTop = 0;
    this._headerRebaselineUntil = 0;
    this._genTimer = new GenTimer(renderer);
    this._imgGenTimer = new ImgGenTimer();
    this._updateBatcher = new MessageUpdateBatcher();
    this._selectionManager = new SelectionManager(
      (name, args) => this._sendToFlutter(name, args),
      () => this._orderedMessageIds(),
    );
    this._editController = new EditController((name, args) => this._sendToFlutter(name, args));
    this._interaction = new InteractionDispatch(this);
    this._charName = null;
    this._personaName = null;
    this._charAvatarUrl = null;
    this._personaAvatarUrl = null;
    this.batterySaver = false;
    this.disableSwipeRegeneration = false;
    // One "a message tried to run JS" report per WebView load — see
    // notifyMessageScriptBlocked().
    this._messageScriptBlockedNotified = false;
    renderer.selectionManager = this._selectionManager;
    this._swipeHandler = new SwipeGestureHandler(
      (name, args) => this._sendToFlutter(name, args),
      () => this.virtualList.container,
      () => this.isGenerating,
      () => this.disableSwipeRegeneration,
    );
    // Windows-only fallback path: the embedder never delivers touchpad pans to
    // WebView2 as wheel events, so Flutter replays them through here.
    this._trackpadScroll = new TrackpadScroll(() => this.virtualList.container);
    // Bottom-inset reconciliation state — see setBottomPadding().
    // `_bottomInsetPx` is the inset Flutter measured from the bottom edge of the
    // full-size WebView box (input bar + keyboard/drawer + safe area);
    // `_viewportFullH` is that box's height in Flutter logical px. Comparing the
    // latter against the live container height reveals how much of the inset the
    // embedder already removed by shrinking the WebView's own viewport.
    this._bottomInsetPx = 0;
    this._viewportFullH = 0;
    // Re-pin glide state (see _glideScrollTo). `_atBottom` is the live
    // parked-at-bottom flag kept by the scroll listener; the very first inset
    // application lands instantly so the chat doesn't slide into place on open.
    this._atBottom = true;
    this._repinAnimating = false;
    this._repinRaf = 0;
    this._bottomInsetApplied = false;
    this._setupScrollListener();
    this._setupViewportShrinkListener();
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
      // Per-message stored persona wins; otherwise use the active identity.
      const newName = isUser
        ? (storedPersonaName || this._personaName || 'You')
        : (this._charName || stored || 'Character');
      const newAvatarUrl = isUser ? this._personaAvatarUrl : this._charAvatarUrl;

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

  /* Names the phase of the running generation in the typing bubble. Called
   * from Flutter on every transition (prompt assembly -> retrieval -> waiting
   * on the model -> streaming -> post-gen), and with an empty string when the
   * run ends so the next bubble starts from the default label instead of the
   * last phase of the previous turn. */
  setGenerationPhase(text) {
    const next = typeof text === 'string' ? text : '';
    if (next === this.generationPhaseText) return;
    this.generationPhaseText = next;
    this._applyGenerationPhase();
  }

  /* A typing bubble is only ever on screen for the live generation, so every
   * `.typing-text` currently rendered belongs to this phase. */
  _applyGenerationPhase() {
    const reduceMotion = window.matchMedia
      && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const animate = !this.batterySaver && !reduceMotion;
    document.querySelectorAll('.typing-container .typing-text').forEach((el) => {
      applyTypingPhase(el, this.generationPhaseText, animate);
    });
  }

  setGenerating(value) {
    const wasGenerating = this.isGenerating;
    this.isGenerating = !!value;
    this._syncGenerationTimer();
    // A cancelled generation trims its empty placeholder, so the list can
    // shrink right here — possibly below the scroll range a hidden header
    // needs to be scrolled back into view. See _ensureHeaderReachable().
    if (wasGenerating && !this.isGenerating) this._ensureHeaderReachable();
  }

  setPostGenRunning(value) {
    this.isPostGenRunning = !!value;
  }

  // The image stage is the only thing that generates from an `[IMG:GEN…]` tag,
  // so this flag is what tells a pending block apart from a running one
  // (INV-IG1). The transition carries no re-render of its own — the reply's
  // last chunk is already painted — so the placeholders are restamped here,
  // and the ticker is woken for the clocks that just started.
  setImageGenerating(value) {
    this.isGeneratingImage = !!value;
    refreshImgGenPlaceholderState();
    this._imgGenTimer.ensureRunning();
  }

  _syncGenerationTimer() {
    if (this.isGenerating) {
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

  // Windows touchpad pan replayed by Flutter as a wheel at the cursor. See
  // ./trackpad_scroll.js for why the embedder can't deliver it itself.
  trackpadScroll(dx, dy, x, y) {
    this._trackpadScroll.scrollBy(dx, dy, x, y);
  }

  // True while the list is being scrolled by us rather than by the user. The
  // virtual list raises the flag around its own scrolls (streaming
  // auto-follow, scroll-to-bottom / -message, anchor restore) and the bridge
  // raises it around the bottom-inset re-pin glide (see
  // _reconcileBottomInset), which also drives `_repinAnimating`.
  _isProgrammaticScroll() {
    return !!(this._repinAnimating || this.virtualList?.isProgrammaticScrolling);
  }

  // Re-shows the header when scrolling can no longer bring it back.
  //
  // The tracker only un-hides on an upward scroll, so a hidden header stays
  // recoverable only while the list has scroll range left. Losing it strands
  // the header off screen with no gesture that could restore it — which is
  // what a cancelled generation does when it trims its empty placeholder and
  // the remaining chat is shorter than the viewport.
  //
  // Deliberately conditional: while the list still scrolls, the header belongs
  // to the user, so this must not undo a hide they asked for by scrolling down
  // mid-stream. Emitting keeps JS the single source of truth for the Flutter
  // header state.
  _ensureHeaderReachable() {
    if (!this._headerHidden) return;
    const container = this.virtualList?.container;
    if (!container) return;
    // Mirrors the `st > 50` hide threshold: with less range than that left
    // there is no upward scroll available to bring the header back.
    if (container.scrollHeight - container.clientHeight > 50) return;
    this._headerHidden = false;
    this._sendToFlutter('onHeaderScroll', [false]);
  }

  // Re-shows the header and re-baselines the hide-on-scroll tracker. Flutter
  // calls this whenever a chat is opened or a session is switched.
  //
  // The WebView — and therefore this controller — is kept alive across chats
  // (see chat_webview_keep_alive.dart), so both `_headerHidden` and the scroll
  // baseline carry over from the chat that was open before. That broke a chat
  // open two ways: the load's jump to the bottom of the new chat read as one
  // large downward scroll and hid the header the instant the chat appeared,
  // and a stale `_headerHidden === true` left JS disagreeing with Flutter's
  // fresh state — since this tracker only emits on transitions, the desync
  // then persisted and the header stopped responding to scrolling at all.
  //
  // Emitted unconditionally so Flutter's state is realigned even when JS
  // already believed the header was visible.
  showHeader() {
    this._headerHidden = false;
    this._headerLastTop = this.virtualList?.container?.scrollTop || 0;
    // The messages land and the list jumps to the bottom over the frames right
    // after this call; those scrolls are programmatic, not user intent. Matches
    // the window setMessages() already uses to suppress load-more.
    this._headerRebaselineUntil = Date.now() + 1000;
    this._sendToFlutter('onHeaderScroll', [false]);
  }

  _setupScrollListener() {
    let loadMoreCooldown = false;
    let lastLoadTop = 0;
    let lastShowScrollToBottom = null;
    // Header hide-on-scroll (ported from Glaze/src/core/services/ui.js initHeaderScroll).
    // `_headerHidden` / `_headerLastTop` are instance fields (see constructor)
    // so _ensureHeaderReachable() can re-show the header when the list shrinks
    // and showHeader() can re-baseline the tracker when a chat opens.
    let ticking = false;
    const container = this.virtualList.container;

    const emitScrollToBottomVisibility = () => {
      const distanceFromBottom =
        container.scrollHeight - container.scrollTop - container.clientHeight;
      // Live parked-at-bottom flag for the inset reconciler. Frozen while our
      // own re-pin glide runs: its intermediate offsets all read as "not at
      // bottom", and letting those through would make a mid-glide correction
      // (the keyboard settle push) re-aim at the wrong offset.
      if (!this._repinAnimating) this._atBottom = distanceFromBottom < 5;
      // Mirror Vue ChatView.onScroll(): button appears past 100px from bottom.
      const show = distanceFromBottom > 100;
      if (lastShowScrollToBottom === show) return;
      lastShowScrollToBottom = show;
      this._sendToFlutter('onScrollToBottomVisibility', [show]);
    };

    const updateHeader = () => {
      ticking = false;
      const st = container.scrollTop;
      // Right after showHeader() the list is still being filled and scrolled to
      // the bottom programmatically. Follow the offset without deciding, so the
      // jump is never mistaken for the user scrolling down.
      if (Date.now() < this._headerRebaselineUntil) {
        this._headerLastTop = st <= 0 ? 0 : st;
        return;
      }
      // Scrolls we caused ourselves are not user intent: the streaming
      // auto-follow, the keyboard / input-bar re-pin glide, scroll-to-message
      // and the anchor restore all move scrollTop on their own. Follow the
      // offset without deciding, so none of them hides the header.
      //
      // This replaced a blanket freeze on the generation flag, which suspended
      // hide-on-scroll for the whole streaming window: during a long reply the
      // header simply stopped responding to scrolling. Only the auto-follow
      // needs suppressing, and it already announces itself through the virtual
      // list's own programmatic-scroll flag.
      //
      // An upward move still restores an already-hidden header. The auto-follow
      // only ever pins downward, so an upward one inside this window is the
      // user's — and it is how they detach from the follow in the first place
      // (the flag stays set for ~80ms after the last pin, see smartScroll()).
      if (this._isProgrammaticScroll()) {
        if (st < this._headerLastTop - 3 && this._headerHidden) {
          this._headerHidden = false;
          this._sendToFlutter('onHeaderScroll', [false]);
        }
        this._headerLastTop = st <= 0 ? 0 : st;
        return;
      }
      // A shrink can clamp scrollTop without leaving room to scroll back up.
      this._ensureHeaderReachable();
      if (st < 0 || st + container.clientHeight > container.scrollHeight) {
        this._headerLastTop = st <= 0 ? 0 : st;
        return;
      }
      if (st > this._headerLastTop + 3 && st > 50) {
        if (!this._headerHidden) {
          this._headerHidden = true;
          this._sendToFlutter('onHeaderScroll', [true]);
        }
      } else if (st < this._headerLastTop - 3) {
        if (this._headerHidden) {
          this._headerHidden = false;
          this._sendToFlutter('onHeaderScroll', [false]);
        }
      }
      this._headerLastTop = st <= 0 ? 0 : st;
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

  /* ---------- Viewport shrink (soft keyboard) ---------- */
  // Whether the soft keyboard shrinks the WebView's own viewport or merely
  // overlays it is decided by the embedder (Android window resize mode +
  // edge-to-edge, iOS WKWebView, desktop), and Flutter cannot tell which
  // happened — every earlier attempt to hard-code one answer broke the other
  // case. So the container measures it: `#chat-container` is `height: 100vh`,
  // and any shrink of the visible viewport shows up in its clientHeight.
  // Reconcile whenever that can change; the padding is then derived from the
  // difference, never assumed. See setBottomPadding() / _viewportShrinkPx().
  _setupViewportShrinkListener() {
    const container = this.virtualList.container;
    const onViewportChange = () => this._reconcileBottomInset();
    if (typeof ResizeObserver === 'function') {
      this._viewportObserver = new ResizeObserver(onViewportChange);
      // Border-box, so our own paddingBottom writes (which shrink the content
      // box) don't re-enter this handler on every inset change.
      this._viewportObserver.observe(container, { box: 'border-box' });
    }
    window.addEventListener('resize', onViewportChange);
    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', onViewportChange);
    }
  }

  // How many px of Flutter's bottom inset the WebView viewport already ate by
  // shrinking. 0 when the viewport stays full-screen and the keyboard simply
  // overlays it (then the whole inset must become real padding).
  _viewportShrinkPx() {
    const full = this._viewportFullH || 0;
    if (full <= 0) return 0;
    const shrink = full - this.virtualList.container.clientHeight;
    // CSS px and Flutter logical px agree (initial-scale=1), but rounding on
    // either side can leave a pixel or two of slack — ignore that as noise so a
    // non-shrinking embedder never loses real padding to it.
    if (shrink < 8) return 0;
    return Math.min(shrink, this._bottomInsetPx);
  }

  /* ---------- Interaction dispatch ---------- */
  _setupInteractionListener() {
    document.addEventListener('click', (e) => this._interaction.handleClick(e));

    document.addEventListener('selectionchange', () => this._selectionManager.handleSelectionChange());

    document.addEventListener('contextmenu', (e) => this._selectionManager.handleContextMenu(e));
  }

  _extractText(section) {
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

  /* ---------- Typing placeholder pinning ---------- */

  /* Lifts the placeholder out of the list and hands back its element, or null
   * when it is not the tail. The node survives detached, so putting it back
   * keeps whatever has already streamed into it. */
  _detachStreamingPlaceholder() {
    const items = this.virtualList.items;
    const last = items[items.length - 1];
    if (!last || last.id !== STREAMING_ID) return null;
    const el = last.el;
    this.virtualList.remove(STREAMING_ID);
    return el;
  }

  _reattachStreamingPlaceholder(el) {
    if (!el) return;
    this.virtualList.append(STREAMING_ID, el);
  }

  /* Runs [fn] with the placeholder lifted out, then puts it back at the tail.
   * Every batch append goes through here: `virtualList.append` lands after
   * whatever is currently last, so a persisted message arriving mid-generation
   * would otherwise render *below* the bubble that is still typing. */
  _keepingPlaceholderLast(fn) {
    const el = this._detachStreamingPlaceholder();
    try {
      fn();
    } finally {
      this._reattachStreamingPlaceholder(el);
    }
  }

  /* ---------- Message list API ---------- */
  setMessages(messagesJson, preserveScroll = false) {
    this.flush();
    // A full re-render drops the placeholder while Flutter still believes it
    // is on screen — every following delta would then update a node that no
    // longer exists and the reply would stream into nothing. Carry it across.
    // `clearAll` runs as its own call right before this one on the re-render
    // path, so it parks the element here for us to pick up.
    const carriedPlaceholder =
      this._detachStreamingPlaceholder() || this._parkedPlaceholder || null;
    this._parkedPlaceholder = null;
    this._suppressLoadMore = true;
    // When re-rendering in place (e.g. a preset switch changes display regexes),
    // remember the current reading position so the batch replace below doesn't
    // yank the chat back to the top/bottom.
    const anchor = preserveScroll ? this.virtualList.captureAnchor() : null;
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
    this._reattachStreamingPlaceholder(carriedPlaceholder);
    if (anchor) this.virtualList.restoreAnchor(anchor);
    this._hideLoadingScreen();
    this._imgGenTimer.ensureRunning();
    setTimeout(() => { this._suppressLoadMore = false; }, 1000);
  }

  _renderAndAppend(msg) {
    const rendered = this.renderer.renderMessage(msg);
    for (const el of rendered) {
      const id = el.dataset.messageId || `__date_${el.dataset.dateSeparator || Date.now()}`;
      this.virtualList.append(id, el);
    }
  }

  appendMessage(messageJson) {
    this.flush();
    const msg = JSON.parse(messageJson);
    // The placeholder is itself appended through here — pinning it behind
    // itself would evict and re-add the node for nothing.
    if (msg.id === STREAMING_ID) {
      this._renderAndAppend(msg);
    } else {
      this._keepingPlaceholderLast(() => this._renderAndAppend(msg));
    }
    this.virtualList.scrollToBottom();
    this._imgGenTimer.ensureRunning();
  }

  appendMessages(messagesJson) {
    this.flush();
    const messages = JSON.parse(messagesJson);
    this._keepingPlaceholderLast(() => {
      messages.forEach(msg => this._renderAndAppend(msg));
    });
    this._imgGenTimer.ensureRunning();
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

  // Patch only memory badges when the async memory providers settle. This
  // deliberately avoids rebuilding message bodies/panels and works for both
  // mounted and virtualized rows because itemMap retains every row element.
  patchMemoryStatuses(statusesJson) {
    const statuses = JSON.parse(statusesJson);
    for (const [id, status] of Object.entries(statuses)) {
      const item = this.virtualList.itemMap?.get(id);
      const section = item?.el;
      if (!section) continue;
      const current = section.querySelector('.msg-memory-badge')?.textContent;
      // REBUILD/STALE come from message-local coverage and outrank book state.
      if (current === 'REBUILD' || current === 'STALE') continue;
      this.renderer.updateMessageMeta(section, { id, memoryStatus: status });
    }
  }

  _executeUpdateMessage(msg) {
    const section = document.querySelector(`[data-message-id="${msg.id}"]`);
    if (!section) {
      // Last line of defence for the virtual placeholder: Flutter only sends
      // updates for it while it believes one is on screen, so if the node is
      // gone the list lost it somewhere. Re-create it instead of dropping the
      // reply on the floor.
      if (msg.id === STREAMING_ID) {
        this._renderAndAppend(msg);
        this.virtualList.scrollToBottom();
      }
      return;
    }

    const animate = !!msg.swipeDirection;
    if (msg.swipeDirection) section.dataset.swipeDirection = msg.swipeDirection;

    if (msg.reasoning) section.dataset.reasoning = msg.reasoning;
    else if (msg.reasoning === null || msg.reasoning === '') delete section.dataset.reasoning;

    if (msg.text != null) section.dataset.rawText = msg.text;

    // Kept in step with rawText: an update that carries text but no sourceText
    // means the stored text and the rendered one are identical again, so a
    // stale source from an earlier update must not survive into the editor.
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
      animate,
    );
    this._imgGenTimer.ensureRunning();

    if (msg.isHidden !== undefined) {
      section.classList.toggle('msg-hidden', !!msg.isHidden);
    }

    if (msg.imageHidden !== undefined) {
      this.renderer.updateImageAttachmentHidden(section, !!msg.imageHidden);
    }

    if (msg.swipeIndex !== undefined) section.dataset.swipeId = String(msg.swipeIndex);
    if (msg.swipeTotal !== undefined) section.dataset.swipeTotal = String(msg.swipeTotal);
    if (msg.agentSwipeIndex !== undefined) section.dataset.agentSwipeId = String(msg.agentSwipeIndex);
    if (msg.agentSwipeTotal !== undefined) section.dataset.agentSwipeTotal = String(msg.agentSwipeTotal);
    if (msg.greetingTotal !== undefined) section.dataset.greetingTotal = String(msg.greetingTotal);
    if (msg.greetingIndex !== undefined) section.dataset.greetingId = String(msg.greetingIndex);

    // Restore data-is-last on char sections after generation ends.
    // setLastMessage(null) clears this flag at generation start; without
    // re-applying it here, the swipe gesture handler sees isLast=false and
    // blocks the left-swipe-to-regenerate gesture on subsequent swipes.
    if (msg.isLast !== undefined && !section.classList.contains('user')) {
      if (msg.isLast) section.dataset.isLast = 'true';
      else delete section.dataset.isLast;
    }

    this._syncMessageControls(section, msg);

    this.renderer.updateMessageMeta(section, msg);

    // Follow the bottom while a message streams in — ported from Vue
    // ChatView.smartScroll() invoked on every generation chunk. Gated on the
    // typing flag (the streamed message) and suppressed during search so the
    // active match stays in view. The pin gate inside smartScroll keeps it from
    // yanking a user who scrolled up.
    if (msg.isTyping && !(this.renderer && this.renderer.searchQuery)) {
      this.virtualList.smartScroll();
    }
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
    const agentSwipeIndex = msg.agentSwipeIndex !== undefined ? msg.agentSwipeIndex : parseInt(section.dataset.agentSwipeId || '0', 10);
    const agentSwipeTotal = msg.agentSwipeTotal !== undefined ? msg.agentSwipeTotal : parseInt(section.dataset.agentSwipeTotal || '0', 10);
    const agentSwipeFinalCount = msg.agentSwipeFinalCount !== undefined ? msg.agentSwipeFinalCount : 0;
    const greetingIndex = msg.greetingIndex !== undefined ? msg.greetingIndex : parseInt(section.dataset.greetingId || '0', 10);
    const greetingTotal = msg.greetingTotal !== undefined ? msg.greetingTotal : parseInt(section.dataset.greetingTotal || '0', 10);
    const messageIndex = parseInt(section.dataset.messageIndex || '-1', 10);
    const hasSwipes = isChar && swipeTotal > 1;
    const hasAgentSwipes = isChar && agentSwipeFinalCount > 1;
    const hasGreetings = isChar && messageIndex === 0 && greetingTotal > 1;
    const showRegen = ((!isChar && isLast) || isError) && !isGenerating && !isEditing;

    center.innerHTML = '';

    if (hasSwipes) {
      center.appendChild(this.renderer._createSwitcher(section.dataset.messageId, swipeIndex || 0, swipeTotal, 'swipe'));
    } else if (hasGreetings) {
      center.appendChild(this.renderer._createSwitcher(section.dataset.messageId, greetingIndex || 0, greetingTotal, 'greeting'));
    }

    // Nested swipes: blue sub-swipe switcher.
    if (hasAgentSwipes) {
      center.appendChild(this.renderer._createSwitcher(section.dataset.messageId, agentSwipeIndex || 0, agentSwipeTotal, 'agent-swipe'));
    }

    if (isChar && isLast && !isGenerating && !isEditing && agentSwipeTotal >= 1) {
      const rerun = document.createElement('div');
      rerun.className = 'msg-rerun-cleaner';
      rerun.dataset.action = 'rerun-cleaner';
      rerun.dataset.messageId = section.dataset.messageId;
      rerun.title = 'Re-run cleaner';
      rerun.innerHTML = ICON.rerunCleaner;
      center.appendChild(rerun);
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

    if (showRegen) {
      const regen = document.createElement('div');
      regen.className = 'msg-regenerate';
      if (hasSwipes || hasGreetings || hasAgentSwipes) regen.classList.add('icon-only');
      regen.dataset.action = 'regenerate';
      regen.dataset.messageId = section.dataset.messageId;
      regen.dataset.mode = 'magic';
      regen.title = 'Regenerate';
      regen.innerHTML = ICON.regen;
      if (!hasSwipes && !hasGreetings && !hasAgentSwipes) {
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
      this.renderer.animateRemoveSection(el, () => {
        // The exit animation runs for ~340ms and the id can be re-registered
        // in the meantime — the streaming placeholder reuses one constant id,
        // and `append` already evicted the node we animated out. Dropping the
        // id here regardless would delete the *new* bubble.
        const item = this.virtualList.itemMap?.get(messageId);
        if (!item || item.el === el) {
          this.virtualList.remove(messageId);
        }
        this._pruneOrphanSeparators();
        // The list just got shorter; a hidden header may have lost the scroll
        // range that lets the user bring it back. This lands ~340ms after the
        // exit animation started, which is why setGenerating()'s own check
        // (the placeholder is still on screen there) is not enough.
        this._ensureHeaderReachable();
      });
    } else {
      this.virtualList.remove(messageId);
      this._pruneOrphanSeparators();
      this._ensureHeaderReachable();
    }
  }

  // Drop separators that no longer head any message. Deleting the last
  // message under a date separator (or trimming the tail on a branch/edit)
  // otherwise leaves the separator hanging until a full chat reload. A date
  // separator is orphaned when no real message follows it before the next
  // separator or the end of the list; the origin marker (`__date_origin`)
  // stays as long as any real message remains.
  _pruneOrphanSeparators() {
    if (!this.virtualList || !this.virtualList.items) return;
    const items = this.virtualList.items;
    const isSep = (id) => typeof id === 'string' && id.startsWith('__date_');
    let realCount = 0;
    for (const it of items) if (!isSep(it.id)) realCount++;
    const orphanIds = [];
    for (let i = 0; i < items.length; i++) {
      const id = items[i].id;
      if (!isSep(id)) continue;
      if (id === '__date_origin') {
        if (realCount === 0) orphanIds.push(id);
        continue;
      }
      let hasMsg = false;
      for (let j = i + 1; j < items.length; j++) {
        if (isSep(items[j].id)) break;
        hasMsg = true;
        break;
      }
      if (!hasMsg) orphanIds.push(id);
    }
    for (const id of orphanIds) this.virtualList.remove(id);
  }

  clearAll() {
    this.flush();
    this._showLoadingScreen();
    this._panelHost?.closeAll();
    // Park the placeholder rather than dropping it: every clearAll on the
    // message-sync path is immediately followed by setMessages, which puts it
    // back at the tail. Without this the reply streams into a removed node.
    this._parkedPlaceholder = this._detachStreamingPlaceholder();
    this.virtualList.clear();
  }

  scrollToBottom(behavior = 'auto') {
    const settled = this.virtualList.scrollToBottom(behavior);
    requestAnimationFrame(() => {
      this._sendToFlutter('onScrollToBottomVisibility', [false]);
    });
    return settled;
  }

  // Arm a one-shot "stick to bottom on the next append" so that sending a
  // message scrolls the view down even when the user had scrolled up (the
  // append handler otherwise only follows the bottom when already near it).
  requestScrollToBottomOnAppend() {
    this.virtualList.pendingScrollToBottom();
  }
  scrollToMessage(messageId, highlight = false) { this.virtualList.scrollToMessage(messageId, highlight); }

  setSearch(query, activeIndex, scroll = true) { this.renderer.setSearch(query, activeIndex, scroll); }

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

    const toggleClass = (className, enabled) => {
      container.classList.toggle(className, !!enabled);
    };
    toggleClass('hide-user-avatar', theme['show-user-avatar'] === '0');
    toggleClass('hide-char-avatar', theme['show-char-avatar'] === '0');
    toggleClass('hide-user-name', theme['show-user-name'] === '0');
    toggleClass('hide-char-name', theme['show-char-name'] === '0');
  }

  // [px] is the bottom inset Flutter measured from the bottom edge of the
  // full-size WebView box: input bar + keyboard/drawer + leftover safe area.
  // [viewportHeight] is that box's height (Flutter logical px), which lets the
  // page tell how much of the inset its own viewport already absorbed — see
  // _setupViewportShrinkListener. Pass 0/undefined and the whole inset becomes
  // padding, i.e. the behaviour of the single-argument version.
  //
  // The keyboard moves the content by exactly [px]'s delta either way; only how
  // much of it has to be *padding* differs, so the scroll compensation below is
  // driven by the inset and stays independent of the split.
  setBottomPadding(px, viewportHeight) {
    const next = Number(px) || 0;
    const insetDiff = next - this._bottomInsetPx;
    this._bottomInsetPx = next;
    if (viewportHeight != null) this._viewportFullH = Number(viewportHeight) || 0;
    this._reconcileBottomInset(insetDiff);
  }

  // Applies `inset - viewport shrink` as the container's real padding and keeps
  // the reading position anchored.
  //
  // [insetDiff] is how much Flutter's inset just moved (0 when a viewport resize
  // triggered this instead). Only the inset drives the scroll: a pure shrink
  // needs no scroll adjustment, because dropping the same number of px from the
  // padding leaves scrollHeight - clientHeight — and therefore the offset that
  // parks the newest message on the input bar — exactly where it was.
  _reconcileBottomInset(insetDiff = 0) {
    const container = document.getElementById('chat-container') || document.body;
    const target = this._targetBottomPadding();
    const prevPadding = parseFloat(container.style.paddingBottom) || 0;
    const paddingChanged = Math.abs(target - prevPadding) >= 0.1;
    if (!paddingChanged && Math.abs(insetDiff) < 0.1) return;

    // Ported from Vue ChatView.updateContentPadding(). We shift scrollTop by the
    // inset delta so the content the user is reading stays anchored to the
    // rising/falling input bar when the keyboard / magic drawer / input height
    // changes — and so more-recent messages slide up into view above the
    // keyboard. This must happen whether or not the chat is parked at the
    // bottom; the at-bottom branch is just the numerically-clean equivalent of
    // `+= insetDiff` that avoids float drift at the very end of the list.
    //
    // The tracked flag wins over the live metric because the live one is
    // unreliable here: mid-glide offsets and a viewport that just shrank both
    // read as "scrolled away" while the user is in fact parked at the newest
    // message. The live metric is still consulted so a list that grew without
    // emitting a scroll event (streamed append) keeps following.
    const liveDistance =
      container.scrollHeight - container.scrollTop - container.clientHeight;
    const wasAtBottom = this._atBottom || liveDistance < 5;

    // Lock the virtual-scroll window logic while we programmatically re-pin so
    // the inset-follow does not fight onContainerScroll / the pin tracker. The
    // matching unlock is owned by _finishRepin — a fixed timeout here would
    // release it mid-glide.
    const vl = this.virtualList;
    if (vl) vl.isProgrammaticScrolling = true;
    clearTimeout(this._bottomPadUnlockTimer);

    // Content height is padding-independent, so it survives the padding moves
    // below and can be measured once, here.
    const contentHeight = container.scrollHeight - prevPadding;
    const targetScrollTop = wasAtBottom
      ? this._restingScrollTop(container, contentHeight)
      : container.scrollTop + insetDiff;

    // The first application (chat just opened) must land instantly — gliding
    // there would show the list visibly sliding into place on open.
    if (!this._bottomInsetApplied) {
      this._bottomInsetApplied = true;
      cancelAnimationFrame(this._repinRaf);
      this._repinAnimating = false;
      container.style.paddingBottom = target + 'px';
      container.scrollTop = targetScrollTop;
      this._finishRepin(container);
      return;
    }

    // Grow the padding now; defer any reduction (see _scheduleShrink). Growing
    // early is always free — a longer scroll range can never clamp.
    //
    // The padding is applied in ONE step either way, never tweened: it relayouts
    // the whole message list, so animating it would relayout every frame — the
    // jank the Flutter side already avoids by pushing only end values. The
    // visible smoothness comes from gliding scrollTop, a compositor scroll, and
    // the padding it reveals sits under the keyboard / input bar where it cannot
    // be seen mid-transition.
    if (target > prevPadding) {
      container.style.paddingBottom = target + 'px';
    } else if (paddingChanged) {
      this._scheduleShrink(container);
    }

    this._glideScrollTo(container, targetScrollTop);
  }

  // A padding REDUCTION waits until both sides of the transition have stopped
  // moving. Shortening the scroll range under a list parked at the bottom makes
  // the engine clamp scrollTop *itself*, instantly — the un-animatable jump the
  // glide exists to avoid — and mid-transition the two sides disagree about how
  // much padding is right: Flutter predicts the end inset the moment the
  // keyboard starts falling, while the viewport is still shrunk. Applying the
  // reduction from that inconsistent pair left no slack for the viewport growing
  // back, which is what made closing the keyboard at the end of a chat jump.
  //
  // Once everything is settled the reduction is clamp-free by construction: at
  // the resting offset the shortened range ends exactly where the list already
  // is (see _restingScrollTop).
  _scheduleShrink(container) {
    clearTimeout(this._paddingShrinkTimer);
    this._paddingShrinkTimer = setTimeout(() => {
      // Still gliding — the transition has not settled, try again after it.
      if (this._repinAnimating) {
        this._scheduleShrink(container);
        return;
      }
      const target = this._targetBottomPadding();
      const applied = parseFloat(container.style.paddingBottom) || 0;
      if (target >= applied - 0.1) return;
      container.style.paddingBottom = target + 'px';
    }, 260);
  }

  // Padding = the part of Flutter's inset the WebView viewport did not already
  // absorb by shrinking. See _setupViewportShrinkListener.
  _targetBottomPadding() {
    return Math.max(0, this._bottomInsetPx - this._viewportShrinkPx());
  }

  // The offset that parks the newest message on the input bar, once everything
  // has settled. Derived from the FULL box height instead of the live viewport
  // on purpose: at rest the padding is `inset - shrink` and the viewport is
  // `full - shrink`, so the shrink cancels out and the resting offset is just
  //     contentHeight + inset - full
  // — the same number whether the keyboard has already resized the viewport,
  // hasn't yet, or never will. That is what lets the glide aim at the final
  // position from the first frame of a transition instead of chasing a target
  // that moves again when the resize lands.
  _restingScrollTop(container, contentHeight) {
    const full = this._viewportFullH || 0;
    // No box height yet — fall back to whatever the current layout reports.
    if (full <= 0) return container.scrollHeight - container.clientHeight;
    return Math.max(0, contentHeight + this._bottomInsetPx - full);
  }

  // Eases scrollTop to [target] over one keyboard beat instead of snapping it,
  // so the list travels with the rising input bar rather than teleporting when
  // Flutter pushes the settled inset. Retargetable: a call mid-flight re-aims
  // from the current offset, so the keyboard's rise and its settle correction
  // read as one continuous follow instead of a staircase of jumps.
  _glideScrollTo(container, target) {
    cancelAnimationFrame(this._repinRaf);
    const start = container.scrollTop;
    const delta = target - start;
    if (Math.abs(delta) < 1) {
      container.scrollTop = target;
      this._repinAnimating = false;
      this._finishRepin(container);
      return;
    }

    // Matches the Flutter input bar's easeOutCubic beat so the chat and the
    // input pill travel together.
    const duration = 240;
    const t0 = performance.now();
    this._repinAnimating = true;
    const step = (now) => {
      const p = Math.min(1, (now - t0) / duration);
      container.scrollTop = start + delta * (1 - Math.pow(1 - p, 3));
      if (p < 1) {
        this._repinRaf = requestAnimationFrame(step);
        return;
      }
      this._repinAnimating = false;
      this._finishRepin(container);
    };
    this._repinRaf = requestAnimationFrame(step);
  }

  _finishRepin(container) {
    // The list has landed; let any held-back reduction settle behind it.
    const target = this._targetBottomPadding();
    const applied = parseFloat(container.style.paddingBottom) || 0;
    if (target > applied) {
      container.style.paddingBottom = target + 'px';
    } else if (target < applied - 0.1) {
      this._scheduleShrink(container);
    }

    const vl = this.virtualList;
    clearTimeout(this._bottomPadUnlockTimer);
    this._bottomPadUnlockTimer = setTimeout(() => {
      if (vl) vl.isProgrammaticScrolling = false;
    }, 60);
    requestAnimationFrame(() => {
      const distanceFromBottom =
        container.scrollHeight - container.scrollTop - container.clientHeight;
      this._sendToFlutter('onScrollToBottomVisibility', [distanceFromBottom > 100]);
    });
  }

  setTopPadding(px) {
    const container = document.getElementById('chat-container') || document.body;
    container.style.paddingTop = px + 'px';
  }

  /* ---------- Overlay blur regions (Flutter glass over the WebView) ----------
   * Flutter's BackdropFilter cannot sample the platform view, so the header /
   * input-bar glass widgets can't blur the messages scrolling under them.
   * Flutter mirrors their rects here; each region becomes a fixed
   * backdrop-filter strip that blurs the page content (the messages) while the
   * global background stays on the Flutter side (the page is transparent, so
   * there is nothing else to blur). No tint/noise — those stay in Flutter. */
  setOverlayBlurRegions(regions) {
    let parsed;
    try {
      parsed = typeof regions === 'string' ? JSON.parse(regions) : regions;
    } catch (_) {
      parsed = [];
    }
    this._overlayBlurRegions = Array.isArray(parsed) ? parsed : [];
    this._renderOverlayBlurRegions();
  }

  _renderOverlayBlurRegions() {
    const regions = this.batterySaver ? [] : (this._overlayBlurRegions || []);
    let layer = document.getElementById('overlay-blur-layer');
    if (regions.length === 0) {
      if (layer) layer.remove();
      return;
    }
    if (!layer) {
      layer = document.createElement('div');
      layer.id = 'overlay-blur-layer';
      document.body.appendChild(layer);
    }
    const seen = new Set();
    for (const r of regions) {
      if (!r || r.id == null) continue;
      const id = String(r.id);
      seen.add(id);
      let el = layer.querySelector(`[data-region-id="${CSS.escape(id)}"]`);
      if (!el) {
        el = document.createElement('div');
        el.className = 'overlay-blur-region';
        el.dataset.regionId = id;
        layer.appendChild(el);
      }
      el.style.left = (r.x || 0) + 'px';
      el.style.top = (r.y || 0) + 'px';
      el.style.width = (r.w || 0) + 'px';
      el.style.height = (r.h || 0) + 'px';
      el.style.borderRadius = (r.r || 0) + 'px';
    }
    for (const el of Array.from(layer.children)) {
      if (!seen.has(el.dataset.regionId)) el.remove();
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
    // Re-run cleaner is a Studio-only affordance — hide it when Studio is off.
    container.classList.toggle('hide-rerun-cleaner', !s.studioEnabled);
    // Battery saver kills the overlay backdrop-filter strips too.
    this._renderOverlayBlurRegions();
  }

  setAllowMessageScripts(enabled) {
    const previous = this.renderer.allowMessageScripts;
    this.renderer.allowMessageScripts = enabled === true;
    // Apply the new policy to what is already on screen: enabling runs the
    // scripts of the messages the user is looking at, disabling re-inserts
    // their sanitized form.
    if (this.renderer.allowMessageScripts !== previous) {
      this.renderer.rerenderMessageBodies();
    }
  }

  /**
   * Called by the renderer when a message carried a `<script>` while message
   * script execution is off. Reported to Flutter once per WebView load — the
   * app then offers to enable execution, and its answer is persisted there.
   */
  notifyMessageScriptBlocked() {
    if (this._messageScriptBlockedNotified) return;
    this._messageScriptBlockedNotified = true;
    this._sendToFlutter('onMessageScriptBlocked', []);
  }

  /* ---------- Inline edit (toggle into .msg-body) ---------- */
  startEdit(messageId) {
    this._editController.startEdit(messageId, (pos) => {
      if (pos !== undefined) this.virtualList.container.scrollTop = pos;
      return this.virtualList.container.scrollTop;
    });
    // After the textarea/footer have been swapped in (and the prior scroll
    // position restored by the controller), smoothly bring the top of the
    // edited message into view so the user starts editing from its beginning.
    this._scrollMessageToTop(messageId);
  }

  // Smoothly scroll so the top of [messageId] lands just below the translucent
  // header. The container carries a dynamic `padding-top` (header inset, see
  // setTopPadding), so we subtract it to avoid the message hiding behind it.
  _scrollMessageToTop(messageId) {
    const container = this.virtualList?.container;
    if (!container) return;
    requestAnimationFrame(() => {
      const section = document.querySelector(`[data-message-id="${messageId}"]`);
      if (!section || !container.isConnected) return;
      const cRect = container.getBoundingClientRect();
      const sRect = section.getBoundingClientRect();
      const padTop = parseFloat(getComputedStyle(container).paddingTop) || 0;
      const target = container.scrollTop + (sRect.top - cRect.top) - padTop - 8;
      this.virtualList.isProgrammaticScrolling = true;
      container.scrollTo({ top: Math.max(0, target), behavior: 'smooth' });
      setTimeout(() => {
        this.virtualList.isProgrammaticScrolling = false;
        // Re-sync the render window to the resting scroll position (scroll
        // events fired during the animation were gated out above).
        if (typeof this.virtualList.updateWindow === 'function') {
          this.virtualList.updateWindow();
        }
      }, 500);
    });
  }

  stopEdit(messageId) {
    this._editController.stopEdit(messageId);
  }

  setBackgroundImage(url, blur) {
    // Duplicate the app background inside the WebView so its own
    // backdrop-filter blur regions have real pixels to sample — CSS
    // backdrop-filter can't see the natively-composited Flutter layer
    // behind the transparent WebView. Flutter keeps painting the same
    // background underneath as a fallback; this opaque copy sits on top.
    //
    // The bg blur must be BAKED into the image (offscreen canvas), not a
    // live `filter: blur()` on #bg-layer: a CSS filter turns the element
    // into a backdrop root (isolated composited layer), which excludes it
    // from every sibling backdrop-filter's sampling set — the overlay-blur
    // strips under the Flutter glass and the bubbles' element-blur would
    // silently go flat whenever bg blur is enabled.
    let bg = document.getElementById('bg-layer');
    if (!url) {
      this._bgBlurToken = null;
      if (bg) {
        bg.style.display = 'none';
        bg.style.backgroundImage = '';
      }
      return;
    }
    if (!bg) {
      bg = document.createElement('div');
      bg.id = 'bg-layer';
      document.body.insertBefore(bg, document.body.firstChild);
    }
    bg.style.display = 'block';
    // The layer stays fully opaque: darkening is the `--bg-dim` overlay in
    // #bg-layer::after. Fading the layer itself would let the transparent
    // WebView show the Flutter background painted behind it.
    bg.style.opacity = '';

    const b = Math.max(0, Number(blur) || 0);
    if (b <= 0) {
      this._bgBlurToken = null;
      bg.style.backgroundImage = `url("${url}")`;
      bg.style.filter = '';
      bg.style.inset = '0';
      return;
    }

    const cacheKey = `${b}|${url}`;
    if (this._bgBlurCache && this._bgBlurCache.key === cacheKey) {
      this._bgBlurToken = null;
      this._applyPreBlurredBg(bg, this._bgBlurCache.dataUrl);
      return;
    }

    // Immediate placeholder while the canvas render is in flight — and the
    // permanent fallback when canvas 2D filters are unsupported. CSS blur on
    // an inset:0 layer bleeds transparent (darkened) edges, unlike Flutter's
    // TileMode.clamp; overscan so the fringe falls outside the viewport.
    bg.style.backgroundImage = `url("${url}")`;
    bg.style.filter = `blur(${b}px)`;
    bg.style.inset = `-${b * 2}px`;

    const token = cacheKey;
    this._bgBlurToken = token;
    this._preBlurImage(url, b).then((dataUrl) => {
      if (!dataUrl) return; // canvas filter unsupported/failed → keep fallback
      this._bgBlurCache = { key: cacheKey, dataUrl };
      if (this._bgBlurToken !== token) return; // superseded by a newer call
      const layer = document.getElementById('bg-layer');
      if (!layer || layer.style.display === 'none') return;
      this._applyPreBlurredBg(layer, dataUrl);
    });
  }

  // Swap #bg-layer to the pre-blurred image with no live CSS filter.
  // #bg-layer transitions `filter` 0.3s; suppress it for the swap so the
  // baked blur + decaying live blur don't visibly stack.
  _applyPreBlurredBg(layer, dataUrl) {
    const prevTransition = layer.style.transition;
    layer.style.transition = 'none';
    layer.style.backgroundImage = `url("${dataUrl}")`;
    layer.style.filter = '';
    layer.style.inset = '0';
    void layer.offsetWidth; // flush so the un-transitioned state commits
    layer.style.transition = prevTransition;
  }

  // Renders [url] blurred into an offscreen canvas, once, at a capped working
  // resolution. Resolves to a data URL, or null when canvas 2D filters are
  // unavailable (older WKWebView) or the render fails — callers keep the live
  // CSS-filter fallback in that case.
  _preBlurImage(url, blur) {
    return new Promise((resolve) => {
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');
      if (!ctx || typeof ctx.filter !== 'string') {
        resolve(null);
        return;
      }
      const img = new Image();
      img.onload = () => {
        try {
          const iw = img.naturalWidth;
          const ih = img.naturalHeight;
          if (!iw || !ih) {
            resolve(null);
            return;
          }
          // The blur destroys detail anyway, so a capped resolution keeps
          // the canvas + data URL small; scale the radius to match.
          const scale = Math.min(1, 1536 / Math.max(iw, ih));
          const scaledBlur = Math.max(0.5, blur * scale);
          canvas.width = Math.max(1, Math.round(iw * scale));
          canvas.height = Math.max(1, Math.round(ih * scale));
          // Overscan: draw expanded by 2×blur per side so the transparent
          // blurred fringe lands outside the canvas and edges stay clamped
          // (Flutter TileMode.clamp equivalent), at the cost of a slight
          // zoom-crop.
          const pad = Math.ceil(scaledBlur * 2);
          ctx.filter = `blur(${scaledBlur}px)`;
          ctx.drawImage(
            img,
            -pad,
            -pad,
            canvas.width + pad * 2,
            canvas.height + pad * 2,
          );
          // WebP keeps the alpha channel (PNG wallpapers) unlike JPEG;
          // engines without a WebP encoder silently return PNG instead.
          resolve(canvas.toDataURL('image/webp', 0.9));
        } catch (_) {
          resolve(null);
        }
      };
      img.onerror = () => resolve(null);
      img.src = url;
    });
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

  // Ordered list of real message ids (top → bottom), excluding date separators.
  // Range selection needs the full order even for messages currently outside
  // the virtual-scroll render window, so it reads from the complete backing
  // item order rather than the DOM.
  _orderedMessageIds() {
    const list = this.virtualList;
    const order = Array.isArray(list?.items)
      ? list.items.map(item => item.id)
      : (list?.messageOrder || []);
    return order.filter(id => typeof id === 'string' && !id.startsWith('__date_'));
  }

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

      // Pending entries are preset placeholders and have no persisted row yet.
      if (block.id) {
        const editBtn = document.createElement('button');
        editBtn.type = 'button';
        editBtn.className = 'ext-block-btn ext-block-btn-icon';
        editBtn.dataset.action = 'ext-block-edit';
        editBtn.dataset.blockId = block.blockId;
        editBtn.dataset.messageId = messageId;
        editBtn.title = 'Редактировать';
        editBtn.textContent = '✎';
        btnGroup.appendChild(editBtn);

        const deleteBtn = document.createElement('button');
        deleteBtn.type = 'button';
        deleteBtn.className = 'ext-block-btn ext-block-btn-icon ext-block-btn-danger';
        deleteBtn.dataset.action = 'ext-block-delete';
        deleteBtn.dataset.blockId = block.blockId;
        deleteBtn.dataset.messageId = messageId;
        deleteBtn.title = 'Удалить';
        deleteBtn.textContent = '✕';
        btnGroup.appendChild(deleteBtn);
      }

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
    // loading="eager" (not "lazy"): the ext-block panel hangs off the last
    // assistant message, i.e. at the very bottom edge of the WebView next to
    // the input bar. On iOS WKWebView, lazy images that close to the viewport
    // edge get unloaded/reloaded as the keyboard + input pill resize the
    // viewport while typing — the image blinks, and because .ext-block-image
    // has no reserved height the whole block collapses and re-expands
    // ("opens and closes"). These are already-generated local files, so eager
    // loading costs nothing and keeps the image pinned.
    return `<span class="ext-block-image-wrapper img-result-wrapper"><img src="${src}" class="ext-block-image" loading="eager" decoding="sync" data-action="image-click" data-src="${src}"><button class="img-download-btn" data-action="img-download" data-src="${src}" title="Save image">⤓</button></span>`;
  }

  /**
   * Rewrites the stored `<img data-iig-…>` form of a finished image block into
   * the `[IMG:RESULT:…]` token this panel already renders — with the download
   * button and the viewer action the bare element would not carry. Purely a
   * render-time normalization; the block's stored content is untouched.
   */
  _extBlockLegacyImageTokens(content) {
    const text = String(content == null ? '' : content);
    if (text.indexOf('data-iig-instruction') === -1) return text;
    return text.replace(
      /<img\s[^>]*?data-iig-instruction\s*=\s*(?:"[^"]*"|'[^']*')[^>]*>/gi,
      (tag) => {
        const parsed = parseImageResultElement(tag);
        if (!parsed) return tag;
        const src = parsed.paths[parsed.activeIndex] || parsed.paths[0] || '';
        return src ? `[IMG:RESULT:${src}]` : tag;
      },
    );
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

    const content = this._extBlockLegacyImageTokens(block.content);
    const imgResultRegex = /\[IMG:RESULT:([^\]]+)\]/;
    const hasImgResult = imgResultRegex.test(content);
    const hasHtmlMarkup = /<[a-z][\s\S]*>/i.test(content);

    if (hasImgResult && hasHtmlMarkup) {
      let html = content.replace(
        /\[IMG:RESULT:([^\]]+)\]/g,
        (match, payload) => this._renderExtBlockImageHtml(payload),
      );
      const htmlEl = document.createElement('div');
      htmlEl.className = 'ext-block-content';
      htmlEl.innerHTML = sanitizeExtBlockHtml(html);
      body.appendChild(htmlEl);
    } else if (hasImgResult) {
      const imgMatch = content.match(imgResultRegex);
      const wrapper = document.createElement('span');
      wrapper.innerHTML = sanitizeExtBlockHtml(this._renderExtBlockImageHtml(imgMatch[1]));
      body.appendChild(wrapper.firstElementChild);
    } else {
      const html = document.createElement('div');
      html.className = 'ext-block-content';
      html.innerHTML = sanitizeExtBlockHtml(content);
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
