// The scroll buttons: jump to the end of the chat, and back to its start.
// Two 44px round buttons stacked in the bottom-right corner, just above the
// composer, as the Flutter buttons they replaced were.
//
// They used to be Flutter widgets laid over the WebView, which put them above
// everything the page draws: on a phone held sideways, the composer filling
// the screen above the keyboard still had them on top of it. Drawn here they
// sit in a layer under the composer and the drawer, and stand down while the
// composer is fullscreen.
//
// Flutter decides when each one is worth showing (the page reports the scroll
// position, Flutter gates it on search, editing and the header) and sends
// `{ down, up }`; a tap comes back as the `scrollDown` / `scrollUp` intent.

import * as S from './safe.js';
import { ICON as I } from './icons.js';
import { h, css, px, rgba, setClass, icon, onTap } from './ui.js';

const SIZE = 44;
const GAP = 8;
const EDGE = 16;

export function createScroll(ctx, composer) {
  const state = { down: false, up: false };

  function button(glyph, intent) {
    const el = h('button', 'gc-scrollbtn', ctx.root);
    S.setAttribute(el, 'type', 'button');
    S.setAttribute(el, 'tabindex', '-1');
    icon(glyph, 26, el);
    onTap(el, () => ctx.send(intent));
    return el;
  }

  const down = button(I.keyboard_arrow_down_rounded, 'scrollDown');
  const up = button(I.keyboard_arrow_up_rounded, 'scrollUp');

  function show(el, on) {
    setClass(el, on ? 'gc-scrollbtn gc-on' : 'gc-scrollbtn');
  }

  /** Follows the composer: called on every layout and every report. */
  function place(composerHeight) {
    const layout = ctx.layout;
    const theme = ctx.theme;
    const bottom = S.mathMax(0, (layout.inset || 0) - ctx.shrink()) + (composerHeight || 0) + EDGE;
    const right = px(EDGE + (layout.gutter || 0));
    css(down, 'right', right);
    css(up, 'right', right);
    css(down, 'bottom', px(bottom));
    css(up, 'bottom', px(bottom + SIZE + GAP));
    const fill = rgba(theme.surface || theme.fillSurface, 0.9);
    css(down, 'background-color', fill);
    css(up, 'background-color', fill);
    // Out of the way while the composer fills the screen: it would only show
    // through the field's glass.
    const full = composer.isFull();
    show(down, state.down && !full);
    show(up, state.up && !full);
  }

  return {
    apply(next) {
      state.down = !!next.down;
      state.up = !!next.up;
    },
    place,
  };
}
