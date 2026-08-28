// `:target` for message HTML.
//
// ST-style cards toggle a panel with an anchor plus a rule keyed on `:target`
// (`<a href="#vn-k7x1">` … `#vn-k7x1:target { opacity:1 }`). That works in a
// document and nowhere else: a URL fragment is only ever resolved against the
// document tree, so an id that lives inside a shadow root never becomes the
// target element and the rule never matches. Message bodies are rendered in
// exactly such a shadow root (`.message-content`), so every one of those cards
// draws a button that does nothing when tapped.
//
// The shim leaves the card's own CSS in charge and only moves the state it
// keys on: `:target` in the message's `<style>` becomes `[data-glaze-target]`,
// and the attribute is stamped on the element a fragment link points at (see
// `_toggleFragmentTarget` in bridge/interaction_dispatch.js).

/** Marks the element a fragment link inside the same root points at. */
export const TARGET_ATTRIBUTE = 'data-glaze-target';

// `:target` as a whole selector token, so `::target-text` (and any future
// `:target-…` pseudo) keeps its own meaning.
const TARGET_SELECTOR = /:target(?![\w-])/g;

/**
 * Rewrites `:target` in the `<style>` blocks of a freshly written message
 * body. Nothing else in the message is touched, and a message without a
 * `:target` rule keeps its stylesheet byte-identical.
 */
export function rewriteTargetSelectors(root) {
  if (!root || !root.querySelectorAll) return;
  for (const style of root.querySelectorAll('style')) {
    const css = style.textContent || '';
    if (!css.includes(':target')) continue;
    const rewritten = css.replace(TARGET_SELECTOR, `[${TARGET_ATTRIBUTE}]`);
    if (rewritten !== css) style.textContent = rewritten;
  }
}
