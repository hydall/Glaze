/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

import { appBody } from '../renderer/message_document.js';

export class SelectionManager {
  constructor(sendToFlutter, getOrderedIds) {
    this._sendToFlutter = sendToFlutter;
    // Returns all real message ids in display order (top → bottom). Injected so
    // range selection can reach messages outside the virtual-scroll window.
    this._getOrderedIds = typeof getOrderedIds === 'function' ? getOrderedIds : () => [];
    this._selectionMode = false;
    this._selectedIds = new Set();
    // Last message the user tapped. The "select everything above / below"
    // toolbar buttons are relative to it, so it survives that message being
    // toggled back off.
    this._lastTappedId = null;
    this._selectedText = '';
    this._barCreated = false;
  }

  get selectionMode() { return this._selectionMode; }

  getSelectedIds() { return [...this._selectedIds]; }

  setSelectionMode(enabled) {
    if (enabled && document.querySelector('.message-section.editing')) return;
    this._selectionMode = !!enabled;
    if (!enabled) {
      this._selectedIds.clear();
      this._lastTappedId = null;
    }
    document.querySelectorAll('.message-section').forEach(msgEl => {
      msgEl.classList.toggle('selection-mode', this._selectionMode);
      msgEl.classList.toggle('selected', this._selectedIds.has(msgEl.dataset.messageId));
    });
  }

  toggleMessageSelection(messageId) {
    this._toggleTapped(messageId);
  }

  // Selects only [messageId] and makes it the anchor for the above/below
  // toolbar buttons.
  selectOnly(messageId) {
    this._selectedIds = new Set([messageId]);
    this._lastTappedId = messageId;
    this._applySelectionClasses();
  }

  // Toggles one message and remembers it as the anchor. Used by every tap in
  // selection mode: a tap only ever affects the message under the finger.
  _toggleTapped(messageId) {
    this._lastTappedId = messageId;
    if (this._selectedIds.has(messageId)) this._selectedIds.delete(messageId);
    else this._selectedIds.add(messageId);
    this._applySelectionClasses();
  }

  // Anchor for the above/below buttons: the last tapped message, falling back
  // to the outermost selected message on that side if the anchor is gone
  // (deleted, or a session switch dropped it from the order).
  _rangeAnchor(order, below) {
    if (this._lastTappedId && order.includes(this._lastTappedId)) {
      return this._lastTappedId;
    }
    const candidates = order.filter(id => this._selectedIds.has(id));
    if (candidates.length === 0) return null;
    return below ? candidates[candidates.length - 1] : candidates[0];
  }

  // Selects every message above (below === false) or below (below === true) the
  // anchor, exclusive. Pressing again while that whole run is already selected
  // deselects it, so the button toggles.
  _selectSide(below) {
    const order = this._getOrderedIds();
    const anchor = this._rangeAnchor(order, below);
    if (anchor == null) return;
    const idx = order.indexOf(anchor);
    if (idx < 0) return;
    const range = below ? order.slice(idx + 1) : order.slice(0, idx);
    if (range.length === 0) return;
    const allSelected = range.every(id => this._selectedIds.has(id));
    for (const id of range) {
      if (allSelected) this._selectedIds.delete(id);
      else this._selectedIds.add(id);
    }
    this._applySelectionClasses();
    this._sendToFlutter('onSelectionChange', [JSON.stringify(this.getSelectedIds())]);
    this.exitIfEmpty();
  }

  selectAbove() { this._selectSide(false); }

  selectBelow() { this._selectSide(true); }

  // Sync the `selected` class for sections currently in the DOM. Sections that
  // scroll into view later pick it up via applyClassesToSection().
  _applySelectionClasses() {
    document.querySelectorAll('.message-section').forEach(msgEl => {
      msgEl.classList.toggle('selected', this._selectedIds.has(msgEl.dataset.messageId));
    });
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
    // Plain toggle: a tap adds or removes exactly the tapped message.
    this._toggleTapped(id);
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
      this._toggleTapped(id);
      this._sendToFlutter('onSelectionChange', [JSON.stringify(this.getSelectedIds())]);
      this.exitIfEmpty();
    } else {
      if (document.querySelector('.message-section.editing')) return false;
      this.setSelectionMode(true);
      this.selectOnly(id);
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
    // appBody(), not document.body: this runs from a click that may have come
    // out of a message, where `document.body` is that message's overlay.
    appBody().appendChild(host);
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
      appBody().appendChild(bar);
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
