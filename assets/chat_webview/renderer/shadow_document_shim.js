// `document` lookups for the JS a message writes.
//
// A message body is rendered into a per-message shadow root
// (`.message-content`), and `document.getElementById` / `document.querySelector`
// never see inside one. ST-style cards are written against a document: the
// script defines `function toggle(id){ document.getElementById('body'+id) … }`
// and the markup calls it back from an `onclick=` handler. Both halves miss the
// card by default — the lookup returns `null`, and the button does nothing.
//
// The shim keeps the card's own code in charge and only widens where a lookup
// looks, in this order:
//
//   1. the scope the call belongs to — the message root whose script is running
//      (`runInMessageScope`), or the root of the element an event is being
//      dispatched to, so a card that is on screen twice answers for the copy
//      that was clicked;
//   2. the real document, so nothing the app itself looks up changes meaning;
//   3. every message shadow root in document order, which is what a deferred
//      call (a `setTimeout` inside a card, a handler bound at render time)
//      falls back to.
//
// Installed lazily by `executeInlineScripts`, so a chat that never runs message
// JS keeps the untouched `document` methods.

/** Hosts of the shadow roots message bodies are written into. */
const MESSAGE_HOST_SELECTOR = '.message-content';

/** Events whose inline handlers a card wires up (`onclick=` and friends). */
const SCOPE_EVENTS = ['pointerdown', 'click', 'change', 'input'];

const native = {
  getElementById: null,
  querySelector: null,
  querySelectorAll: null,
};

let installed = false;
let activeScope = null;
let releaseHandle = 0;

/**
 * Runs [run] with [scope] as the root every `document` lookup consults first.
 * Nested calls restore the scope they replaced, so a render triggered from
 * inside a card's script cannot leave the wrong root behind.
 */
export function runInMessageScope(scope, run) {
  const previous = activeScope;
  activeScope = scope || null;
  try {
    return run();
  } finally {
    activeScope = previous;
  }
}

export function installShadowDocumentShim() {
  if (installed) return;
  installed = true;

  native.getElementById = document.getElementById.bind(document);
  native.querySelector = document.querySelector.bind(document);
  native.querySelectorAll = document.querySelectorAll.bind(document);

  document.getElementById = function (id) {
    const selector = escapeId(id);
    if (!selector) return native.getElementById(id);
    const inScope = queryIn(activeScope, selector);
    if (inScope) return inScope;
    const inDocument = native.getElementById(id);
    if (inDocument) return inDocument;
    return firstInMessageRoots(selector);
  };

  document.querySelector = function (selector) {
    const inScope = queryIn(activeScope, selector);
    if (inScope) return inScope;
    // An invalid selector throws out of the native call, as it always has.
    const inDocument = native.querySelector(selector);
    if (inDocument) return inDocument;
    return firstInMessageRoots(selector);
  };

  document.querySelectorAll = function (selector) {
    const inScope = queryAllIn(activeScope, selector);
    if (inScope && inScope.length) return inScope;
    const inDocument = native.querySelectorAll(selector);
    if (inDocument.length) return inDocument;
    return allInMessageRoots(selector) || inDocument;
  };

  // The scope of an inline handler is decided before it runs: a capture-phase
  // listener on the document sees the click first, the `onclick=` attribute
  // runs at the target, and the timeout releases the scope once the whole
  // dispatch is over (a handler that stops propagation cannot skip it).
  for (const type of SCOPE_EVENTS) {
    document.addEventListener(type, captureScope, true);
  }
}

function captureScope(event) {
  const path = (event.composedPath && event.composedPath()) || [];
  const target = path[0] || event.target;
  const root = target && target.getRootNode ? target.getRootNode() : null;
  activeScope = root && root.nodeType === 11 && root.host ? root : null;
  if (releaseHandle) clearTimeout(releaseHandle);
  releaseHandle = setTimeout(() => {
    releaseHandle = 0;
    activeScope = null;
  }, 0);
}

function escapeId(id) {
  try {
    return `#${CSS.escape(String(id))}`;
  } catch (_) {
    return null;
  }
}

function queryIn(scope, selector) {
  if (!scope || !scope.querySelector) return null;
  try {
    return scope.querySelector(selector);
  } catch (_) {
    return null;
  }
}

function queryAllIn(scope, selector) {
  if (!scope || !scope.querySelectorAll) return null;
  try {
    return scope.querySelectorAll(selector);
  } catch (_) {
    return null;
  }
}

/** Every message shadow root, in document order. */
function messageRoots() {
  const roots = [];
  for (const host of native.querySelectorAll(MESSAGE_HOST_SELECTOR)) {
    if (host.shadowRoot) roots.push(host.shadowRoot);
  }
  return roots;
}

function firstInMessageRoots(selector) {
  for (const root of messageRoots()) {
    const hit = queryIn(root, selector);
    if (hit) return hit;
  }
  return null;
}

function allInMessageRoots(selector) {
  for (const root of messageRoots()) {
    const hits = queryAllIn(root, selector);
    if (hits && hits.length) return hits;
  }
  return null;
}
