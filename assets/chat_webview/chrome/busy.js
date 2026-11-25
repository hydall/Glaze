// The spinner over the chat while it switches to another session (an imported
// chat, a session picked from outside the chat). The page under it is about
// to be replaced, so it also takes every tap until the switch lands.
//
// It used to be a Flutter overlay above the WebView. Flutter still decides
// when the chat is busy and sends `busy: true | false`.

import * as S from './safe.js';
import { h, setClass, clear } from './ui.js';
import { spinner } from './cards.js';

export function createBusy(ctx) {
  const el = h('div', 'gc-busy gc-hidden', ctx.root);
  let on = false;
  let color = '';

  function render() {
    setClass(el, on ? 'gc-busy gc-live' : 'gc-busy gc-hidden');
    const accent = S.jsonStringify(ctx.theme.accent);
    if (!on || accent === color) return;
    color = accent;
    clear(el);
    spinner(el, 36, ctx.theme.accent);
  }

  return {
    apply(value) {
      on = !!value;
      render();
    },
    themeChanged() {
      color = '';
      render();
    },
  };
}
