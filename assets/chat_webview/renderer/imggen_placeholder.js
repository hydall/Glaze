/* Isolates the "generating image" placeholder from message CSS.
 *
 * A message body is authored content: cards ship their own `<style>` blocks,
 * and those rules land in the same shadow root as everything the formatter
 * renders. A card that styles `div`, `button` or `*` therefore restyles the
 * loading placeholder too — and because a card's rules can carry `!important`,
 * no amount of specificity in `SHADOW_STYLE` wins that fight. The placeholder
 * is app chrome, not part of the reply, so it must look the same in every chat.
 *
 * The fix is a boundary rather than a specificity war: each `.imggen-loading`
 * becomes a shadow host of its own and its content moves inside, where message
 * rules cannot reach. Two leaks are closed by hand:
 *
 *  - the host element itself still lives in the message tree, so the geometry
 *    that keeps the block visible is pinned as inline `!important` (inline
 *    `!important` outranks a stylesheet's);
 *  - inherited properties (font, colour, spacing) cross a shadow boundary, so
 *    the wrapper inside starts from `all: initial` and sets its own.
 *
 * The shadow root is open, which is what keeps the rest of the WebView working
 * unchanged: click dispatch already walks `composedPath()` (it pierces shadow
 * boundaries), and `ImgGenTimer` descends into the nested root for its ticker.
 */

/** Styles for the placeholder's own shadow tree. Message CSS cannot reach it. */
const PLACEHOLDER_CSS = `
  :host { display: block; }
  .imggen-root {
    /* Cuts every inherited property off at the boundary, so a card's
       font-size / color / letter-spacing stops here. Custom properties are
       exempt from \`all\`, which is what lets the pinned theme colour below
       still reach in. */
    all: initial;
    display: block;
    position: relative;
    box-sizing: border-box;
    width: 100%;
    min-height: 120px;
    border-radius: 12px;
    overflow: hidden;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    font-size: 14px;
    line-height: 1.4;
    color: var(--imggen-fg, #e0e0e0);
    text-align: left;
    -webkit-user-select: none;
    user-select: none;
  }
  /* Grey on grey rather than a white sheen: the same shimmer has to read on a
     light theme and a dark one, and the block no longer inherits either. */
  .imggen-surface {
    position: absolute;
    inset: 0;
    z-index: 0;
    border-radius: inherit;
    background-color: rgba(128, 128, 128, 0.12);
    background-image: linear-gradient(90deg,
      rgba(128, 128, 128, 0.00) 25%,
      rgba(128, 128, 128, 0.16) 50%,
      rgba(128, 128, 128, 0.00) 75%);
    background-size: 200% 100%;
    animation: imggen-shimmer 1.5s infinite linear;
    pointer-events: none;
  }
  .imggen-head {
    position: relative;
    z-index: 1;
    display: flex;
    align-items: baseline;
    gap: 6px;
    padding: 12px 44px 0 12px;
  }
  .imggen-loading-hint {
    font-size: 14px;
    font-weight: 600;
    opacity: 0.9;
  }
  .imggen-loading-timer {
    font-size: 14px;
    font-weight: 600;
    opacity: 0.65;
    font-variant-numeric: tabular-nums;
  }
  .imggen-stop-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    z-index: 2;
    width: 26px;
    height: 26px;
    margin: 0;
    padding: 0;
    border: none;
    border-radius: 50%;
    background: rgba(0, 0, 0, 0.55);
    color: #fff;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .imggen-stop-btn:active { background: rgba(0, 0, 0, 0.8); }
  .imggen-stop-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
    pointer-events: none;
  }
  .imggen-loading-prompt {
    position: absolute;
    z-index: 1;
    bottom: 10px;
    left: 10px;
    right: 10px;
    font-size: 11px;
    line-height: 1.4;
    opacity: 0.6;
    max-height: 2.8em;
    overflow: hidden;
    transition: max-height 0.25s ease;
    word-break: break-word;
  }
  /* Tapping the block opens the full prompt; the class lands on the host. */
  :host(.expanded) .imggen-loading-prompt {
    top: 44px;
    max-height: calc(100% - 54px);
    overflow-y: auto;
  }
  @keyframes imggen-shimmer {
    0% { background-position: 100% 0; }
    100% { background-position: -100% 0; }
  }
`;

