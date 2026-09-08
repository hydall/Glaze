/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

export class EditController {
  constructor(sendToFlutter) {
    this._sendToFlutter = sendToFlutter;
  }

  startEdit(messageId, scrollTopFn) {
    const section = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!section) return;

    // If the section is already in editing state (e.g. a rapid cancel
    // followed immediately by another startEdit, or Dart sent startEdit
    // twice), restore it first so that originalHtml is captured from
    // the rendered content, not from the textarea.
    if (section.classList.contains('editing')) {
      const prevBody = section.querySelector('.msg-body');
      if (prevBody && prevBody.dataset.originalHtml !== undefined) {
        prevBody.innerHTML = prevBody.dataset.originalHtml;
        delete prevBody.dataset.originalHtml;
      }
      const prevFooter = section.querySelector('.msg-footer');
      if (prevFooter && prevFooter.dataset.originalHtml !== undefined) {
        prevFooter.innerHTML = prevFooter.dataset.originalHtml;
        delete prevFooter.dataset.originalHtml;
      }
      section.classList.remove('editing');
    }

    const scrollPos = scrollTopFn();
    section.classList.add('editing');

    const rawText = (section.dataset.rawText || '').replace(/^<think\b[^>]*>[\s\S]*?<\/think>\s*/, '');
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
      const delta = this._scaledWheelDelta(e, textarea);
      const maxScrollTop = textarea.scrollHeight - textarea.clientHeight;
      const canScrollSelf = maxScrollTop > 1 && (
        (delta < 0 && textarea.scrollTop > 0) ||
        (delta > 0 && textarea.scrollTop < maxScrollTop - 1)
      );

      if (!canScrollSelf) {
        // Let the event bubble to #chat-container. The container's own wheel
        // handler applies the same WebView scale factor and scrolls the chat.
        return;
      }

      e.preventDefault();
      e.stopPropagation();
      textarea.scrollTop += delta;
    }, { passive: false });

    // Touch-drag over the textarea scrolls the whole chat. The textarea
    // auto-grows to fit its content (field-sizing: content, no max-height), so
    // it never scrolls itself vertically — a finger drag over it would
    // otherwise be swallowed by the native <textarea> (caret/selection) and do
    // nothing. When the textarea can't consume the vertical movement we drive
    // the chat container's scrollTop directly via scrollTopFn, matching the
    // wheel handler's "bubble to the chat" behavior for touch input.
    let touchStartY = 0;
    let touchLastY = 0;
    let touchLastT = 0;
    let touchVelocity = 0; // px/ms, finger direction (smoothed)
    let touchScrolling = false;
    let inertiaRAF = 0;

    const cancelInertia = () => {
      if (inertiaRAF) { cancelAnimationFrame(inertiaRAF); inertiaRAF = 0; }
    };

    textarea.addEventListener('touchstart', (e) => {
      if (e.touches.length !== 1) return;
      cancelInertia(); // a new touch grabs the scroll — stop any glide
      touchStartY = touchLastY = e.touches[0].clientY;
      touchLastT = performance.now();
      touchVelocity = 0;
      touchScrolling = false;
    }, { passive: true });
    textarea.addEventListener('touchmove', (e) => {
      if (e.touches.length !== 1) return;
      const y = e.touches[0].clientY;
      const dyTotal = y - touchStartY;
      const maxScrollTop = textarea.scrollHeight - textarea.clientHeight;
      // Finger down (dyTotal > 0) scrolls the content up → the textarea can
      // consume it only when it has hidden overflow above (scrollTop > 0).
      const canScrollSelf = maxScrollTop > 1 && (
        (dyTotal > 0 && textarea.scrollTop > 0) ||
        (dyTotal < 0 && textarea.scrollTop < maxScrollTop - 1)
      );
      if (canScrollSelf) return; // let the textarea scroll its own overflow

      // Below the threshold the gesture might still settle into a tap (caret
      // placement / selection), so don't hijack it yet.
      if (!touchScrolling && Math.abs(dyTotal) < 6) return;
      touchScrolling = true;

      const now = performance.now();
      const dy = y - touchLastY;
      const dt = now - touchLastT;
      // Weighted-average the velocity so the release value reflects the last
      // moments of the drag without a single jittery sample dominating.
      if (dt > 0) touchVelocity = touchVelocity * 0.2 + (dy / dt) * 0.8;
      touchLastY = y;
      touchLastT = now;
      e.preventDefault();
      e.stopPropagation();
      scrollTopFn(scrollTopFn() - dy);
    }, { passive: false });
    // After the finger lifts, keep the chat gliding with a decaying velocity so
    // the drag has the momentum users expect instead of stopping dead — the
    // manual scrollTop drive above has no native inertia of its own.
    const onTouchEnd = () => {
      const wasScrolling = touchScrolling;
      touchScrolling = false;
      if (!wasScrolling || Math.abs(touchVelocity) < 0.05) return;
      let v = touchVelocity; // px/ms
      let lastT = performance.now();
      const step = (now) => {
        const dt = now - lastT;
        lastT = now;
        v *= Math.pow(0.95, dt / 16.67); // ~5% decay per 60fps frame (~1s glide)
        if (Math.abs(v) < 0.02) { inertiaRAF = 0; return; }
        const before = scrollTopFn();
        const after = scrollTopFn(before - v * dt);
        if (Math.abs(after - before) < 0.5) { inertiaRAF = 0; return; } // hit an edge
        inertiaRAF = requestAnimationFrame(step);
      };
      inertiaRAF = requestAnimationFrame(step);
    };
    textarea.addEventListener('touchend', onTouchEnd, { passive: true });
    textarea.addEventListener('touchcancel', () => {
      touchScrolling = false;
      cancelInertia();
    }, { passive: true });

    const stopEditEventPropagation = (e) => e.stopPropagation();
    textarea.addEventListener('pointerdown', stopEditEventPropagation);
    textarea.addEventListener('mousedown', stopEditEventPropagation);
    textarea.addEventListener('click', stopEditEventPropagation);
    textarea.addEventListener('dblclick', stopEditEventPropagation);
    textarea.addEventListener('focus', () => {
      this._sendToFlutter('onEditFocusChange', [messageId, true]);
    });
    textarea.addEventListener('blur', () => {
      this._sendToFlutter('onEditFocusChange', [messageId, false]);
    });

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

    // Do NOT restore from originalHtml — innerHTML does not serialise shadow
    // roots, so the snapshot captured in startEdit() is always empty for
    // shadow-DOM-hosted content.  Instead, re-render the body from the
    // authoritative rawText / reasoning stored on the section dataset.
    // This works for both Cancel (rawText unchanged) and Save (Dart updates
    // rawText via updateMessage before calling stopEdit).
    const body = section.querySelector('.msg-body');
    if (body) {
      delete body.dataset.originalHtml;   // discard stale snapshot
      if (window.bridge?.renderer) {
        const isUser = section.classList.contains('user');
        window.bridge.renderer.updateMessageContent(
          section,
          section.dataset.rawText || '',
          section.dataset.reasoning || null,
          isUser, false, false,
        );
      }
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

  _scaledWheelDelta(e, textarea) {
    if (e.deltaMode === 0) return e.deltaY * 0.3;
    if (e.deltaMode === 1) return e.deltaY * 16;
    return e.deltaY * textarea.clientHeight;
  }
}
