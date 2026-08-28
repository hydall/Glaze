import { syncCodeBlockMetadata } from './code_highlight.js';
import { formatMessageBody } from './macros_in_message.js';
import { reportCssErrors } from './css_diagnostics.js';
import { isolateImgGenPlaceholders } from './imggen_placeholder.js';
import { sanitizeMessageHtml } from '../bridge/html_sanitizer.js';
import { rewriteTargetSelectors } from './target_toggle.js';
import {
  installShadowDocumentShim,
  runInMessageScope,
} from './shadow_document_shim.js';

/** Cheap pre-sanitize probe for an embedded `<script>` in formatted HTML. */
const SCRIPT_TAG = /<script\b/i;

/** How many times a generated image may re-request itself after a failure. */
const LOCAL_IMAGE_RETRY_LIMIT = 2;

/** Backoff before the first retry; later attempts scale with the attempt. */
const LOCAL_IMAGE_RETRY_DELAY_MS = 350;

/**
 * Tell Flutter that a message wanted to run JS while execution is off, so the
 * app can offer to turn it on. The check has to run on the *formatted* HTML:
 * with execution off `sanitizeMessageHtml` drops every `<script>` before
 * insertion, so by the time `executeInlineScripts` looks at the DOM there is
 * nothing left to see. The bridge de-duplicates, so calling this on every
 * render is fine.
 */
function notifyMessageScriptBlocked() {
  try {
    window.bridge?.notifyMessageScriptBlocked?.();
  } catch (_) {
    // Bridge not wired yet — a later render notifies instead.
  }
}

export function writeShadowContent({
  host,
  text,
  isUser,
  isTyping,
  formatter,
  searchQuery,
  applySearchHighlight,
  allowMessageScripts = false,
  isReasoning = false,
}) {
  if (!host || !host.shadowRoot) return;
  const root = host.shadowRoot.querySelector('.glaze-message');
  if (!root) return;
  try {
    if (isTyping && (!text || !text.trim())) {
      root.innerHTML = '';
      return;
    }
    let formatted = formatMessageBody(formatter, text, isUser, isReasoning);
    if (searchQuery) formatted = applySearchHighlight(formatted);
    if (!allowMessageScripts && SCRIPT_TAG.test(formatted)) {
      notifyMessageScriptBlocked();
    }
    // Strip the code before insertion: assigning active HTML first can fire
    // load/error handlers before a later cleanup gets a chance to remove them.
    // Markup and CSS are never touched — with execution off the message is
    // still rendered exactly as written, it just cannot run anything.
    root.innerHTML = sanitizeMessageHtml(formatted, {
      allowScripts: allowMessageScripts,
    });
    // A fragment link cannot make an id inside a shadow root the document's
    // target element, so the card's `:target` rules are re-keyed on the
    // attribute the click dispatcher stamps instead.
    rewriteTargetSelectors(root);
    // Before anything else touches the tree: the placeholder's content moves
    // behind a shadow boundary, out of reach of the message's own CSS.
    isolateImgGenPlaceholders(root);
    syncCodeBlockMetadata(root);
    // A reply still arriving is half a stylesheet, and every unclosed brace in
    // it is on its way to being closed — report only what the message settled
    // on. `isGenerating` covers the whole reply, `isTyping` its first chunks.
    if (!isTyping && !window.bridge?.isGenerating) reportCssErrors(root);
    executeInlineScripts(root, allowMessageScripts);
    fixDetailsSummaryArrows(root);
    retryFailedLocalImages(root);
  } catch (e) {
    root.textContent = text || '';
    console.error('Formatter error:', e);
  }
}

