// The document a message body gets.
//
// A message renders into a shadow root (`.message-content`), which is what
// keeps a card's CSS out of the app chrome. Cards, though, are written against
// a *document*: they look elements up with `document.getElementById`, declare
// functions a `onclick=` attribute calls, wait for `DOMContentLoaded`, and put
// a modal in `document.body`. None of that works inside a shadow root on its
// own, and for a while each case was discovered by a user and patched one at
// a time.
//
// This module is the whole list, in one place. What a card may rely on is
// written down in docs/INVARIANTS.md § Message document contract
// (INV-MR1…INV-MR8); every item here has a case in test/webview_js. Add to
// the contract rather than shimming one more thing where it happens to help.

import { rewriteTargetSelectors } from './target_toggle.js';

/** Events during which a message's own code may run and query the document. */
const SCOPED_EVENTS = [
  'click', 'dblclick', 'pointerdown', 'pointerup', 'mousedown', 'mouseup',
  'input', 'change', 'submit', 'keydown', 'keyup', 'toggle',
  'transitionend', 'animationend',
];

/** Load events a card waits for, which the real document fired long ago. */
const READY_EVENTS = new Set(['DOMContentLoaded', 'load', 'readystatechange']);

/** Where `document.body.appendChild` puts a node — inside the message. */
const OVERLAY_CLASS = 'glaze-message-overlay';

// Captured before anything can shim `document.head`, which the scope below
// points at the message root: a <script> appended to a shadow root never runs.
const REAL_HEAD = document.head || document.documentElement;
const REAL_BODY = document.body || document.documentElement;

/**
 * The app's own body, for chrome that must land outside a message.
 *
 * While a message's code runs — its `<script>`, and any handler it fires —
 * `document.body` is the message's overlay layer (INV-MR6). App code that
 * appends chrome during such an event (the selection bar, a measuring host)
 * has to say so, or its element ends up inside somebody's card.
 */
export function appBody() {
  return REAL_BODY;
}

