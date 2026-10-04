/* Typing-bubble phase label.
 *
 * The label under the pencil names the stage the generation is actually in —
 * "Building prompt…", "Waiting for the model…", "Generating…" — pushed from
 * Flutter through `bridge.setGenerationPhase()` as the run advances. The text
 * itself is localized on the Dart side; this module only owns how a new label
 * replaces the old one on screen.
 *
 * The swap is two-stage (old text fades down and out, new text fades up and
 * in) so a phase change reads as a transition rather than a flicker. Battery
 * saver swaps the text outright: the whole point of that mode is to keep
 * repeated animations off the compositor.
 */

/* Shown until Flutter names a phase — and after a run ends, so a re-rendered
 * bubble never shows a stale phase from the previous turn. */
export const DEFAULT_TYPING_TEXT = 'Generating...';

/* Must match the .typing-text.phase-out animation duration in styles.css. */
const SWAP_OUT_MS = 130;

/* Replaces the label of one `.typing-text` node, cross-fading unless
 * [animate] is false. Re-entrant: a phase that changes again mid-swap cancels
 * the pending timer instead of stacking a second one, so the node always
 * settles on the newest label. */
export function applyTypingPhase(el, label, animate) {
  if (!el) return;
  const next = label || DEFAULT_TYPING_TEXT;
  if (el._phaseTimer) {
    clearTimeout(el._phaseTimer);
    el._phaseTimer = null;
  }
  // `_phasePending` is the label the node is mid-swap towards; comparing
  // against it (not just textContent) keeps a repeated phase from restarting
  // the animation on every push.
  if ((el._phasePending || el.textContent) === next) {
    el._phasePending = null;
    return;
  }
  if (!animate || !el.textContent) {
    el._phasePending = null;
    el.classList.remove('phase-out', 'phase-in');
    el.textContent = next;
    return;
  }
  el._phasePending = next;
  el.classList.remove('phase-in');
  el.classList.add('phase-out');
  el._phaseTimer = setTimeout(() => {
    el._phaseTimer = null;
    el._phasePending = null;
    el.textContent = next;
    el.classList.remove('phase-out');
    el.classList.add('phase-in');
  }, SWAP_OUT_MS);
}
