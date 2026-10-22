import { syncCodeBlockMetadata } from './code_highlight.js';
import { formatMessageBody } from './macros_in_message.js';
import { inspectBlockedAtRules, reportCssErrors } from './css_diagnostics.js';
import { isolateImgGenPlaceholders } from './imggen_placeholder.js';
import { sanitizeMessageHtml } from '../bridge/html_sanitizer.js';
import {
  hoistStyleFontFaces,
  hoistStyleImports,
  installMessageDocument,
} from './message_document.js';
import { retryFailedLocalImages } from './local_image_retry.js';

/** Cheap pre-sanitize probe for an embedded `<script>` in formatted HTML. */
const SCRIPT_TAG = /<script\b/i;

/**
 * Tell Flutter that a message wanted to run JS while execution is off, so the
 * app can offer to turn it on. The check has to run on the *formatted* HTML:
 * with execution off `sanitizeMessageHtml` drops every `<script>` before
 * insertion, so by the time the script runner looks at the DOM there is
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

/** `<style>` bodies as the message wrote them, before the CSS policy ran. */
const STYLE_BLOCK = /<style\b[^>]*>([\s\S]*?)(?:<\/style\s*>|$)/gi;

/**
 * The message's own CSS, as written.
 *
 * Read off the formatted HTML rather than the DOM: the sanitizer rewrites
 * every `<style>` before insertion, so by the time the message is on screen
 * the at-rules it carried are already gone.
 */
function styleSources(formatted) {
  const sources = [];
  STYLE_BLOCK.lastIndex = 0;
  let match;
  while ((match = STYLE_BLOCK.exec(formatted)) !== null) sources.push(match[1]);
  return sources;
}

/** What the CSS policy did to the message's at-rules, as report lines. */
function cssPolicyNotes(sources, refusedImports, refusedFontFaces) {
  const notes = refusedImports.map(
    (url) => `@import ignored: ${url} (only https is loaded)`,
  );
  notes.push(...refusedFontFaces);
  for (const css of sources) notes.push(...inspectBlockedAtRules(css));
  return notes;
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
  allowExternalMedia = true,
  isReasoning = false,
  messageId,
}) {
  if (!host || !host.shadowRoot) return;
  const root = host.shadowRoot.querySelector('.glaze-message');
  if (!root) return;
  try {
    if (isTyping && (!text || !text.trim())) {
      root.innerHTML = '';
      return;
    }
    let formatted = formatMessageBody(
      formatter,
      text,
      isUser,
      isReasoning,
      !isTyping,
    );
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
      allowExternalMedia,
    });
    // Before anything else touches the tree: the placeholder's content moves
    // behind a shadow boundary, out of reach of the message's own CSS.
    isolateImgGenPlaceholders(root, messageId);
    syncCodeBlockMetadata(root);
    // A reply still arriving is half a stylesheet, and every unclosed brace in
    // it is on its way to being closed — report only what the message settled
    // on. `isGenerating` covers the whole reply, `isTyping` its first chunks.
    // `@import` and `@font-face` do not work inside a shadow root, so the
    // sheets a card pulls and the fonts it embeds are lifted to the document
    // head (INV-MR5). Everything the CSS policy still refuses is reported
    // instead of failing silently.
    const styles = styleSources(formatted);
    const refusedImports = hoistStyleImports(styles, { allowExternalMedia });
    const refusedFontFaces = hoistStyleFontFaces(styles, { allowExternalMedia });
    if (!isTyping && !window.bridge?.isGenerating) {
      reportCssErrors(root, cssPolicyNotes(styles, refusedImports, refusedFontFaces));
    }
    // The message's document: `:target` re-keyed, the scoped `document.*`
    // lookups installed for later events, and the card's own scripts run.
    // See renderer/message_document.js and INV-MR1…INV-MR8.
    installMessageDocument(root, { allowMessageScripts });
    retryFailedLocalImages(root);
  } catch (e) {
    root.textContent = text || '';
    console.error('Formatter error:', e);
  }
}