function escapeSelector(value) {
  const text = String(value == null ? '' : value);
  if (typeof CSS !== 'undefined' && CSS.escape) return CSS.escape(text);
  return text.replace(/["\\\]]/g, '\\$&');
}

/**
 * The message's overlay layer: `display: contents`, so a node moved here lays
 * out exactly where `document.body.appendChild` would have put it — except
 * that it is still under the message's own stylesheet instead of naked in the
 * app chrome (INV-MR6).
 */
export function messageOverlay(root) {
  let layer = root.querySelector(`:scope > .${OVERLAY_CLASS}`);
  if (!layer) {
    layer = document.createElement('div');
    layer.className = OVERLAY_CLASS;
    root.appendChild(layer);
  }
  return layer;
}

/** The message root a DOM event passed through, or null for app chrome. */
function messageRootOf(event) {
  const path = (event.composedPath && event.composedPath()) || [];
  for (const node of path) {
    if (node && node.nodeType === 1 && node.classList &&
        node.classList.contains('glaze-message')) {
      return node;
    }
  }
  return null;
}

// Roots whose own code has actually run. A message with no `<script>` never
// needs the scope, and keeping it off for those means the app's document is
// untouched for all but a handful of messages.
const scripted = new WeakSet();

/** The root the scope is currently installed for, or null. */
let installed = null;

/**
 * Points the document's lookups at [root] for as long as the returned restore
 * has not been called. Everything is an own property on `document` / `window`,
 * so restoring is a delete and the originals are never rewritten.
 */
function installDocumentScope(root, collectReady) {
  if (installed) return () => {};
  const defined = [];
  const define = (target, name, descriptor) => {
    defined.push({ target, name });
    Object.defineProperty(target, name, { configurable: true, ...descriptor });
  };
  const method = (name, fn) => define(document, name, { value: fn, writable: true });

  const documentQuery = Document.prototype;
  const first = (selector) => {
    try {
      return root.querySelector(selector);
    } catch (_) {
      return null;
    }
  };
  const all = (selector) => {
    try {
      return root.querySelectorAll(selector);
    } catch (_) {
      return [];
    }
  };

  // INV-MR3: a lookup finds the message's own element first, and falls back to
  // the document so app-level code called from a card still works.
  method('getElementById', (id) =>
    first(`#${escapeSelector(id)}`) || documentQuery.getElementById.call(document, id));
  method('querySelector', (selector) =>
    first(selector) || documentQuery.querySelector.call(document, selector));
  method('querySelectorAll', (selector) => {
    const found = all(selector);
    return found.length ? found : documentQuery.querySelectorAll.call(document, selector);
  });
  method('getElementsByClassName', (name) =>
    all(String(name).trim().split(/\s+/).map((c) => `.${escapeSelector(c)}`).join('')));
  method('getElementsByTagName', (name) =>
    (String(name) === '*' ? all('*') : all(escapeSelector(name))));
  method('getElementsByName', (name) => all(`[name="${escapeSelector(name)}"]`));

  // INV-MR4: the document's collections are the message's own.
  define(document, 'forms', { get: () => all('form') });
  define(document, 'images', { get: () => all('img') });
  define(document, 'links', { get: () => all('a[href], area[href]') });
  define(document, 'styleSheets', {
    get: () => Array.from(all('style')).map((style) => style.sheet).filter(Boolean),
  });

  // INV-MR6: a node the card hands to the document lands in the message.
  define(document, 'body', { get: () => messageOverlay(root) });
  define(document, 'head', { get: () => root });

  // INV-MR7: the load events the card is waiting for are collected, not
  // registered — the real ones fired before the message existed.
  const documentAdd = document.addEventListener.bind(document);
  const windowAdd = window.addEventListener.bind(window);
  method('addEventListener', function (type, listener, options) {
    if (READY_EVENTS.has(type) && listener) {
      collectReady(listener);
      return;
    }
    documentAdd(type, listener, options);
  });
  define(window, 'addEventListener', {
    writable: true,
    value: function (type, listener, options) {
      if (READY_EVENTS.has(type) && listener) {
        collectReady(listener);
        return;
      }
      windowAdd(type, listener, options);
    },
  });
  define(window, 'onload', {
    get: () => null,
    set: (listener) => { if (listener) collectReady(listener); },
  });

  installed = root;
  return () => {
    if (installed !== root) return;
    installed = null;
    for (const { target, name } of defined) delete target[name];
  };
}

/**
 * Keeps the document scope in place for the length of an event dispatch, so a
 * card's `onclick` sees the same document its `<script>` saw. Installed once,
 * on the first message rendered.
 */
let bridged = false;
function installEventScope() {
  if (bridged) return;
  bridged = true;
  for (const type of SCOPED_EVENTS) {
    document.addEventListener(type, (event) => {
      const root = messageRootOf(event);
      if (!root || !scripted.has(root)) return;
      const restore = installDocumentScope(root, () => {});
      // The dispatch is one task: a microtask runs once it has finished
      // propagating. The timeout is only a backstop for a listener that
      // throws past the checkpoint.
      queueMicrotask(restore);
      setTimeout(restore, 0);
    }, true);
  }
}

/** Runs [source] in the page's global scope, so `function f(){}` becomes `f`. */
function runInGlobalScope(source) {
  // `new Function(src)()` gives the script a function scope of its own, so a
  // card that declares the handler its own `onclick=` calls left the attribute
  // pointing at nothing. A real <script> element executes synchronously, in
  // the global scope, and declares its globals.
  const element = document.createElement('script');
  element.textContent = source;
  REAL_HEAD.appendChild(element);
  element.remove();
}

/**
 * Runs a message's `<script>` blocks — or drops them, which is what the
 * message-scripts toggle turns off (nothing else about the message changes).
 */
export function runMessageScripts(root, allowMessageScripts = false) {
  const scripts = Array.from(root.querySelectorAll('script'));
  if (!allowMessageScripts) {
    scripts.forEach((script) => script.remove());
    return;
  }
  if (!scripts.length) return;

  const ready = [];
  scripted.add(root);
  const restoreScope = installDocumentScope(root, (listener) => ready.push(listener));
  // A script inserted this way reports a throw to window.onerror instead of to
  // the caller, and one broken card must not read as an app crash.
  const swallow = (event) => {
    console.error('Message script error:', event.message || event.error);
    event.preventDefault();
  };
  window.addEventListener('error', swallow, true);
  try {
    for (const script of scripts) {
      // ST-style cards read `document.currentScript.previousElementSibling` to
      // find the element they decorate; the real currentScript would be our
      // injected element, sitting in the document's head.
      const shim = {
        previousElementSibling: script.previousElementSibling,
        parentNode: script.parentNode,
      };
      Object.defineProperty(document, 'currentScript', {
        value: shim,
        configurable: true,
      });
      try {
        runInGlobalScope(script.textContent || '');
      } finally {
        delete document.currentScript;
      }
      script.remove();
    }
    for (const listener of ready) {
      try {
        listener.call(document, new Event('DOMContentLoaded'));
      } catch (e) {
        console.error('Message script error:', e);
      }
    }
  } finally {
    window.removeEventListener('error', swallow, true);
    restoreScope();
  }
}

/**
 * Gives a freshly written message body its document: `:target` re-keyed onto
 * the attribute the click dispatcher stamps, the scoped document installed for
 * later events, and the message's own scripts run.
 */
export function installMessageDocument(root, { allowMessageScripts = false } = {}) {
  if (!root) return;
  installEventScope();
  rewriteTargetSelectors(root);
  runMessageScripts(root, allowMessageScripts);
}
