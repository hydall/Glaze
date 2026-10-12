// Host side of the Tavo-compatible plugin runtime.
//
// Each enabled plugin gets one hidden entry frame (its `entry` script) and one
// frame per `/chat` HTML fragment. Every frame is `sandbox="allow-scripts"`
// without `allow-same-origin`: plugin code never runs in the chat page and
// cannot reach `flutter_inappwebview`. Frames talk to this host with
// postMessage; the host knows which plugin owns each frame window and stamps
// that identity on the request it forwards to Dart (`tavoBridge` handler), so
// a plugin cannot speak for another one.
(function () {
  'use strict';

  var FRAME_Z = 30;
  var HIT_SLACK_PX = 6;
  var INTERCEPT_CAP_MS = 120000;
  var ACTION_CAP_MS = 600000;

  var sdkSource = '';
  var methods = [];
  var plugins = new Map(); // pluginId -> PluginState
  var frames = new Map(); // Window -> FrameState
  var replySeq = 0;
  var pendingReplies = new Map(); // id -> resolve
  var insets = { topSafe: 0, topBar: 0, bottomInput: 0, bottomSafe: 0 };

  /* ---------- Frames ---------- */
  function jsonForScript(value) {
    return JSON.stringify(value)
      .replace(/</g, '\\u003c')
      .replace(/\u2028/g, '\\u2028')
      .replace(/\u2029/g, '\\u2029');
  }

  function bootFor(plugin, surface, fragmentId) {
    return {
      pluginId: plugin.pluginId,
      surface: surface,
      fragmentId: fragmentId || null,
      config: plugin.config || {},
      i18n: plugin.i18n || null,
      vars: plugin.vars || { chat: {}, global: {} },
      storage: plugin.storage || {},
      methods: plugin.methods || methods,
      insets: insets,
    };
  }

  function headScripts(boot) {
    return '<meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">' +
      '<style>html,body{background:transparent!important;margin:0}</style>' +
      '<script>window.__TAVO_BOOT__=' + jsonForScript(boot) + ';<\/script>' +
      '<script>' + sdkSource.replace(/<\/script/gi, '<\\/script') + '<\/script>';
  }

  function entrySrcdoc(plugin) {
    var run = '(function(){var s=document.createElement("script");s.textContent=' +
      jsonForScript(plugin.entry + '\n//# sourceURL=tavo-plugin://' + plugin.pluginId + '/entry.js') +
      ';document.head.appendChild(s);})();';
    return '<!doctype html><html><head>' + headScripts(bootFor(plugin, 'entry')) +
      '</head><body><script>' + run + '<\/script></body></html>';
  }

  // Fragment HTML may be a full document or a bare snippet; the SDK has to run
  // before any of its scripts either way.
  function fragmentSrcdoc(plugin, fragment) {
    var head = headScripts(bootFor(plugin, 'fragment', fragment.id));
    var html = String(fragment.html || '');
    var headTag = /<head(\s[^>]*)?>/i.exec(html);
    if (headTag) {
      var at = headTag.index + headTag[0].length;
      return html.slice(0, at) + head + html.slice(at);
    }
    var htmlTag = /<html(\s[^>]*)?>/i.exec(html);
    if (htmlTag) {
      var after = htmlTag.index + htmlTag[0].length;
      return html.slice(0, after) + '<head>' + head + '</head>' + html.slice(after);
    }
    return '<!doctype html><html><head>' + head + '</head><body>' + html + '</body></html>';
  }

  function createFrame(plugin, surface, fragment) {
    var iframe = document.createElement('iframe');
    iframe.setAttribute('sandbox', 'allow-scripts');
    iframe.setAttribute('data-glaze-plugin', plugin.pluginId);
    iframe.setAttribute('aria-hidden', surface === 'entry' ? 'true' : 'false');
    iframe.setAttribute('allowtransparency', 'true');
    var style = iframe.style;
    style.border = '0';
    style.background = 'transparent';
    style.colorScheme = 'normal';
    if (surface === 'entry') {
      style.position = 'fixed';
      style.width = '0';
      style.height = '0';
      style.left = '-10px';
      style.top = '-10px';
      style.visibility = 'hidden';
      style.pointerEvents = 'none';
    } else {
      style.position = 'fixed';
      style.left = '0';
      style.top = '0';
      style.width = '100%';
      style.height = '100%';
      style.zIndex = String(FRAME_Z + (fragment.order || 0));
      style.pointerEvents = 'none';
      style.clipPath = 'polygon(0 0, 0 0, 0 0)';
    }
    iframe.srcdoc = surface === 'entry' ? entrySrcdoc(plugin) : fragmentSrcdoc(plugin, fragment);
    var state = {
      plugin: plugin,
      surface: surface,
      fragmentId: fragment ? fragment.id : null,
      iframe: iframe,
      ready: false,
      queue: [],
      win: null,
    };
    document.body.appendChild(iframe);
    state.win = iframe.contentWindow;
    frames.set(state.win, state);
    return state;
  }

  function removeFrame(state) {
    frames.delete(state.win);
    try { state.iframe.remove(); } catch (e) { /* already detached */ }
  }

  function send(state, msg) {
    if (!state.ready) { state.queue.push(msg); return; }
    try { state.win.postMessage(msg, '*'); } catch (e) { /* frame gone */ }
  }

  function framesOf(pluginId) {
    var out = [];
    frames.forEach(function (f) { if (f.plugin.pluginId === pluginId) out.push(f); });
    return out;
  }

  /* ---------- Hit regions ---------- */
  function applyHitRects(state, rects) {
    var style = state.iframe.style;
    if (!Array.isArray(rects) || !rects.length) {
      style.clipPath = 'polygon(0 0, 0 0, 0 0)';
      style.pointerEvents = 'none';
      return;
    }
    // A few px of slack keeps soft shadows and glows from being cut square.
    var pad = HIT_SLACK_PX;
    var path = rects.map(function (r) {
      var x = Math.max(0, (+r[0] || 0) - pad), y = Math.max(0, (+r[1] || 0) - pad);
      var w = Math.max(0, +r[2] || 0) + 2 * pad, h = Math.max(0, +r[3] || 0) + 2 * pad;
      return 'M' + x + ' ' + y + 'h' + w + 'v' + h + 'h' + (-w) + 'Z';
    }).join(' ');
    style.clipPath = 'path(\'' + path + '\')';
    style.pointerEvents = 'auto';
  }

  /* ---------- Dart transport ---------- */
  function callDart(state, method, params) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      return Promise.resolve({ ok: false, error: { code: 'runtime_unavailable', message: 'Glaze bridge is not available' } });
    }
    return window.flutter_inappwebview.callHandler('tavoBridge', {
      pluginId: state.plugin.pluginId,
      surface: state.surface,
      fragmentId: state.fragmentId,
      method: String(method || ''),
      params: params === undefined ? null : params,
    });
  }

  window.addEventListener('message', function (e) {
    var state = frames.get(e.source);
    if (!state) return;
    var d = e.data;
    if (!d || typeof d.type !== 'string' || d.type.indexOf('tavo:') !== 0) return;
    switch (d.type) {
      case 'tavo:ready':
        state.ready = true;
        state.queue.splice(0).forEach(function (m) { send(state, m); });
        return;
      case 'tavo:call':
        Promise.resolve(callDart(state, d.method, d.params)).then(function (res) {
          res = res || {};
          send(state, res.ok === false
            ? { type: 'tavo:result', id: d.id, ok: false, error: res.error || { message: 'Tavo call failed' } }
            : { type: 'tavo:result', id: d.id, ok: true, result: res.result });
        }, function (err) {
          send(state, { type: 'tavo:result', id: d.id, ok: false, error: { message: String(err && err.message || err) } });
        });
        return;
      case 'tavo:reply': {
        var resolve = pendingReplies.get(d.id);
        if (resolve) { pendingReplies.delete(d.id); resolve(d.result); }
        return;
      }
      case 'tavo:subscribe':
        if (state.surface === 'entry') state.plugin.subscriptions.add(String(d.event));
        return;
      case 'tavo:emit':
        framesOf(state.plugin.pluginId).forEach(function (f) {
          if (f !== state) send(f, { type: 'tavo:emit', event: d.event, detail: d.detail });
        });
        return;
      case 'tavo:hit':
        if (state.surface === 'fragment') applyHitRects(state, d.rects);
        return;
    }
  });

  function ask(state, msg, capMs) {
    return new Promise(function (resolve) {
      var id = 'r' + (++replySeq);
      var timer = capMs ? setTimeout(function () {
        pendingReplies.delete(id);
        resolve(null);
      }, capMs) : null;
      pendingReplies.set(id, function (result) {
        if (timer) clearTimeout(timer);
        resolve(result);
      });
      send(state, Object.assign({ id: id }, msg));
    });
  }

  /* ---------- Insets ---------- */
  var safeProbe = null;
  function readSafeArea() {
    if (!safeProbe) {
      safeProbe = document.createElement('div');
      safeProbe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;' +
        'padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)';
      document.body.appendChild(safeProbe);
    }
    var cs = getComputedStyle(safeProbe);
    return { top: parseFloat(cs.paddingTop) || 0, bottom: parseFloat(cs.paddingBottom) || 0 };
  }

  function refreshInsets() {
    var container = document.getElementById('chat-container');
    if (!container) return;
    var safe = readSafeArea();
    var next = {
      topSafe: Math.round(safe.top * 100) / 100,
      topBar: Math.round(Math.max(safe.top, parseFloat(container.style.paddingTop) || 0) * 100) / 100,
      bottomInput: Math.round(Math.max(safe.bottom, parseFloat(container.style.paddingBottom) || 0) * 100) / 100,
      bottomSafe: Math.round(safe.bottom * 100) / 100,
    };
    if (next.topSafe === insets.topSafe && next.topBar === insets.topBar &&
        next.bottomInput === insets.bottomInput && next.bottomSafe === insets.bottomSafe) return;
    insets = next;
    frames.forEach(function (f) { if (f.surface === 'fragment') send(f, { type: 'tavo:insets', insets: insets }); });
  }

  var insetRaf = 0;
  function scheduleInsets() {
    if (insetRaf) return;
    insetRaf = requestAnimationFrame(function () { insetRaf = 0; refreshInsets(); });
  }

  function watchInsets() {
    var container = document.getElementById('chat-container');
    if (container && typeof MutationObserver === 'function') {
      new MutationObserver(scheduleInsets).observe(container, { attributes: true, attributeFilter: ['style'] });
    }
    window.addEventListener('resize', scheduleInsets);
    refreshInsets();
  }

  /* ---------- Public API (called from Dart) ---------- */
  function teardown() {
    frames.forEach(removeFrame);
    frames.clear();
    plugins.clear();
    pendingReplies.forEach(function (resolve) { resolve(null); });
    pendingReplies.clear();
  }

  function setup(payload) {
    payload = payload || {};
    teardown();
    if (typeof payload.sdk === 'string') sdkSource = payload.sdk;
    methods = Array.isArray(payload.methods) ? payload.methods.slice() : methods;
    refreshInsets();
    (payload.plugins || []).forEach(function (p) {
      var plugin = Object.assign({}, p, { subscriptions: new Set() });
      plugins.set(plugin.pluginId, plugin);
      if (typeof plugin.entry === 'string' && plugin.entry) createFrame(plugin, 'entry', null);
      (plugin.fragments || []).forEach(function (fragment) { createFrame(plugin, 'fragment', fragment); });
    });
    return plugins.size;
  }

  function dispatchEvent(type, payload, onlyPluginId) {
    var msg = { type: 'tavo:event', event: String(type), payload: payload || {} };
    frames.forEach(function (f) {
      if (!onlyPluginId || f.plugin.pluginId === onlyPluginId) send(f, msg);
    });
  }

  function pushVars(scope, value) {
    frames.forEach(function (f) { send(f, { type: 'tavo:vars', scope: scope, value: value || {} }); });
  }

  // Runs a blocking hook through every subscribed plugin in setup order.
  // Resolves `{ text, cancelled, cancelledBy?, message? }`.
  async function intercept(type, payload) {
    payload = Object.assign({}, payload || {});
    var text = typeof payload.text === 'string' ? payload.text : '';
    var order = Array.from(plugins.values());
    for (var i = 0; i < order.length; i++) {
      var plugin = order[i];
      if (!plugin.subscriptions.has(type)) continue;
      var entry = framesOf(plugin.pluginId).filter(function (f) { return f.surface === 'entry'; })[0];
      if (!entry) continue;
      var cap = type === 'generation:prepare' ? INTERCEPT_CAP_MS : 30000;
      var result = await ask(entry, { type: 'tavo:intercept', event: type, payload: Object.assign({}, payload, { text: text }) }, cap);
      if (!result || typeof result.text !== 'string') continue;
      text = result.text;
      if (result.cancelled) {
        return { text: text, cancelled: true, cancelledBy: plugin.pluginId, message: result.message || null };
      }
    }
    return { text: text, cancelled: false };
  }

  function hasSubscribers(type) {
    var found = false;
    plugins.forEach(function (p) { if (p.subscriptions.has(type)) found = true; });
    return found;
  }

  async function runAction(pluginId, event, args) {
    var entry = framesOf(pluginId).filter(function (f) { return f.surface === 'entry'; })[0];
    if (!entry) return { ok: false, reason: 'runtime-not-ready' };
    var result = await ask(entry, { type: 'tavo:action', event: String(event), args: args || null }, ACTION_CAP_MS);
    return result || { ok: false, reason: 'timeout' };
  }

  function updateLocalization(list) {
    (list || []).forEach(function (item) {
      var plugin = plugins.get(item.pluginId);
      if (!plugin) return;
      plugin.i18n = item.i18n;
      framesOf(item.pluginId).forEach(function (f) { send(f, { type: 'tavo:i18n', i18n: item.i18n }); });
    });
  }

  window.glazePlugins = Object.freeze({
    setup: setup,
    teardown: teardown,
    dispatchEvent: dispatchEvent,
    pushVars: pushVars,
    intercept: intercept,
    hasSubscribers: hasSubscribers,
    runAction: runAction,
    updateLocalization: updateLocalization,
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchInsets);
  else watchInsets();
})();
