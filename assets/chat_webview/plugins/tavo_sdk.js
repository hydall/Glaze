// Tavo-compatible plugin SDK. Runs inside a plugin iframe
// (sandbox="allow-scripts", null origin) — never in the chat page itself.
//
// The host (plugin_host.js) writes `window.__TAVO_BOOT__` before this script:
//   { pluginId, surface: 'entry'|'fragment', fragmentId, config, i18n,
//     vars: { chat, global }, storage, methods: [...] }
// Every call goes to the parent as a `tavo:call` postMessage; the parent
// attributes it to this frame's plugin and forwards it to Dart, so nothing the
// plugin sends can claim another plugin's identity.
(function () {
  'use strict';
  var boot = window.__TAVO_BOOT__ || {};
  var parentWin = window.parent;
  var seq = 0;
  var pending = new Map();
  var isEntry = boot.surface === 'entry';

  function post(msg) {
    try { parentWin.postMessage(msg, '*'); } catch (e) { /* host gone */ }
  }

  function call(method, params) {
    return new Promise(function (resolve, reject) {
      var id = 'c' + (++seq);
      pending.set(id, { resolve: resolve, reject: reject });
      post({ type: 'tavo:call', id: id, method: method, params: params === undefined ? null : params });
    });
  }

  function fire(method, params) {
    call(method, params).catch(function (e) { console.warn('[tavo]', method, e && e.message); });
  }

  /* ---------- Variables (async + legacy sync cache) ---------- */
  var varCache = {
    chat: (boot.vars && boot.vars.chat) || {},
    global: (boot.vars && boot.vars.global) || {},
  };

  function splitPath(name) {
    return String(name == null ? '' : name).split('.').filter(function (p) { return p.length; });
  }
  function getAt(root, name) {
    var parts = splitPath(name), node = root;
    for (var i = 0; i < parts.length; i++) {
      if (node == null || typeof node !== 'object') return undefined;
      node = node[parts[i]];
    }
    return node;
  }
  function setAt(root, name, value) {
    var parts = splitPath(name), node = root;
    if (!parts.length) return;
    for (var i = 0; i < parts.length - 1; i++) {
      if (node[parts[i]] == null || typeof node[parts[i]] !== 'object') node[parts[i]] = {};
      node = node[parts[i]];
    }
    node[parts[parts.length - 1]] = value;
  }
  function clone(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); }
  function scopeOf(s) {
    if (s && typeof s === 'object') s = s.scope;
    return s === 'global' ? 'global' : 'chat';
  }
  function isPlain(v) { return v != null && typeof v === 'object' && !Array.isArray(v); }

  var variable = Object.freeze({
    list: function (scope) { return call('variable.list', { scope: scopeOf(scope) }); },
    get: function (name, scope) { return call('variable.get', { name: name, scope: scopeOf(scope) }); },
    set: function (name, value, scope) {
      var s = scopeOf(scope);
      setAt(varCache[s], name, clone(value));
      return call('variable.set', { name: name, value: value, scope: s });
    },
    update: function (name, value, scope) {
      var s = scopeOf(scope), prev = getAt(varCache[s], name);
      setAt(varCache[s], name, isPlain(prev) && isPlain(value) ? Object.assign({}, prev, clone(value)) : clone(value));
      return call('variable.update', { name: name, value: value, scope: s });
    },
    unset: function (name, scope) {
      var s = scopeOf(scope), parts = splitPath(name), parent = parts.length > 1
        ? getAt(varCache[s], parts.slice(0, -1).join('.')) : varCache[s];
      if (parent && typeof parent === 'object') delete parent[parts[parts.length - 1]];
      return call('variable.unset', { name: name, scope: s });
    },
  });

  /* ---------- Plugin namespace ---------- */
  var handlers = new Map(); // event -> [fn]
  var emitHandlers = new Map();
  var HOOK_EVENTS = ['input:beforeSend', 'input:afterSend', 'generation:prepare',
    'generation:success', 'generation:error', 'generation:cancelled'];
  var PREFIXES = ['chat:', 'message:', 'inputActions:', 'sidebar:', 'lastMessageActions:'];

  function canonical(type) { return type === 'chat:changed' ? 'chat:updated' : type; }

  function on(type, handler) {
    if (typeof handler !== 'function') throw new Error('Plugin event handler must be a function: ' + type);
    var known = typeof type === 'string' &&
      (HOOK_EVENTS.indexOf(type) >= 0 || PREFIXES.some(function (p) { return type.indexOf(p) === 0; }));
    if (!known) {
      // Glaze extension: any other name is a plugin-private event, delivered
      // by tavo.plugin.emit() to every frame of the same plugin.
      if (typeof type !== 'string' || !type) throw new Error('Unsupported plugin event: ' + type);
      if (!emitHandlers.has(type)) emitHandlers.set(type, []);
      emitHandlers.get(type).push(handler);
      return function () { remove(emitHandlers, type, handler); };
    }
    var key = canonical(type);
    // Hooks and actions belong to the entry script, as in Tavo. Fragments may
    // still listen to chat:/message: notifications.
    if (!isEntry && (HOOK_EVENTS.indexOf(key) >= 0 || !/^(chat|message):/.test(key))) {
      throw new Error('Plugin event registration unavailable: ' + type);
    }
    if (!handlers.has(key)) handlers.set(key, []);
    handlers.get(key).push(handler);
    post({ type: 'tavo:subscribe', event: key });
    return function () { remove(handlers, key, handler); };
  }
  function remove(map, key, fn) {
    var list = map.get(key);
    if (!list) return;
    var i = list.indexOf(fn);
    if (i >= 0) list.splice(i, 1);
  }

  function emit(name, detail) {
    if (typeof name !== 'string' || !name) throw new Error('Plugin event name is required');
    var payload;
    try { payload = detail === undefined ? null : JSON.parse(JSON.stringify(detail)); } catch (e) { payload = null; }
    post({ type: 'tavo:emit', event: name, detail: payload });
  }

  var configValues = Object.freeze(Object.assign({}, boot.config || {}));
  var config = Object.freeze({
    get: function (key) {
      return Object.prototype.hasOwnProperty.call(configValues, key) ? clone(configValues[key]) : null;
    },
    all: function () { return clone(configValues); },
  });

  var i18nState = boot.i18n || null;
  var i18nListeners = new Set();
  var i18n = i18nState ? Object.freeze({
    get requestedLocale() { return i18nState.requestedLocale; },
    get locale() { return i18nState.locale; },
    get defaultLocale() { return i18nState.defaultLocale; },
    get supportedLocales() { return (i18nState.supportedLocales || []).slice(); },
    t: function (key, params) {
      var msg = i18nState.messages && Object.prototype.hasOwnProperty.call(i18nState.messages, key)
        ? i18nState.messages[key] : key;
      if (!params || typeof params !== 'object') return msg;
      return String(msg).replace(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g, function (m, name) {
        if (!Object.prototype.hasOwnProperty.call(params, name)) return m;
        var v = params[name];
        return (typeof v === 'string' || typeof v === 'boolean' || (typeof v === 'number' && isFinite(v))) ? String(v) : m;
      });
    },
    onChange: function (fn) {
      if (typeof fn !== 'function') throw new Error('i18n.onChange handler must be a function');
      i18nListeners.add(fn);
      return function () { i18nListeners.delete(fn); };
    },
  }) : undefined;

  function actionRegistrar(prefix) {
    return function (id, handler) {
      if (typeof id !== 'string' || !id) throw new Error('Action id is required');
      return on(prefix + id, handler);
    };
  }

  var plugin = {
    pluginId: boot.pluginId,
    fragmentId: boot.fragmentId || null,
    on: on,
    emit: emit,
    onInputAction: actionRegistrar('inputActions:'),
    onSidebarAction: actionRegistrar('sidebar:'),
    onLastMessageAction: actionRegistrar('lastMessageActions:'),
    registerFileProcessor: function () {
      throw new Error('File processors are not supported by Glaze yet');
    },
    config: config,
  };
  if (i18n) plugin.i18n = i18n;

  /* ---------- UI insets ---------- */
  var insets = Object.freeze(Object.assign({ topSafe: 0, topBar: 0, bottomInput: 0, bottomSafe: 0 }, boot.insets || {}));
  var insetListeners = new Set();
  var INSET_VARS = { topSafe: 'top-safe', topBar: 'top-bar', bottomInput: 'bottom-input', bottomSafe: 'bottom-safe' };
  function applyInsetVars() {
    var root = document.documentElement;
    if (!root) return;
    Object.keys(INSET_VARS).forEach(function (k) {
      root.style.setProperty('--tavo-inset-' + INSET_VARS[k], insets[k] + 'px');
    });
  }
  applyInsetVars();
  var ui = Object.freeze({
    getInsets: function () { return insets; },
    onInsetsChanged: function (fn) {
      if (typeof fn !== 'function') throw new Error('onInsetsChanged handler must be a function');
      insetListeners.add(fn);
      return function () { insetListeners.delete(fn); };
    },
  });

  /* ---------- Bridged namespaces ---------- */
  var available = new Set(boot.methods || []);
  function ns(name, fns, extra) {
    var o = {};
    fns.forEach(function (fn) {
      var method = name + '.' + fn;
      if (!available.has(method)) return;
      o[fn] = function () { return call(method, Array.prototype.slice.call(arguments)); };
    });
    return Object.freeze(Object.assign(o, extra || {}));
  }

  var tavo = {
    variable: variable,
    get: function (name, scope) { return clone(getAt(varCache[scopeOf(scope)], name)); },
    set: function (name, value, scope) { variable.set(name, value, scope).catch(function () {}); },
    update: function (name, value, scope) { variable.update(name, value, scope).catch(function () {}); },
    unset: function (name, scope) { variable.unset(name, scope).catch(function () {}); },
    message: ns('message', ['find', 'get', 'count', 'current']),
    chat: ns('chat', ['current']),
    character: ns('character', ['all', 'get', 'find', 'current']),
    persona: ns('persona', ['all', 'get', 'find', 'current']),
    input: ns('input', ['get', 'set', 'append', 'clear', 'send']),
    file: ns('file', ['list', 'save', 'load', 'delete', 'exists']),
    utils: ns('utils', ['toast', 'openUrl', 'ask', 'select']),
    app: ns('app', ['version', 'versionNumber']),
    plugin: Object.freeze(plugin),
    ui: ui,
  };
  if (available.has('generate')) {
    tavo.generate = function (prompt, options) { return call('generate', [prompt, options || {}]); };
  }
  tavo.v1 = Object.freeze({ get: tavo.get, set: tavo.set, update: tavo.update, unset: tavo.unset });
  tavo = Object.freeze(tavo);
  try {
    Object.defineProperty(window, 'tavo', { value: tavo, writable: false, configurable: false });
  } catch (e) { window.tavo = tavo; }

  /* ---------- localStorage shim ---------- */
  // A null-origin frame has no Web Storage; scripts written for Tavo (where
  // plugins share the chat page's origin) expect one. This keeps a per-plugin
  // copy in Glaze and persists every write.
  var store = Object.assign({}, boot.storage || {});
  var storage = {
    get length() { return Object.keys(store).length; },
    key: function (i) { var k = Object.keys(store); return i >= 0 && i < k.length ? k[i] : null; },
    getItem: function (k) { k = String(k); return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
    setItem: function (k, v) { k = String(k); v = String(v); store[k] = v; fire('storage.set', { key: k, value: v }); },
    removeItem: function (k) { k = String(k); delete store[k]; fire('storage.remove', { key: k }); },
    clear: function () { store = {}; fire('storage.clear', {}); },
  };
  try { Object.defineProperty(window, 'localStorage', { value: storage, configurable: true }); } catch (e) { /* keep native */ }

  /* ---------- Host -> frame messages ---------- */
  function errorFrom(err) {
    var e = new Error((err && err.message) || 'Tavo call failed');
    if (err && err.code) e.code = err.code;
    if (err && err.details) e.details = err.details;
    return e;
  }

  function runHandlers(list, event) {
    (list || []).slice().forEach(function (fn) {
      try {
        var r = fn(event);
        if (r && typeof r.catch === 'function') r.catch(function (e) { console.error('[tavo plugin]', e); });
      } catch (e) { console.error('[tavo plugin]', e); }
    });
  }

  function withTimeout(promise, ms) {
    if (!ms) return promise;
    return new Promise(function (resolve, reject) {
      var t = setTimeout(function () { reject(new Error('timeout')); }, ms);
      promise.then(function (v) { clearTimeout(t); resolve(v); }, function (e) { clearTimeout(t); reject(e); });
    });
  }

  // Blocking hooks: run in registration order, each against the text the
  // previous one committed. A throw/timeout discards that handler's edits.
  async function runInterceptor(type, payload) {
    var text = typeof payload.text === 'string' ? payload.text : '';
    var list = (handlers.get(type) || []).slice();
    var cancellable = type === 'input:beforeSend';
    var allowEmpty = type !== 'generation:success';
    var timeout = type === 'generation:prepare' ? 0 : 5000;
    for (var i = 0; i < list.length; i++) {
      var draft = text, cancelled = false, reason = null, active = true;
      var event = Object.create(null);
      ['type', 'chatId', 'source', 'at', 'generationId'].forEach(function (k) {
        if (payload[k] !== undefined) Object.defineProperty(event, k, { value: payload[k], enumerable: true });
      });
      Object.defineProperty(event, 'type', { value: type, enumerable: true, configurable: true });
      Object.defineProperty(event, 'pluginId', { value: boot.pluginId, enumerable: true });
      Object.defineProperty(event, 'text', {
        enumerable: true,
        get: function () { return draft; },
        set: function (v) { if (active) draft = v; },
      });
      if (cancellable) {
        event.cancel = function (r) { if (active) { cancelled = true; reason = r == null ? null : String(r); } };
      }
      try {
        await withTimeout(Promise.resolve(list[i](event)), timeout);
        active = false;
        if (typeof draft !== 'string' || (!allowEmpty && !draft.trim())) continue;
        text = draft;
        if (cancelled) return { text: text, cancelled: true, message: reason };
      } catch (e) {
        active = false;
        console.error('[tavo plugin] ' + type, e);
      }
    }
    return { text: text, cancelled: false };
  }

  window.addEventListener('message', function (e) {
    if (e.source !== parentWin) return;
    var d = e.data;
    if (!d || typeof d.type !== 'string') return;
    switch (d.type) {
      case 'tavo:result': {
        var p = pending.get(d.id);
        if (!p) return;
        pending.delete(d.id);
        if (d.ok) p.resolve(d.result === undefined ? null : d.result);
        else p.reject(errorFrom(d.error));
        return;
      }
      case 'tavo:event': {
        var type = canonical(d.event);
        var ev = Object.assign({}, d.payload || {}, { type: type, pluginId: boot.pluginId });
        if (d.vars) varCache[d.vars.scope] = d.vars.value || {};
        runHandlers(handlers.get(type), Object.freeze(ev));
        if (type.indexOf('message:') === 0 && type !== 'message:changed') {
          runHandlers(handlers.get('message:changed'), Object.freeze(Object.assign({}, ev, { type: 'message:changed' })));
        }
        return;
      }
      case 'tavo:vars':
        varCache[d.scope === 'global' ? 'global' : 'chat'] = d.value || {};
        return;
      case 'tavo:emit':
        runHandlers(emitHandlers.get(d.event), d.detail);
        return;
      case 'tavo:intercept':
        runInterceptor(d.event, d.payload || {}).then(function (result) {
          post({ type: 'tavo:reply', id: d.id, result: result });
        });
        return;
      case 'tavo:action': {
        var fn = (handlers.get(d.event) || [])[0];
        if (!fn) { post({ type: 'tavo:reply', id: d.id, result: { ok: false, reason: 'missing-handler' } }); return; }
        Promise.resolve().then(function () { return fn(d.args || undefined); }).then(
          function () { post({ type: 'tavo:reply', id: d.id, result: { ok: true } }); },
          function (err) {
            console.error('[tavo plugin] action', err);
            post({ type: 'tavo:reply', id: d.id, result: { ok: false, reason: 'handler-error', message: String(err && err.message || err) } });
          });
        return;
      }
      case 'tavo:insets':
        insets = Object.freeze(Object.assign({}, insets, d.insets || {}));
        applyInsetVars();
        insetListeners.forEach(function (fn) { try { fn(insets); } catch (err) { console.error(err); } });
        return;
      case 'tavo:i18n':
        if (!i18nState || !d.i18n) return;
        i18nState = d.i18n;
        i18nListeners.forEach(function (fn) {
          try {
            fn(Object.freeze({ requestedLocale: i18nState.requestedLocale, locale: i18nState.locale,
              defaultLocale: i18nState.defaultLocale, supportedLocales: (i18nState.supportedLocales || []).slice() }));
          } catch (err) { console.error(err); }
        });
        return;
    }
  });

  /* ---------- Hit regions (fragments) ---------- */
  // A fragment frame covers the whole chat page, but only the boxes the plugin
  // actually draws may take touches — everything else has to fall through to
  // the chat. The host clips the frame to the rectangles reported here.
  if (!isEntry) {
    var SKIP = { SCRIPT: 1, STYLE: 1, LINK: 1, META: 1, TEMPLATE: 1, NOSCRIPT: 1 };
    var MAX_RECTS = 48;
    var lastKey = '';
    var scheduled = false;
    var collect = function () {
      scheduled = false;
      var rects = [];
      var vw = window.innerWidth, vh = window.innerHeight;
      var walk = function (el, cover) {
        for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
          if (SKIP[c.tagName]) continue;
          var cs = getComputedStyle(c);
          if (cs.display === 'none') continue;
          var r = c.getBoundingClientRect();
          var hit = cs.pointerEvents !== 'none' && cs.visibility === 'visible' &&
            r.width >= 1 && r.height >= 1 && r.right > 0 && r.bottom > 0 && r.left < vw && r.top < vh;
          var inside = cover && r.left >= cover.left && r.top >= cover.top &&
            r.right <= cover.right && r.bottom <= cover.bottom;
          if (hit && !inside) {
            var box = {
              left: Math.max(0, r.left), top: Math.max(0, r.top),
              right: Math.min(vw, r.right), bottom: Math.min(vh, r.bottom),
            };
            rects.push(box);
            walk(c, box);
          } else {
            walk(c, cover);
          }
        }
      };
      if (document.body) walk(document.body, null);
      if (rects.length > MAX_RECTS) {
        var u = rects.reduce(function (a, b) {
          return { left: Math.min(a.left, b.left), top: Math.min(a.top, b.top),
            right: Math.max(a.right, b.right), bottom: Math.max(a.bottom, b.bottom) };
        });
        rects = [u];
      }
      var out = rects.map(function (b) {
        return [Math.floor(b.left), Math.floor(b.top), Math.ceil(b.right - b.left), Math.ceil(b.bottom - b.top)];
      });
      var key = JSON.stringify(out);
      if (key === lastKey) return;
      lastKey = key;
      post({ type: 'tavo:hit', rects: out });
    };
    var schedule = function () {
      if (scheduled) return;
      scheduled = true;
      // Not requestAnimationFrame: Chromium stops rendering a cross-origin
      // frame it considers invisible, and a frame clipped to nothing is.
      setTimeout(collect, 60);
    };
    var observe = function () {
      new MutationObserver(schedule).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true, characterData: false,
      });
      ['resize', 'transitionend', 'animationend', 'scroll', 'pointerup', 'load'].forEach(function (n) {
        window.addEventListener(n, schedule, true);
      });
      schedule();
    };
    if (document.documentElement) observe();
    else document.addEventListener('DOMContentLoaded', observe);
  }

  post({ type: 'tavo:ready' });
})();
