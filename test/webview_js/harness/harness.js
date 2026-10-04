// The render harness the WebView asset tests drive.
//
// It reproduces the production path for one message body and nothing else:
// a `.message-content` host, an open shadow root carrying the real
// SHADOW_STYLE, and `writeShadowContent` — the same function the renderer
// calls. Tests then assert on the tree the browser built, on the CSS it
// resolved and on what a click does, instead of on the shape of the source.
import { Formatter } from '/assets/chat_webview/formatter/index.js';
import { writeShadowContent } from '/assets/chat_webview/renderer/markdown.js';
import { SHADOW_STYLE } from '/assets/chat_webview/renderer/shadow_style.js';
import { InteractionDispatch } from '/assets/chat_webview/bridge/interaction_dispatch.js';

const formatter = new Formatter();

/** Everything the harness bridge was asked to forward to Flutter. */
const flutterCalls = [];

/** Console errors the page produced, so a test can assert on a clean render. */
const consoleErrors = [];
const nativeError = console.error.bind(console);
console.error = (...args) => {
  consoleErrors.push(args.map((a) => String(a)).join(' '));
  nativeError(...args);
};

// The narrowest bridge InteractionDispatch can run against: message clicks go
// through the real dispatcher (fragment `:target`, links, image actions), and
// anything that would reach the app is recorded instead of sent.
const bridge = {
  _selectionManager: { handleClick: () => false },
  _swipeHandler: { toggleGuidedSwipe: () => {} },
  _sendToFlutter: (method, args) => flutterCalls.push({ method, args }),
  isGenerating: false,
  notifyMessageScriptBlocked: () => flutterCalls.push({
    method: 'notifyMessageScriptBlocked',
    args: [],
  }),
};
window.bridge = bridge;

const dispatch = new InteractionDispatch(bridge);
document.addEventListener('click', (e) => {
  try {
    dispatch.handleClick(e);
  } catch (error) {
    console.error('dispatch error:', error);
  }
});

function createHost() {
  const host = document.createElement('div');
  host.className = 'message-content';
  const shadow = host.attachShadow({ mode: 'open' });
  const style = document.createElement('style');
  style.textContent = SHADOW_STYLE;
  shadow.appendChild(style);
  const root = document.createElement('div');
  root.className = 'glaze-message';
  shadow.appendChild(root);
  return host;
}

/**
 * Renders one message body the way the app does and returns a handle the
 * specs address it by. Successive calls replace the message on screen, so a
 * spec that renders a stream of prefixes sees one message, not a pile.
 */
function render(text, options = {}) {
  const {
    isUser = false,
    isTyping = false,
    isReasoning = false,
    allowMessageScripts = true,
    searchQuery = '',
    keep = false,
  } = options;
  if (!keep) reset();
  const section = document.createElement('div');
  section.className = 'message';
  section.dataset.messageId = options.messageId || `m${Date.now()}`;
  const host = createHost();
  section.appendChild(host);
  document.getElementById('chat-container').appendChild(section);
  writeShadowContent({
    host,
    text,
    isUser,
    isTyping,
    isReasoning,
    formatter,
    searchQuery,
    applySearchHighlight: (html) => html,
    allowMessageScripts,
  });
  return host;
}

function reset() {
  document.getElementById('chat-container').innerHTML = '';
  flutterCalls.length = 0;
  consoleErrors.length = 0;
  // A stale cache would hide a formatter change from the very next render.
  formatter.cache.clear();
}

/** The message root of the message rendered last. */
function currentRoot() {
  const hosts = document.querySelectorAll('#chat-container .message-content');
  const host = hosts[hosts.length - 1];
  return host ? host.shadowRoot.querySelector('.glaze-message') : null;
}

window.harness = {
  render,
  reset,
  currentRoot,
  formatter,
  flutterCalls,
  consoleErrors,
  /** Raw formatter output, for assertions that predate a DOM. */
  format: (text, isUser = false, isReasoning = false) =>
    formatter.format(text, isUser, isReasoning),
  /** Rendered HTML of the message on screen. */
  html: () => (currentRoot() ? currentRoot().innerHTML : ''),
  /** Text a reader actually sees — collapsed whitespace, no markup. */
  text: () => (currentRoot() ? currentRoot().textContent.replace(/\s+/g, ' ').trim() : ''),
};

window.dispatchEvent(new Event('harness-ready'));
window.__harnessReady = true;
