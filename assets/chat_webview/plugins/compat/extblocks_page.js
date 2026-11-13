// The ExtBlocks page: where script blocks of the original ExtBlocks
// extension run when their preset may use it ("Page over the chat").
//
// The original evaluates a script in SillyTavern's own page, so a script may
// leave things behind — a floating button, a window, a timer, an observer —
// and keep data in `localStorage`. Glaze's one-shot script sandbox drops all
// of that the moment the script returns. This page is a chat panel of a
// plugin the app makes for the preset (`ext_blocks_page.dart`), so it lives
// as long as the chat is open, draws over the chat where its boxes are and
// keeps `localStorage` like a plugin does.
//
// Loaded after plugin_sdk.js, as a plugin's compat layer. It takes the
// plugin `glaze` away and puts the script API (glaze_sdk.js) in its place,
// carried over the plugin call `extblocks.bridge`, so a script sees the same
// `glaze`, `context` and services as in the sandbox (extblocks_compat.js).
//
// What a script reads of the chat is a mirror: the messages as they are
// displayed, in SillyTavern's markup (`#chat .mes[mesid] .mes_text`), hidden.
// Changing it changes nothing in the chat.
(function () {
  'use strict';
  var pg = window.glaze;
  if (document.currentScript) document.currentScript.remove();
  if (!pg || !pg.plugin || !pg.extblocks) return;
  try { delete window.glaze; } catch (e) { /* kept */ }

  var compatSource = __XB_COMPAT__;
  // Scripts that run when the page opens may not generate or write: they
  // restore what a script draws, not what it does.
  var restoring = 0;

  Object.defineProperty(window, 'flutter_inappwebview', {
    configurable: false,
    enumerable: false,
    value: Object.freeze({
      callHandler: function (name, request) {
        if (name !== 'glazeBridge') return Promise.reject(new Error('Unavailable'));
        if (restoring > 0) {
          return Promise.resolve({
            ok: false,
            error: { code: 'restoring', message: 'Not while the page restores its scripts' },
          });
        }
        return pg.extblocks.bridge(request);
      },
    }),
  });

  /*__GLAZE_SDK__*/

  /* ---------- Mirror of the chat ---------- */
  var chat = null;
  var byId = new Map();

  function chatRoot() {
    if (chat && chat.isConnected) return chat;
    chat = document.getElementById('chat');
    if (!chat) {
      chat = document.createElement('div');
      chat.id = 'chat';
      (document.body || document.documentElement).appendChild(chat);
    }
    // Read by scripts, never seen and never touched by a finger.
    chat.style.setProperty('display', 'none', 'important');
    chat.setAttribute('aria-hidden', 'true');
    return chat;
  }

  // Message HTML goes in inert: no script of a message runs on this page,
  // whatever the chat's own setting is.
  function inert(html) {
    var t = document.createElement('template');
    t.innerHTML = String(html == null ? '' : html);
    t.content.querySelectorAll('script,iframe,object,embed,frame,frameset,base,meta,link').forEach(function (el) {
      el.remove();
    });
    t.content.querySelectorAll('*').forEach(function (el) {
      Array.prototype.slice.call(el.attributes).forEach(function (a) {
        var name = a.name.toLowerCase();
        if (name.indexOf('on') === 0 ||
            (/^(href|src|action|formaction|xlink:href)$/.test(name) && /^\s*javascript:/i.test(a.value))) {
          el.removeAttribute(a.name);
        }
      });
    });
    return t.content;
  }

  function messageEl(m) {
    var el = byId.get(m.id);
    if (!el) {
      el = document.createElement('div');
      el.className = 'mes';
      var text = document.createElement('div');
      text.className = 'mes_text';
      el.appendChild(text);
      byId.set(m.id, el);
    }
    el.setAttribute('mesid', String(m.index));
    el.setAttribute('is_user', m.isUser ? 'true' : 'false');
    el.setAttribute('ch_name', String(m.name || ''));
    el.setAttribute('data-message-id', String(m.id));
    var body = el.querySelector('.mes_text');
    body.replaceChildren(inert(m.html));
    return el;
  }

  function applyMirror(d) {
    if (!d) return;
    var root = chatRoot();
    if (d.reset) {
      byId.clear();
      root.replaceChildren();
    }
    (d.upsert || []).forEach(messageEl);
    var order = Array.isArray(d.order) ? d.order : [];
    var keep = new Set(order);
    byId.forEach(function (el, id) {
      if (!keep.has(id)) { el.remove(); byId.delete(id); }
    });
    order.forEach(function (id, index) {
      var el = byId.get(id);
      if (!el) return;
      el.setAttribute('mesid', String(index));
      if (root.children[index] !== el) root.insertBefore(el, root.children[index] || null);
    });
  }

  pg.plugin.on('extblocks:mirror', applyMirror);

  /* ---------- Running scripts ---------- */
  pg.plugin.on('action:extblocks:run', async function (args) {
    args = args || {};
    var context = JSON.parse(JSON.stringify(args.context || {}));
    window.__glazeContext = context;
    if (args.restore) restoring++;
    try {
      var scope = (new Function('context', compatSource))(context);
      var result = await scope.__run(String(args.script || ''));
      return result === undefined || result === null ? '' : String(result);
    } finally {
      if (args.restore) restoring--;
    }
  });

  chatRoot();
})();
