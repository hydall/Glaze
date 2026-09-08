/* ============================================================
 * RollingNumber — 1:1 port of Glaze/src/components/ui/RollingNumber.vue
 *
 * DOM mirrors the Vue template:
 *   .rolling-number
 *     .rolling-number-inner          (acts as Vue's <transition-group>)
 *       .rolling-column[.is-symbol]  (one per character; keyed by position from right)
 *         .symbol                    (when char is non-numeric)
 *         OR
 *         .digit-container
 *           .digit-measure ("0")    (sets width)
 *           .digit (current value)  (animated via slide-digit / slide-digit-fast)
 *
 * Animations are class-driven, matching the names from RollingNumber.vue's
 * <style scoped> block so the existing CSS in styles.css drives them.
 * ============================================================ */

class RollingNumber {
  constructor(initialValue = '') {
    this.el = document.createElement('div');
    this.el.className = 'rolling-number';
    this.inner = document.createElement('div');
    this.inner.className = 'rolling-number-inner';
    this.el.appendChild(this.inner);
    this.columns = new Map();
    if (initialValue !== '') this.setValue(initialValue);
  }

  setValue(newValue) {
    const str = String(newValue);

    // Battery-saver bypass: no animations at all.
    if (window.bridge && window.bridge.batterySaver) {
      if (this.columns.size > 0) {
        for (const [, colState] of this.columns) {
          if (colState.el && colState.el.parentNode) {
            colState.el.parentNode.removeChild(colState.el);
          }
        }
        this.columns.clear();
      }
      this.inner.textContent = str;
      return;
    }
    // Recovering from text-mode (battery saver was on): clear stray text node.
    if (this.columns.size === 0 && this.inner.firstChild) {
      this.inner.textContent = '';
    }

    // Compute target columns (mirrors the Vue computed property).
    const newCols = [];
    let isDecimal = false;
    for (let i = 0; i < str.length; i++) {
      const char = str[i];
      if (char === '.' || char === ',') isDecimal = true;
      const isSymbol = isNaN(char) || char === ' ';
      newCols.push({
        id: `pos-${str.length - i}`,
        value: char,
        isFast: isDecimal && !isSymbol,
        isSymbol,
      });
    }

    // 1) Remove columns that no longer exist (Vue's transition-group leave).
    const newIds = new Set(newCols.map(c => c.id));
    for (const [id, colState] of this.columns) {
      if (!newIds.has(id)) {
        this._leaveColumn(colState);
        this.columns.delete(id);
      }
    }

    // 2) Add / update columns in target order.
    let prevEl = null;
    for (const colData of newCols) {
      let colState = this.columns.get(colData.id);
      if (!colState) {
        colState = this._createColumn(colData);
        this.columns.set(colData.id, colState);
        this._enterColumn(colState.el);
      } else if (colState.value !== colData.value) {
        this._swapDigit(colState, colData);
      }
      // Maintain visual order (positions can shift when digits change place).
      const after = prevEl ? prevEl.nextSibling : this.inner.firstChild;
      if (colState.el !== after) {
        this.inner.insertBefore(colState.el, after);
      }
      prevEl = colState.el;
    }
  }

  /* ---------- Column lifecycle ---------- */

  _createColumn(colData) {
    const el = document.createElement('div');
    el.className = 'rolling-column';
    if (colData.isSymbol) el.classList.add('is-symbol');

    let digitContainer = null;
    if (colData.isSymbol) {
      const sym = document.createElement('div');
      sym.className = 'symbol';
      sym.textContent = colData.value;
      el.appendChild(sym);
    } else {
      digitContainer = document.createElement('div');
      digitContainer.className = 'digit-container';
      const measure = document.createElement('div');
      measure.className = 'digit-measure';
      measure.textContent = '0';
      digitContainer.appendChild(measure);
      const digit = document.createElement('div');
      digit.className = 'digit';
      digit.textContent = colData.value;
      digitContainer.appendChild(digit);
      el.appendChild(digitContainer);
    }

    return { el, digitContainer, value: colData.value, isSymbol: colData.isSymbol };
  }

  _enterColumn(el) {
    // Vue: column-enter-from → column-enter-active → (next frame) drop from
    el.classList.add('column-enter-from', 'column-enter-active');
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        el.classList.remove('column-enter-from');
      });
    });
    this._onTransitionDone(el, 250, () => {
      el.classList.remove('column-enter-active');
    });
  }

  _leaveColumn(colState) {
    const el = colState.el;
    el.classList.add('column-leave-active');
    // Force a layout read so the browser registers the current width before
    // we collapse it via column-leave-to.
    void el.offsetWidth;
    requestAnimationFrame(() => {
      el.classList.add('column-leave-to');
    });
    this._onTransitionDone(el, 250, () => {
      if (el.parentNode) el.parentNode.removeChild(el);
    });
  }

  _swapDigit(colState, colData) {
    if (colState.isSymbol) {
      const sym = colState.el.querySelector('.symbol');
      if (sym) sym.textContent = colData.value;
      colState.value = colData.value;
      return;
    }

    const container = colState.digitContainer;
    if (!container) return;

    const enterName = colData.isFast ? 'slide-digit-fast' : 'slide-digit';

    // Leave: mark current .digit(:not(.leaving)) as leaving and animate out.
    const oldDigit = container.querySelector('.digit:not(.leaving)');
    if (oldDigit) {
      oldDigit.classList.add('leaving');
      oldDigit.classList.add(`${enterName}-leave-active`, `${enterName}-leave-from`);
      void oldDigit.offsetWidth;
      requestAnimationFrame(() => {
        oldDigit.classList.remove(`${enterName}-leave-from`);
        oldDigit.classList.add(`${enterName}-leave-to`);
      });
      this._onTransitionDone(oldDigit, colData.isFast ? 80 : 250, () => {
        if (oldDigit.parentNode) oldDigit.parentNode.removeChild(oldDigit);
      });
    }

    // Enter: new digit appears from below and slides to natural position.
    const newDigit = document.createElement('div');
    newDigit.className = 'digit';
    newDigit.textContent = colData.value;
    newDigit.classList.add(`${enterName}-enter-active`, `${enterName}-enter-from`);
    container.appendChild(newDigit);
    void newDigit.offsetWidth;
    requestAnimationFrame(() => {
      newDigit.classList.remove(`${enterName}-enter-from`);
      newDigit.classList.add(`${enterName}-enter-to`);
    });
    this._onTransitionDone(newDigit, colData.isFast ? 80 : 250, () => {
      newDigit.classList.remove(
        `${enterName}-enter-active`,
        `${enterName}-enter-to`,
      );
    });

    colState.value = colData.value;
  }

  _onTransitionDone(el, fallbackMs, fn) {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      el.removeEventListener('transitionend', onEnd);
      fn();
    };
    const onEnd = (e) => {
      if (e.target !== el) return;
      finish();
    };
    el.addEventListener('transitionend', onEnd);
    setTimeout(finish, fallbackMs);
  }
}