/**
 * Re-requests a generated image that failed to load.
 *
 * Generated images are served by the app's own loopback file server, and that
 * fetch can lose a race the picture itself is not to blame for — the file
 * server is still answering an aborted request from the render this one
 * replaced, or the app is mid-resize as the reply settles. The browser never
 * retries a failed <img>, so a message keeps the broken tag until something
 * re-renders it. A couple of delayed attempts with a fresh query string (the
 * file server reads only `path`, and a new URL sidesteps a cached failure)
 * turn that into a picture that simply arrives a moment later.
 */
export function retryFailedLocalImages(root) {
  for (const img of root.querySelectorAll('img.imggen-result')) {
    if (img.dataset.retryWired) continue;
    img.dataset.retryWired = '1';
    img.addEventListener('error', () => {
      const source = img.dataset.src || '';
      if (!source) return;
      const attempt = Number(img.dataset.retryAttempt || '0') + 1;
      if (attempt > LOCAL_IMAGE_RETRY_LIMIT) return;
      img.dataset.retryAttempt = String(attempt);
      setTimeout(() => {
        const separator = source.includes('?') ? '&' : '?';
        img.src = `${source}${separator}__glaze_retry=${attempt}`;
      }, LOCAL_IMAGE_RETRY_DELAY_MS * attempt);
    });
  }
}

export function executeInlineScripts(root, allowMessageScripts = false) {
  const scripts = Array.from(root.querySelectorAll('script'));
  if (!allowMessageScripts) {
    scripts.forEach(script => script.remove());
    return;
  }
  if (!scripts.length) return;
  // Message JS reaches its own DOM through `document`; from here on the
  // document's lookups know about the message shadow roots.
  installShadowDocumentShim();
  for (const oldScript of scripts) {
    // Inline scripts set via innerHTML are never executed by the browser. We
    // re-run each one through a script element of our own, so it behaves like
    // the document script an ST-compatible card is written as: the body
    // evaluates in global scope, which is the only way a `function toggle(){…}`
    // the markup calls back from an `onclick=` handler is still there when the
    // button is pressed. Two shims cover what a shadow root breaks:
    //   - document.currentScript.previousElementSibling -> sibling in shadow root
    //   - document.getElementById / querySelector -> the message root first
    //     (shadow_document_shim.js, which keeps answering for the card long
    //     after this call returns — that is when its buttons are pressed)
    const prev = oldScript.previousElementSibling;
    const src = oldScript.textContent || '';
    try {
      const shim = { previousElementSibling: prev, parentNode: prev ? prev.parentNode : null };
      const csDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'currentScript');
      Object.defineProperty(document, 'currentScript', { value: shim, configurable: true });

      const runner = document.createElement('script');
      runner.textContent = src;
      try {
        // An inline script runs on insertion, so the whole body evaluates
        // inside the scope below; an error in it reaches the console the way a
        // page script's does.
        runInMessageScope(root, () => document.head.appendChild(runner));
      } finally {
        runner.remove();
        if (csDesc) {
          Object.defineProperty(document, 'currentScript', csDesc);
        } else {
          delete document.currentScript;
        }
      }
    } catch (e) {
      console.error('Inline script error:', e);
    }
    oldScript.remove();
  }
}

export function fixDetailsSummaryArrows(root) {
  root.querySelectorAll('details').forEach(details => {
    const summary = details.querySelector('summary');
    if (!summary || summary.querySelector('.glaze-flex-wrap')) return;

    const wrap = document.createElement('span');
    wrap.className = 'glaze-flex-wrap';
    wrap.style.cssText = 'display:flex;align-items:baseline;gap:6px;width:100%;';

    const arrow = document.createElement('span');
    arrow.className = 'glaze-arrow';
    arrow.setAttribute('aria-hidden', 'true');
    arrow.textContent = '▶';

    while (summary.firstChild) {
      wrap.appendChild(summary.firstChild);
    }
    wrap.insertBefore(arrow, wrap.firstChild);
    summary.appendChild(wrap);

    details.addEventListener('toggle', () => {
      arrow.classList.toggle('glaze-arrow-open', details.open);
    }, { once: false });
  });
}
