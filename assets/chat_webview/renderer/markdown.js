import { syncCodeBlockMetadata } from './code_highlight.js';
import { formatMessageBody } from './macros_in_message.js';
import { sanitizeMessageHtml } from '../bridge/html_sanitizer.js';

export function writeShadowContent({
  host,
  text,
  isUser,
  isTyping,
  formatter,
  searchQuery,
  applySearchHighlight,
  allowMessageScripts = false,
}) {
  if (!host || !host.shadowRoot) return;
  const root = host.shadowRoot.querySelector('.glaze-message');
  if (!root) return;
  try {
    if (isTyping && (!text || !text.trim())) {
      root.innerHTML = '';
      return;
    }
    let formatted = formatMessageBody(formatter, text, isUser);
    if (searchQuery) formatted = applySearchHighlight(formatted);
    // Sanitize before insertion: assigning active HTML first can fire load/error
    // handlers before a later cleanup gets a chance to remove them.
    root.innerHTML = allowMessageScripts
      ? formatted
      : sanitizeMessageHtml(formatted);
    syncCodeBlockMetadata(root);
    executeInlineScripts(root, allowMessageScripts);
    fixDetailsSummaryArrows(root);
  } catch (e) {
    root.textContent = text || '';
    console.error('Formatter error:', e);
  }
}

export function executeInlineScripts(root, allowMessageScripts = false) {
  const scripts = Array.from(root.querySelectorAll('script'));
  if (!allowMessageScripts) {
    scripts.forEach(script => script.remove());
    return;
  }
  for (const oldScript of scripts) {
    // Inline scripts set via innerHTML are never executed by the browser.
    // We run them manually with shimmed globals so ST-compatible regex
    // scripts (BOOTS, HEADER, etc.) work inside shadow DOM:
    //   - document.currentScript.previousElementSibling -> sibling in shadow root
    //   - document.getElementById -> searches inside the shadow root first
    //   - document.querySelector  -> searches inside the shadow root first
    const prev = oldScript.previousElementSibling;
    const src = oldScript.textContent || '';
    try {
      const shim = { previousElementSibling: prev, parentNode: prev ? prev.parentNode : null };
      const csDesc = Object.getOwnPropertyDescriptor(Document.prototype, 'currentScript');
      Object.defineProperty(document, 'currentScript', { value: shim, configurable: true });

      const origGetById = document.getElementById.bind(document);
      const origQS = document.querySelector.bind(document);
      document.getElementById = function(id) {
        const inShadow = root.querySelector('#' + CSS.escape(id));
        return inShadow || origGetById(id);
      };
      document.querySelector = function(sel) {
        const inShadow = root.querySelector(sel);
        return inShadow || origQS(sel);
      };

      try {
        new Function(src)();
      } finally {
        if (csDesc) {
          Object.defineProperty(document, 'currentScript', csDesc);
        } else {
          delete document.currentScript;
        }
        document.getElementById = origGetById;
        document.querySelector = origQS;
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
