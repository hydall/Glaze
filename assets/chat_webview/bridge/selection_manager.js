/* Extracted from ../bridge.legacy.js. Keep public behavior stable. */

export class SelectionManager {
  constructor(sendToFlutter, getOrderedIds) {
    this._sendToFlutter = sendToFlutter;
    // Returns all real message ids in display order (top → bottom). Injected so
    // range selection can reach messages outside the virtual-scroll window.
    this._getOrderedIds = typeof getOrderedIds === 'function' ? getOrderedIds : () => [];
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

  // Selects [messageId … last message]: the tapped message plus every message
  // after it. Re-tapping always redefines the range from the newly tapped
  // message, so tapping a lower message after an upper one collapses the
  // selection down to that lower message and everything below it.
  selectRangeFrom(messageId) {
    const order = this._getOrderedIds();
    const idx = order.indexOf(messageId);
    const range = idx >= 0 ? order.slice(idx) : [messageId];
    this._selectedIds = new Set(range);
    this._applySelectionClasses();
  }

  // Topmost currently-selected id in display order (the range anchor), or null.
  _anchorId() {
    if (this._selectedIds.size === 0) return null;
    const order = this._getOrderedIds();
    for (const id of order) {
      if (this._selectedIds.has(id)) return id;
    }
    return null;
  }

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
    // Re-tapping the range anchor clears the whole selection (and exits mode);
    // any other tap redefines the range from the tapped message downward.
    if (id === this._anchorId()) {
      this._selectedIds.clear();
      this._applySelectionClasses();
    } else {
      this.selectRangeFrom(id);
    }
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
      if (id === this._anchorId()) {
        this._selectedIds.clear();
        this._applySelectionClasses();
      } else {
        this.selectRangeFrom(id);
      }
      this._sendToFlutter('onSelectionChange', [JSON.stringify(this.getSelectedIds())]);
      this.exitIfEmpty();
    } else {
      if (document.querySelector('.message-section.editing')) return false;
      this.setSelectionMode(true);
      this.selectRangeFrom(id);
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