/* Geometry pinned on the host, where message rules still apply. Inline
 * `!important` is the one declaration a message stylesheet cannot outrank, so
 * these are the properties a card must not be able to take away: the ones that
 * would hide the block outright, and the box the shadow tree is laid out in.
 * Painting is left to `.imggen-surface` inside, hence the transparent host. */
const HOST_STYLE = [
  ['display', 'block'],
  ['position', 'relative'],
  ['box-sizing', 'border-box'],
  ['inset', 'auto'],
  ['width', 'auto'],
  ['max-width', '100%'],
  ['height', 'auto'],
  ['min-height', '120px'],
  ['max-height', 'none'],
  ['margin', '8px 0'],
  ['padding', '0'],
  ['border', '0'],
  ['border-radius', '12px'],
  ['overflow', 'hidden'],
  ['background', 'transparent'],
  ['box-shadow', 'none'],
  ['animation', 'none'],
  ['transform', 'none'],
  ['filter', 'none'],
  ['clip-path', 'none'],
  ['mix-blend-mode', 'normal'],
  ['float', 'none'],
  ['opacity', '1'],
  ['visibility', 'visible'],
  ['pointer-events', 'auto'],
  ['cursor', 'pointer'],
];

/* The one thing that *should* reach in: the app's own text colour, so the
 * placeholder reads on a light theme as well as a dark one. Custom properties
 * survive `all: initial`, and pinning the value the app set on the document
 * keeps a card from redefining it out from under the block. */
const THEME_VARIABLE = '--text-color';
const PINNED_FOREGROUND = '--imggen-fg';

/** Children that belong on the placeholder's header row, in that order. */
const HEAD_CLASSES = ['imggen-loading-hint', 'imggen-loading-timer'];

/**
 * Moves every `.imggen-loading` placeholder under [root] into a shadow root of
 * its own. Idempotent: a placeholder that already has one is left alone, so
 * calling this after every render costs one query on an unchanged message.
 */
export function isolateImgGenPlaceholders(root) {
  if (!root || !root.querySelectorAll) return;
  for (const host of root.querySelectorAll('.imggen-loading')) {
    if (host.shadowRoot) continue;
    try {
      isolateOne(host);
    } catch (_) {
      // attachShadow refuses a host that already has one, and older engines
      // may refuse it outright. The block then renders from SHADOW_STYLE's
      // fallback rules — plainer, but never missing.
    }
  }
}

function isolateOne(host) {
  const shadow = host.attachShadow({ mode: 'open' });

  const wrapper = host.ownerDocument.createElement('div');
  wrapper.className = 'imggen-root';

  const surface = host.ownerDocument.createElement('div');
  surface.className = 'imggen-surface';
  wrapper.appendChild(surface);

  const head = host.ownerDocument.createElement('div');
  head.className = 'imggen-head';
  wrapper.appendChild(head);

  // The formatter emits the hint, the timer, the stop button and the prompt as
  // flat siblings; the header row is assembled here so the nested stylesheet
  // has a box to lay the first two out in.
  for (const child of Array.from(host.childNodes)) {
    const className = child.nodeType === 1 ? child.className : '';
    const inHead = typeof className === 'string' &&
      HEAD_CLASSES.some((name) => className.split(/\s+/).includes(name));
    (inHead ? head : wrapper).appendChild(child);
  }

  const style = host.ownerDocument.createElement('style');
  style.textContent = PLACEHOLDER_CSS;
  shadow.appendChild(style);
  shadow.appendChild(wrapper);

  for (const [property, value] of HOST_STYLE) {
    host.style.setProperty(property, value, 'important');
  }
  pinForeground(host);
}

function pinForeground(host) {
  let color = '';
  try {
    color = getComputedStyle(host.ownerDocument.documentElement)
      .getPropertyValue(THEME_VARIABLE)
      .trim();
  } catch (_) {
    // No computed style to read (a detached tree): the stylesheet's own
    // fallback colour stands in.
  }
  if (color) host.style.setProperty(PINNED_FOREGROUND, color, 'important');
}
