// A theme's own layout for one chrome surface: its template lays out the
// surface's pieces (see template.js), and taking it away puts each piece back
// where the surface built it.

import * as S from './safe.js';
import { arrange } from './template.js';
import { h, detach, onTap } from './ui.js';

/**
 * [container] is where the template is drawn, [pieces] (name → element) what
 * it may place, [home] the surface's own order to restore: a list of
 * `[parent, [children…]]`, outermost first. [actions] (name → fn(scope)) are
 * what a `g-action` may do.
 */
export function createSkin(container, pieces, home, actions) {
  let view = null;
  let holder = null;
  // Each piece's own parent, from [home].
  const homes = S.dict();
  for (let i = 0; i < home.length; i++) {
    const kids = home[i][1];
    for (let k = 0; k < kids.length; k++) {
      for (const name in pieces) if (S.hasOwn(pieces, name) && pieces[name] === kids[k]) homes[name] = home[i][0];
    }
  }
  let data = {};
  const hooks = {
    action(el, name, scope) {
      const fn = S.hasOwn(actions, name) ? actions[name] : null;
      if (typeof fn === 'function') onTap(el, () => fn(scope));
    },
  };

  function goHome() {
    for (let i = 0; i < home.length; i++) {
      const parent = home[i][0];
      const kids = home[i][1];
      for (let k = 0; k < kids.length; k++) if (kids[k]) S.appendChild(parent, kids[k]);
    }
  }

  return {
    /** Lays the surface out with [tpl] (compiled), or its own way for null. */
    set(tpl) {
      if (view) {
        view.destroy();
        view = null;
        goHome();
        detach(holder);
        holder = null;
      }
      if (!tpl || tpl.empty) return;
      holder = h('div', 'g-unplaced', container);
      view = arrange(tpl, data, container, pieces, holder, hooks, homes);
    },
    update(next) {
      data = next;
      if (view) view.update(next);
    },
    get active() {
      return !!view;
    },
  };
}
