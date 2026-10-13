// Host side of the Glaze plugin runtime (runs in the chat page).
//
// Every plugin script runs in its own `sandbox="allow-scripts"` iframe (null
// origin): one hidden main frame, one frame per chat panel, one per message
// panel and message, and a short-lived frame per file-handler run. Frames
// talk to this host with postMessage; the host knows which plugin (and which
// message) owns each frame window and stamps that identity on every request
// it forwards to Dart (`pluginBridge` handler), so a plugin cannot speak for
// another one.
(function () {
  'use strict';

  var P = 'glaze-plugin:';
  var FRAME_Z = 30;
  var HIT_SLACK_PX = 6;
  var INTERCEPT_CAP_MS = 120000;
  var ACTION_CAP_MS = 600000;
  var FILE_CAP_MS = 600000;

  var sdkSource = '';
  var compatSources = {};
  var plugins = new Map(); // pluginId -> plugin
  var frames = new Map(); // Window -> frame state
  var replySeq = 0;
  var pendingReplies = new Map();
  var insets = { topSafe: 0, topBar: 0, bottomInput: 0, bottomSafe: 0 };
  var messageList = []; // [{id, role}] in chat order
  var busy = false;
  var currentChatId = null;

  /* ---------- Frames ---------- */
  function jsonForScript(value) {
    return JSON.stringify(value)
      .replace(/</g, '\\u003c')
      .replace(/\u2028/g, '\\u2028')
      .replace(/\u2029/g, '\\u2029');
  }

  function scriptTag(source) {
    return '<script>' + String(source).replace(/<\/script/gi, '<\\/script') + '<\/script>';
  }

  function bootFor(plugin, kind, extra) {
    return Object.assign({
      pluginId: plugin.pluginId,
      kind: kind,
      config: plugin.config || {},
      i18n: plugin.i18n || null,
      vars: plugin.vars || { chat: {}, global: {} },
      storage: plugin.storage || {},
      methods: plugin.methods || [],
      insets: insets,
      compat: plugin.compat || null,
      network: plugin.network === true ? true : Array.isArray(plugin.network) ? plugin.network : false,
    }, extra || {});
  }

  // A plugin frame may load from outside only where its network setting
  // says: `true` anywhere, a host list only there, otherwise nowhere.
  // Everything a plugin ships is inlined as data URLs, so it needs none.
  function networkPolicy(network) {
    if (network === true) return null;
    var hosts = '';
    if (Array.isArray(network)) {
      network.forEach(function (h) {
        if (/^(\*\.)?[a-z0-9.-]+$/.test(h)) ['https', 'http', 'wss', 'ws'].forEach(function (scheme) { hosts += ' ' + scheme + '://' + h + ':*'; });
      });
    }
    var local = " data: blob:" + hosts;
    return "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'" + local +
      "; style-src 'unsafe-inline'" + local + "; img-src" + local + "; media-src" + local +
      "; font-src" + local + "; worker-src" + local + "; frame-src" + local +
      "; connect-src " + (hosts ? hosts.slice(1) : "'none'");
  }

  function headScripts(plugin, boot) {
    var policy = networkPolicy(plugin.network);
    var html = (policy ? '<meta http-equiv="Content-Security-Policy" content="' + policy + '">' : '') +
      '<meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">' +
      '<style>html,body{background:transparent!important;margin:0}</style>' +
      '<script>window.__GLAZE_PLUGIN_BOOT__=' + jsonForScript(boot) + ';<\/script>' +
      scriptTag(sdkSource);
    var compat = plugin.compat && compatSources[plugin.compat];
    if (compat) html += scriptTag(compat);
    return html;
  }

  function runScriptsDoc(plugin, boot, sources) {
    var run = '(function(){' + sources.map(function (s) {
      return 'var s=document.createElement("script");s.textContent=' + jsonForScript(s.source +
        '\n//# sourceURL=glaze-plugin://' + plugin.pluginId + '/' + s.name) +
        ';document.head.appendChild(s);';
    }).join('') + '})();';
    return '<!doctype html><html><head>' + headScripts(plugin, boot) +
      '</head><body><script>' + run + '<\/script></body></html>';
  }

  // Panel HTML may be a full document or a bare snippet; the SDK has to run
  // before any of its scripts either way.
  function panelDoc(plugin, boot, html) {
    var head = headScripts(plugin, boot);
    html = String(html || '');
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

  function hiddenStyle(style) {
    style.position = 'fixed';
    style.width = '0';
    style.height = '0';
    style.left = '-10px';
    style.top = '-10px';
    style.visibility = 'hidden';
    style.pointerEvents = 'none';
  }

  function mountFrame(plugin, kind, srcdoc, opts) {
    opts = opts || {};
    var iframe = document.createElement('iframe');
    iframe.setAttribute('sandbox', 'allow-scripts');
    iframe.setAttribute('data-glaze-plugin', plugin.pluginId);
    iframe.setAttribute('data-glaze-plugin-kind', kind);
    iframe.setAttribute('allowtransparency', 'true');
    var style = iframe.style;
    style.border = '0';
    style.background = 'transparent';
    style.colorScheme = 'normal';
    if (kind === 'main' || kind === 'file') {
      iframe.setAttribute('aria-hidden', 'true');
      hiddenStyle(style);
    } else if (kind === 'panel') {
      style.position = 'fixed';
      style.left = '0';
      style.top = '0';
      style.width = '100%';
      style.height = '100%';
      style.zIndex = String(FRAME_Z + (opts.order || 0));
      style.pointerEvents = 'none';
      style.clipPath = 'polygon(0 0, 0 0, 0 0)';
    } else {
      style.display = 'block';
      style.width = '100%';
      style.height = '0';
    }
    iframe.srcdoc = srcdoc;
    // The policy cannot stop a frame from navigating itself to a URL; one
    // that leaves its document without internet access is torn down.
    if (plugin.network !== true) {
      var loads = 0;
      iframe.addEventListener('load', function () {
        if (++loads < 2) return;
        reportNetwork(plugin.pluginId, 'navigation', true);
        removeFrame(state);
      });
    }
    var state = {
      plugin: plugin,
      kind: kind,
      panelId: opts.panelId || null,
      messageId: opts.messageId || null,
      iframe: iframe,
      ready: false,
      queue: [],
      win: null,
    };
    (opts.parent || document.body).appendChild(iframe);
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

  function mainFrame(pluginId) {
    return framesOf(pluginId).filter(function (f) { return f.kind === 'main'; })[0] || null;
  }

  /* ---------- Hit regions (chat panels) ---------- */
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
  function reportNetwork(pluginId, host, blocked) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
    window.flutter_inappwebview.callHandler('pluginNetwork', {
      pluginId: pluginId, host: String(host).slice(0, 253), blocked: !!blocked,
    });
  }

  function callDart(state, method, params) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      return Promise.resolve({ ok: false, error: { code: 'unavailable', message: 'Glaze bridge is not available' } });
    }
    return window.flutter_inappwebview.callHandler('pluginBridge', {
      pluginId: state.plugin.pluginId,
      messageId: state.messageId,
      method: String(method || ''),
      params: params === undefined ? null : params,
    });
  }

  window.addEventListener('message', function (e) {
    var state = frames.get(e.source);
    if (!state) return;
    var d = e.data;
    if (!d || typeof d.type !== 'string' || d.type.indexOf(P) !== 0) return;
    switch (d.type.slice(P.length)) {
      case 'ready':
        state.ready = true;
        state.queue.splice(0).forEach(function (m) { send(state, m); });
        return;
      case 'call':
        Promise.resolve(callDart(state, d.method, d.params)).then(function (res) {
          res = res || {};
          send(state, res.ok === false
            ? { type: P + 'result', id: d.id, ok: false, error: res.error || { message: 'Plugin call failed' } }
            : { type: P + 'result', id: d.id, ok: true, result: res.result });
        }, function (err) {
          send(state, { type: P + 'result', id: d.id, ok: false, error: { message: String(err && err.message || err) } });
        });
        return;
      case 'reply': {
        var resolve = pendingReplies.get(d.id);
        if (resolve) { pendingReplies.delete(d.id); resolve(d.result); }
        return;
      }
      case 'subscribe':
        if (state.kind === 'main') state.plugin.subscriptions.add(String(d.event));
        return;
      case 'emit':
        framesOf(state.plugin.pluginId).forEach(function (f) {
          if (f !== state) send(f, { type: P + 'emit', event: d.event, detail: d.detail });
        });
        return;
      case 'net':
        if (typeof d.host === 'string' && d.host) reportNetwork(state.plugin.pluginId, d.host, d.blocked);
        return;
      case 'hit':
        if (state.kind === 'panel') applyHitRects(state, d.rects);
        return;
      case 'size':
        if (state.kind === 'message') {
          var h = Math.max(0, Math.min(4000, Math.ceil(+d.height || 0)));
          state.iframe.style.height = h + 'px';
        }
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
    var round = function (v) { return Math.round(v * 100) / 100; };
    var next = {
      topSafe: round(safe.top),
      topBar: round(Math.max(safe.top, parseFloat(container.style.paddingTop) || 0)),
      bottomInput: round(Math.max(safe.bottom, parseFloat(container.style.paddingBottom) || 0)),
      bottomSafe: round(safe.bottom),
    };
    if (next.topSafe === insets.topSafe && next.topBar === insets.topBar &&
        next.bottomInput === insets.bottomInput && next.bottomSafe === insets.bottomSafe) return;
    insets = next;
    frames.forEach(function (f) { if (f.kind === 'panel') send(f, { type: P + 'insets', insets: insets }); });
  }

  var insetRaf = 0;
  function scheduleInsets() {
    if (insetRaf) return;
    insetRaf = requestAnimationFrame(function () { insetRaf = 0; refreshInsets(); });
  }

  /* ---------- Message panels and message actions ---------- */
  var messageFrames = new Map(); // key -> frame state
  var reconcileScheduled = false;

  function scheduleReconcile() {
    if (reconcileScheduled) return;
    reconcileScheduled = true;
    requestAnimationFrame(function () { reconcileScheduled = false; reconcileMessages(); });
  }

  function roleOf(section) {
    return section.classList.contains('user') ? 'user'
      : section.classList.contains('char') ? 'character' : 'system';
  }

  function panelMatches(panel, section, messageId) {
    var role = roleOf(section);
    if (role === 'system') return false;
    if (panel.role && panel.role !== role) return false;
    if (panel.position) {
      var ids = messageList.map(function (m) { return m.id; });
      var target = panel.position === 'first' ? ids[0] : ids[ids.length - 1];
      if (target !== messageId) return false;
    }
    return true;
  }

  function slotHost(section, slot) {
    var stack = section.querySelector('.msg-content-stack');
    if (!stack) return null;
    var cls = 'glaze-plugin-slot glaze-plugin-slot-' + slot;
    var host = stack.querySelector(':scope > .glaze-plugin-slot-' + slot);
    if (host) return host;
    host = document.createElement('div');
    host.className = cls;
    var anchor = stack.querySelector(':scope > .msg-transition-wrapper');
    if (slot === 'start') stack.insertBefore(host, anchor || stack.firstChild);
    else if (anchor && anchor.nextSibling) stack.insertBefore(host, anchor.nextSibling);
    else stack.appendChild(host);
    return host;
  }

  function reconcileMessages() {
    var container = document.getElementById('chat-container');
    if (!container) return;
    var seen = new Set();
    var sections = container.querySelectorAll('.message-section[data-message-id]');
    sections.forEach(function (section) {
      var messageId = section.dataset.messageId;
      if (!messageId || section.classList.contains('typing')) return;
      plugins.forEach(function (plugin) {
        (plugin.panels || []).forEach(function (panel) {
          if (panel.placement !== 'message' || !panelMatches(panel, section, messageId)) return;
          var key = plugin.pluginId + '|' + panel.id + '|' + messageId;
          seen.add(key);
          var host = slotHost(section, panel.slot || 'end');
          if (!host) return;
          var existing = messageFrames.get(key);
          if (existing && existing.iframe.isConnected && existing.iframe.parentNode === host) return;
          if (existing) removeFrame(existing);
          var boot = bootFor(plugin, 'message', { panelId: panel.id, messageId: messageId });
          messageFrames.set(key, mountFrame(plugin, 'message', panelDoc(plugin, boot, panel.html), {
            panelId: panel.id, messageId: messageId, parent: host,
          }));
        });
      });
      renderMessageActions(section, messageId);
    });
    messageFrames.forEach(function (state, key) {
      if (!seen.has(key)) { removeFrame(state); messageFrames.delete(key); }
    });
  }

  function lastMessage() {
    return messageList.length ? messageList[messageList.length - 1] : null;
  }

  function renderMessageActions(section, messageId) {
    var old = section.querySelector('.glaze-plugin-msg-actions');
    var last = lastMessage();
    var role = roleOf(section);
    var actions = [];
    if (!busy && last && last.id === messageId && role !== 'system') {
      plugins.forEach(function (plugin) {
        (plugin.messageActions || []).forEach(function (a) {
          if (a.role === 'any' || a.role === role) actions.push({ plugin: plugin, action: a });
        });
      });
    }
    var signature = actions.map(function (x) { return x.plugin.pluginId + ':' + x.action.id + ':' + x.action.label; }).join('|');
    if (old && old.dataset.signature === signature) return;
    if (old) old.remove();
    if (!actions.length) return;
    var trailing = section.querySelector('.msg-footer .msg-trailing-actions');
    if (!trailing) return;
    var row = document.createElement('div');
    row.className = 'glaze-plugin-msg-actions';
    row.dataset.signature = signature;
    row.style.cssText = 'display:inline-flex;gap:4px;align-items:center;margin-right:4px';
    actions.forEach(function (x) {
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.title = x.action.label;
      btn.setAttribute('aria-label', x.action.label);
      // Same look as the footer's translate button.
      btn.style.cssText = 'width:28px;height:28px;box-sizing:border-box;padding:4px;' +
        'display:flex;align-items:center;justify-content:center;cursor:pointer;' +
        'color:var(--text-gray);font-family:inherit;font-size:13px;font-weight:600;line-height:1;border-radius:50%;' +
        'border:1px solid rgba(255,255,255,0.1);' +
        'background-color:rgba(var(--ui-bg-rgb),var(--element-opacity,0.8));' +
        'backdrop-filter:blur(var(--element-blur,12px));-webkit-backdrop-filter:blur(var(--element-blur,12px))';
      if (x.action.icon) {
        var img = document.createElement('img');
        img.src = x.action.icon;
        img.alt = '';
        img.style.cssText = 'width:100%;height:100%;object-fit:contain;pointer-events:none';
        btn.appendChild(img);
      } else {
        btn.textContent = x.action.label.slice(0, 1);
      }
      btn.addEventListener('click', function (ev) {
        ev.stopPropagation();
        if (row.dataset.pending) return;
        row.dataset.pending = '1';
        row.style.opacity = '.4';
        runAction(x.plugin.pluginId, 'action:message:' + x.action.id, {
          chatId: currentChatId, messageId: messageId, role: roleOf(section),
        }).then(function (result) {
          delete row.dataset.pending;
          row.style.opacity = '';
          if (window.flutter_inappwebview && result && !result.ok) {
            window.flutter_inappwebview.callHandler('pluginActionFailed', {
              pluginId: x.plugin.pluginId, reason: result.reason || null, message: result.message || null,
            });
          }
        });
      });
      row.appendChild(btn);
    });
    trailing.insertBefore(row, trailing.firstChild);
  }

  function watchDom() {
    var container = document.getElementById('chat-container');
    if (container && typeof MutationObserver === 'function') {
      new MutationObserver(scheduleInsets).observe(container, { attributes: true, attributeFilter: ['style'] });
      new MutationObserver(function () { if (plugins.size) scheduleReconcile(); })
        .observe(container, { childList: true, subtree: true });
    }
    window.addEventListener('resize', scheduleInsets);
    refreshInsets();
  }

  /* ---------- Public API (called from Dart) ---------- */
  function teardown() {
    frames.forEach(removeFrame);
    frames.clear();
    messageFrames.clear();
    plugins.clear();
    pendingReplies.forEach(function (resolve) { resolve(null); });
    pendingReplies.clear();
    document.querySelectorAll('.glaze-plugin-slot,.glaze-plugin-msg-actions').forEach(function (el) { el.remove(); });
  }

  function setup(payload) {
    payload = payload || {};
    teardown();
    if (typeof payload.sdk === 'string') sdkSource = payload.sdk;
    compatSources = payload.compat || {};
    refreshInsets();
    (payload.plugins || []).forEach(function (p) {
      var plugin = Object.assign({}, p, { subscriptions: new Set() });
      plugins.set(plugin.pluginId, plugin);
      if (typeof plugin.main === 'string' && plugin.main) {
        mountFrame(plugin, 'main', runScriptsDoc(plugin, bootFor(plugin, 'main'), [{ name: 'main.js', source: plugin.main }]));
      }
      (plugin.panels || []).forEach(function (panel) {
        if (panel.placement !== 'chat') return;
        mountFrame(plugin, 'panel', panelDoc(plugin, bootFor(plugin, 'panel', { panelId: panel.id }), panel.html), {
          panelId: panel.id, order: panel.order,
        });
      });
    });
    scheduleReconcile();
    return plugins.size;
  }

  function dispatchEvent(type, payload, onlyPluginId) {
    var msg = { type: P + 'event', event: String(type), payload: payload || {} };
    frames.forEach(function (f) {
      if (f.kind === 'file') return;
      if (!onlyPluginId || f.plugin.pluginId === onlyPluginId) send(f, msg);
    });
  }

  function pushVars(scope, value) {
    frames.forEach(function (f) { send(f, { type: P + 'vars', scope: scope, value: value || {} }); });
  }

  function setMessages(list, isBusy, chatId) {
    messageList = Array.isArray(list) ? list : [];
    busy = !!isBusy;
    currentChatId = chatId || null;
    scheduleReconcile();
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
      var main = mainFrame(plugin.pluginId);
      if (!main) continue;
      var cap = type === 'generation:prepare' ? INTERCEPT_CAP_MS : 30000;
      var result = await ask(main, { type: P + 'intercept', event: type, payload: Object.assign({}, payload, { text: text }) }, cap);
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
    var main = mainFrame(pluginId);
    if (!main) return { ok: false, reason: 'runtime-not-ready' };
    var result = await ask(main, { type: P + 'action', event: String(event), args: args || null }, ACTION_CAP_MS);
    return result || { ok: false, reason: 'timeout' };
  }

  // Runs a file handler: in the main frame when it was registered there, or
  // in a fresh hidden frame running the handler's own scripts.
  async function runFileHandler(pluginId, handlerId, file, scripts) {
    var plugin = plugins.get(pluginId);
    if (!plugin) return { ok: false, error: { code: 'runtime-not-ready', message: 'Plugin is not running' } };
    var frame = null;
    if (Array.isArray(scripts) && scripts.length) {
      frame = mountFrame(plugin, 'file', runScriptsDoc(plugin, bootFor(plugin, 'file'), scripts));
    }
    var target = frame || mainFrame(pluginId);
    if (!target) return { ok: false, error: { code: 'runtime-not-ready', message: 'Plugin is not running' } };
    try {
      var result = await ask(target, { type: P + 'file', handlerId: handlerId, file: file }, FILE_CAP_MS);
      return result || { ok: false, error: { code: 'timeout', message: 'The file took too long to process' } };
    } finally {
      if (frame) removeFrame(frame);
    }
  }

  function updateLocalization(list) {
    (list || []).forEach(function (item) {
      var plugin = plugins.get(item.pluginId);
      if (!plugin) return;
      plugin.i18n = item.i18n;
      if (item.messageActions) plugin.messageActions = item.messageActions;
      framesOf(item.pluginId).forEach(function (f) { send(f, { type: P + 'i18n', i18n: item.i18n }); });
    });
    document.querySelectorAll('.glaze-plugin-msg-actions').forEach(function (el) { el.remove(); });
    scheduleReconcile();
  }

  window.glazePlugins = Object.freeze({
    setup: setup,
    teardown: teardown,
    dispatchEvent: dispatchEvent,
    pushVars: pushVars,
    setMessages: setMessages,
    intercept: intercept,
    hasSubscribers: hasSubscribers,
    runAction: runAction,
    runFileHandler: runFileHandler,
    updateLocalization: updateLocalization,
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchDom);
  else watchDom();
})();
