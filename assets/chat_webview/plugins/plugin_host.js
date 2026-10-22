// Host side of the Glaze plugin runtime (runs in the chat page).
//
// Every plugin script runs in its own `sandbox="allow-scripts"` iframe (null
// origin): one hidden main frame, one frame per chat panel, one per message
// panel and message, and a short-lived frame per file-handler run. A frame's
// document is built here and loaded from the plugin's package address on the
// app's package server (`frames.open`), so the plugin's own files load as on
// the web; without the server it is made inline (srcdoc). A plugin whose
// main script shares one page with its chat panels (`onePage`: Tavo runs
// both in its chat page) gets one frame for all of them instead. Frames
// talk to this host with postMessage; the host knows which plugin (and which
// message) owns each frame window and stamps that identity on every request
// it forwards to Dart (`pluginBridge` handler), so a plugin cannot speak for
// another one.
//
// Where the app can lay a second, transparent WebView over its own controls
// (the plugin layer, `plugin_layer.html`), chat panels live there instead, so
// they draw over the header and the message box rather than under them. Both
// pages then run this host: `setup` says which `layer` this page is, and what
// crosses between them (emits, insets) goes through Dart.
(function () {
  'use strict';

  // Message type prefix, new for every setup: the frames learn it from
  // their boot data, and nothing in it names the app.
  var P = 'p0:';
  var FRAME_Z = 30;
  var HIT_SLACK_PX = 6;
  var INTERCEPT_CAP_MS = 120000;
  var ACTION_CAP_MS = 600000;
  var FILE_CAP_MS = 600000;

  var EVENT_KINDS = ['send', 'generation', 'chat', 'message'];
  var sdkSource = '';
  var compatSources = {};
  var rtcToken = null;
  var plugins = new Map(); // pluginId -> plugin
  var frames = new Map(); // plugin Window -> frame state
  var wrappers = new Map(); // wrapper Window -> frame state
  var replySeq = 0;
  var pendingReplies = new Map();
  var insets = { topSafe: 0, topBar: 0, bottomInput: 0, bottomSafe: 0, keyboard: 0 };
  var messageList = []; // [{id, role}] in chat order
  var busy = false;
  var currentChatId = null;
  // 'all': every frame here. 'chat': all but chat panels, which are in the
  // plugin layer. 'panels': this is the plugin layer, chat panels only.
  var layer = 'all';

  /* ---------- Over the chat chrome ---------- */
  // The header and the message box are drawn in this page too, in the top
  // layer (assets/chat_webview/chrome). Chat panels go over them, as they go
  // over the app's controls where they are in the plugin layer: shown in the
  // top layer after the chrome, in their own order. The chrome raises
  // itself back over anything else that enters the top layer, but not over
  // these, and puts them back on top whenever it does.
  var showPopoverFn = typeof HTMLElement.prototype.showPopover === 'function'
    ? HTMLElement.prototype.showPopover : null;
  var hidePopoverFn = showPopoverFn ? HTMLElement.prototype.hidePopover : null;
  var matchesFn = Element.prototype.matches;
  var panelFrames = new WeakSet();

  function panelsInTopLayer() {
    return layer === 'all' && !!showPopoverFn;
  }

  function raisePanels() {
    if (!panelsInTopLayer()) return;
    var list = [];
    wrappers.forEach(function (f) { if (f.kind === 'panel') list.push(f); });
    list.sort(function (a, b) { return (a.order || 0) - (b.order || 0); });
    list.forEach(function (f) {
      var el = f.iframe;
      if (!el.isConnected) return;
      try {
        if (matchesFn.call(el, ':popover-open')) hidePopoverFn.call(el);
        showPopoverFn.call(el);
      } catch (e) { /* not a popover (any more) */ }
    });
  }

  Object.defineProperty(window, '__glazePluginPanels', {
    value: Object.freeze({
      has: function (el) { return panelFrames.has(el); },
      raise: raisePanels,
    }),
    writable: false,
    configurable: false,
    enumerable: false,
  });

  function callHandler(name, arg) {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler(name, arg);
    }
  }

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
      channel: P,
      vars: plugin.vars || { chat: {}, global: {} },
      storage: plugin.storage || {},
      storageQuota: plugin.storageQuota || 0,
      methods: plugin.methods || [],
      insets: insets,
      compat: plugin.compat || null,
      network: plugin.network === true ? true : Array.isArray(plugin.network) ? plugin.network : false,
      localNetwork: plugin.network !== false && plugin.localNetwork === true,
      // The address of the plugin's own files ('…/plugins/<id>/'), or null.
      package: packageOf(plugin),
      // Only a plugin that may reach any host gets WebRTC back.
      rtcToken: plugin.network === true ? rtcToken : null,
    }, extra || {});
  }

  // Hosts on the user's own network: loopback, private and link-local
  // addresses and the names that only resolve inside a network.
  function isLocalHost(host) {
    host = String(host).toLowerCase().replace(/^\[|\]$/g, '');
    if (host === 'localhost' || /\.(localhost|local|lan|home\.arpa|internal)$/.test(host)) return true;
    var v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(host);
    if (v4) {
      var a = +v4[1], b = +v4[2];
      return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b < 128) ||
        (a === 169 && b === 254) || (a === 172 && b >= 16 && b < 32) || (a === 192 && b === 168) || a >= 224;
    }
    if (host.indexOf(':') >= 0) {
      return host === '::' || host === '::1' || /^(fc|fd|fe[89ab]|ff)/.test(host) || /^::ffff:/.test(host);
    }
    return false;
  }

  // A plugin frame may load from outside only where its network setting
  // says: `true` anywhere, a host list only there, otherwise nowhere.
  // Without local network access only https/wss go out, which keeps the
  // frame away from home devices (they rarely speak TLS), and listed hosts
  // on the local network are dropped.
  // A plugin's own package (its path on the package server) is always in
  // reach, and only its own: the policy names the path.
  // The source list a plugin may reach outside, '' for none; null when
  // nothing is restricted.
  function reachable(network, local, pkg) {
    if (network === true && local) return null;
    var schemes = local ? ['https', 'http', 'wss', 'ws'] : ['https', 'wss'];
    var hosts = pkg ? ' ' + pkg : '';
    if (network === true) {
      hosts = ' https: wss:';
    } else if (Array.isArray(network)) {
      network.forEach(function (h) {
        if (!/^(\*\.)?[a-z0-9.-]+$/.test(h)) return;
        if (!local && isLocalHost(h.replace(/^\*\./, ''))) return;
        schemes.forEach(function (scheme) { hosts += ' ' + scheme + '://' + h + ':*'; });
      });
    }
    return hosts;
  }

  // The package address of [plugin] when it is served: '<origin>/plugins/<id>/'.
  function packageOf(plugin) {
    var pkg = plugin.package;
    if (typeof pkg !== 'string' || !/^http:\/\/127\.0\.0\.1:\d+\/plugins\/[a-z0-9._-]+\/$/.test(pkg)) return null;
    return pkg.slice(pkg.indexOf('/plugins/') + 9, -1) === plugin.pluginId ? pkg : null;
  }

  // [media] are app origins a frame may show pictures and sound from (the
  // ExtBlocks page shows the chat's generated images); nothing else of the
  // page may load from them.
  function networkPolicy(network, local, pkg, media) {
    var hosts = reachable(network, local, pkg);
    if (hosts === null) return null;
    var outside = " data: blob:" + hosts;
    var shown = outside + (media || []).map(function (o) { return ' ' + o; }).join('');
    return "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'" + outside +
      "; style-src 'unsafe-inline'" + outside + "; img-src" + shown + "; media-src" + shown +
      "; font-src" + outside + "; worker-src" + outside + "; frame-src" + outside +
      "; connect-src " + (hosts ? hosts.slice(1) : "'none'");
  }

  // Loopback origins of the app's own file server, as the payload names them.
  function mediaOf(plugin) {
    return (Array.isArray(plugin.mediaOrigins) ? plugin.mediaOrigins : []).filter(function (o) {
      return typeof o === 'string' && /^https?:\/\/(127\.0\.0\.1|localhost):\d+$/.test(o);
    });
  }

  function headScripts(plugin, boot) {
    var policy = networkPolicy(plugin.network, boot.localNetwork, packageOf(plugin), mediaOf(plugin));
    var html = (policy ? '<meta http-equiv="Content-Security-Policy" content="' + policy + '">' : '') +
      '<meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">' +
      '<style>html,body{background:transparent!important;margin:0}</style>' +
      '<script>window.__pluginBoot=' + jsonForScript(boot) + ';<\/script>' +
      scriptTag(sdkSource);
    var compat = plugin.compat && compatSources[plugin.compat];
    if (compat) html += scriptTag(compat);
    return html;
  }

  function runScriptsDoc(plugin, boot, sources) {
    var run = '(function(){document.currentScript.remove();' + sources.map(function (s) {
      return 'var s=document.createElement("script");s.textContent=' + jsonForScript(s.source +
        '\n//# sourceURL=plugin://' + plugin.pluginId + '/' + s.name) +
        ';document.head.appendChild(s);';
    }).join('') + '})();';
    return '<!doctype html><html><head>' + headScripts(plugin, boot) +
      '</head><body><script>' + run + '<\/script></body></html>';
  }

  // Panel HTML may be a full document or a bare snippet. The policy and the
  // SDK go first either way, right after a leading doctype: anything the
  // page has before its <head> would otherwise run unrestricted. The
  // parser keeps them in the head the page's own <html>/<head> then join.
  function panelDoc(plugin, boot, html) {
    var head = headScripts(plugin, boot);
    html = String(html || '');
    if (!/<(html|head)(\s[^>]*)?>/i.test(html)) {
      return '<!doctype html><html><head>' + head + '</head><body>' + html + '</body></html>';
    }
    var doctype = /^\s*<!doctype[^>]*>/i.exec(html);
    var at = doctype ? doctype[0].length : 0;
    return html.slice(0, at) + head + html.slice(at);
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

  function attr(value) {
    return String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;');
  }

  // A plugin frame sits inside a wrapper frame of its own. A frame's
  // navigations are checked against its parent's policy, which a frame
  // cannot change: with the plugin's own policy on the wrapper, a plugin
  // that leaves its document for a URL (say, with the chat in the query) is
  // stopped before the request goes out, unless its internet setting
  // reaches that host anyway. The plugin's document inherits that policy
  // too, so it must be the same one.
  // [doc] is the plugin's document inline, or `{ url }` to load it from.
  function wrapperDoc(plugin, doc, local) {
    var policy = networkPolicy(plugin.network, local, packageOf(plugin), mediaOf(plugin));
    var inner = typeof doc === 'string' ? 'srcdoc="' + attr(doc) + '"' : 'src="' + attr(doc.url) + '"';
    return '<!doctype html><html><head>' +
      (policy ? '<meta http-equiv="Content-Security-Policy" content="' + policy + '">' : '') +
      '<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent!important;color-scheme:normal}' +
      'iframe{display:block;border:0;width:100%;height:100%;background:transparent;color-scheme:normal}</style></head>' +
      '<body><iframe sandbox="allow-scripts" allowtransparency="true" ' + inner + '></iframe>' +
      // A second load means the plugin left its document (the policy
      // decided whether the new one loaded); the host takes the frame down.
      '<script>(function(){var n=0;document.querySelector("iframe").addEventListener("load",function(){' +
      'if(++n>1)parent.postMessage({type:' + jsonForScript(P + 'gone') + '},"*");});})();<\/script></body></html>';
  }

  // Mounts a frame for [doc], loaded from [path] in the plugin's package when
  // the package is served. The frame state is there at once; the page comes
  // when the server has the document.
  function mountFrame(plugin, kind, doc, path, opts) {
    opts = opts || {};
    var iframe = document.createElement('iframe');
    // Scripts are allowed so the inner frame keeps them; the wrapper has none.
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
      style.clipPath = layer === 'panels' ? 'none' : 'polygon(0 0, 0 0, 0 0)';
      if (panelsInTopLayer()) {
        // A popover's UA box (margin: auto, padding, border, a Canvas
        // background) would take the frame off the edges.
        iframe.setAttribute('popover', 'manual');
        style.margin = '0';
        style.padding = '0';
        style.inset = '0';
        style.maxWidth = 'none';
        style.maxHeight = 'none';
        style.overflow = 'visible';
        panelFrames.add(iframe);
      }
    } else {
      style.display = 'block';
      style.width = '100%';
      style.height = '0';
    }
    var local = plugin.network !== false && plugin.localNetwork === true;
    var state = {
      plugin: plugin,
      kind: kind,
      panelId: opts.panelId || null,
      order: opts.order || 0,
      messageId: opts.messageId || null,
      iframe: iframe,
      ready: false,
      queue: [],
      win: null,
    };
    (opts.parent || document.body).appendChild(iframe);
    // The plugin's own window is known once the wrapper has parsed; it is
    // bound when it first posts (see frameOf).
    state.wrapper = iframe.contentWindow;
    wrappers.set(state.wrapper, state);
    var load = function (url) {
      if (state.removed) return;
      iframe.srcdoc = wrapperDoc(plugin, typeof url === 'string' && url ? { url: url } : doc, local);
    };
    if (!packageOf(plugin)) {
      load(null);
    } else {
      Promise.resolve(callDart(state, 'frames.open', [String(path || ''), doc])).then(function (res) {
        load(res && res.ok !== false ? res.result : null);
      }, function () { load(null); });
    }
    return state;
  }

  // The frame state of [win]: a bound plugin window, or the one window of a
  // wrapper the first time it posts.
  function frameOf(win) {
    var state = frames.get(win);
    if (state) return state;
    var up;
    try { up = win.parent; } catch (e) { return null; }
    state = wrappers.get(up);
    if (!state || state.win) return null;
    var inner;
    try { inner = up.frames[0]; } catch (e) { return null; }
    if (inner !== win) return null;
    state.win = win;
    frames.set(win, state);
    return state;
  }

  function removeFrame(state) {
    state.removed = true;
    if (state.win) frames.delete(state.win);
    wrappers.delete(state.wrapper);
    if (fitted === state) fitted = null;
    try { state.iframe.remove(); } catch (e) { /* already detached */ }
    if (state.holes) { refreshClips(); scheduleHoles(); }
  }

  function send(state, msg) {
    if (!state.ready) { state.queue.push(msg); return; }
    try { state.win.postMessage(msg, '*'); } catch (e) { /* frame gone */ }
  }

  function framesOf(pluginId) {
    var out = [];
    wrappers.forEach(function (f) { if (f.plugin.pluginId === pluginId) out.push(f); });
    return out;
  }

  // The frame running the plugin's main script: its own, or the one page it
  // shares with the chat panels.
  function mainFrame(pluginId) {
    return framesOf(pluginId).filter(isMain)[0] || null;
  }

  function isMain(f) { return f.kind === 'main' || f.hostsMain === true; }

  // Main script and chat panels in one page: the panels' documents one after
  // another, the main script first.
  function onePage(plugin) {
    return plugin.onePage === true &&
      (plugin.panels || []).some(function (p) { return p.placement === 'chat'; });
  }

  function onePageHtml(plugin) {
    var html = typeof plugin.main === 'string' && plugin.main
      ? scriptTag(plugin.main + '\n//# sourceURL=plugin://' + plugin.pluginId + '/' + (plugin.mainPath || 'main.js'))
      : '';
    (plugin.panels || []).forEach(function (panel) {
      if (panel.placement === 'chat') html += String(panel.html || '');
    });
    return html;
  }

  /* ---------- Hit regions (chat panels) ---------- */
  function applyHitRects(state, rects) {
    if (!Array.isArray(rects) || !rects.length) {
      state.holes = null;
    } else {
      // A few px of slack keeps soft shadows and glows from being cut square.
      var pad = HIT_SLACK_PX;
      state.holes = rects.map(function (r) {
        var x = Math.max(0, (+r[0] || 0) - pad), y = Math.max(0, (+r[1] || 0) - pad);
        return [x, y, Math.max(0, +r[2] || 0) + 2 * pad, Math.max(0, +r[3] || 0) + 2 * pad];
      });
    }
    refreshClips();
    scheduleHoles();
  }

  // A panel frame covers the whole page, so only its hit boxes may take
  // touches: the frame is clipped to them, which cuts what it draws there
  // too. In the plugin layer nothing of the page is under the frames, so a
  // frame is only clipped where another one takes touches as well; the app
  // itself lets touches into the layer only inside the boxes.
  function clipTo(style, boxes) {
    style.clipPath = 'path(\'' + boxes.map(function (b) {
      return 'M' + b[0] + ' ' + b[1] + 'h' + b[2] + 'v' + b[3] + 'h' + (-b[2]) + 'Z';
    }).join(' ') + '\')';
  }

  function refreshClips() {
    var touched = 0;
    wrappers.forEach(function (f) { if (f.kind === 'panel' && f.holes) touched++; });
    wrappers.forEach(function (f) {
      if (f.kind !== 'panel') return;
      var style = f.iframe.style;
      style.pointerEvents = f.holes ? 'auto' : 'none';
      if (layer === 'panels' && touched < 2) style.clipPath = 'none';
      else if (f.holes) clipTo(style, f.holes);
      else style.clipPath = layer === 'panels' ? 'none' : 'polygon(0 0, 0 0, 0 0)';
    });
  }

  // What chat panels draw goes over the app's own controls (header, message
  // box): the plugin layer takes touches only in these areas, or else the
  // app cuts its controls out there.
  var holesKey = '[]';
  var holesTimer = 0;
  function reportHoles() {
    holesTimer = 0;
    var all = [];
    wrappers.forEach(function (f) { if (f.kind === 'panel' && f.holes) all = all.concat(f.holes); });
    var key = JSON.stringify(all);
    if (key === holesKey) return;
    holesKey = key;
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('pluginHoles', all);
    }
  }

  function scheduleHoles() {
    if (!holesTimer) holesTimer = setTimeout(reportHoles, 0);
  }

  /* ---------- Dart transport ---------- */
  function reportNetwork(pluginId, host, blocked) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
    window.flutter_inappwebview.callHandler('pluginNetwork', {
      pluginId: pluginId, host: String(host).slice(0, 253), blocked: !!blocked,
    });
  }

  // A request a plugin frame made, for the app's request log. The frame
  // says what it sent; the plugin it belongs to is the host's to say.
  function reportRequest(pluginId, d) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
    var str = function (v, max) { return typeof v === 'string' ? v.slice(0, max) : null; };
    var headers = Array.isArray(d.headers) ? d.headers.slice(0, 64).filter(function (h) {
      return Array.isArray(h) && h.length === 2 && typeof h[0] === 'string' && typeof h[1] === 'string';
    }).map(function (h) { return [h[0].slice(0, 256), h[1].slice(0, 8192)]; }) : [];
    window.flutter_inappwebview.callHandler('pluginHttp', {
      pluginId: pluginId,
      phase: d.phase === 'start' ? 'start' : 'end',
      id: str(d.id, 64),
      via: str(d.via, 32),
      method: str(d.method, 16),
      url: str(d.url, 8192),
      headers: headers,
      body: str(d.body, 200000),
      status: typeof d.status === 'number' ? d.status : null,
      error: str(d.error, 2000),
    });
  }

  function callDart(state, method, params) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      return Promise.resolve({ ok: false, error: { code: 'unavailable', message: 'The app is not available' } });
    }
    return window.flutter_inappwebview.callHandler('pluginBridge', {
      pluginId: state.plugin.pluginId,
      messageId: state.messageId,
      method: String(method || ''),
      params: params === undefined ? null : params,
    });
  }

  // Whether [win] is a plugin frame or nested anywhere inside one.
  function insidePluginFrame(win) {
    for (var w = win, depth = 0; w && depth < 32; depth++) {
      if (frames.has(w) || wrappers.has(w)) return true;
      var up;
      try { up = w.parent; } catch (e) { return false; }
      if (!up || up === w || up === window) return false;
      w = up;
    }
    return false;
  }

  // Registered before the page's own listeners and in the capture phase:
  // what plugin frames (and frames they nest) post stops here, so they can
  // only speak the plugin protocol and never reach the page's other relays,
  // such as the one serving message HTML.
  window.addEventListener('message', function (e) {
    if (!e.source || !insidePluginFrame(e.source)) return;
    e.stopImmediatePropagation();
    var state = frameOf(e.source);
    var d = e.data;
    if (!state) {
      var wrapped = wrappers.get(e.source);
      if (wrapped && d && d.type === P + 'gone') {
        if (wrapped.plugin.network !== true) reportNetwork(wrapped.plugin.pluginId, 'navigation', true);
        removeFrame(wrapped);
      }
      return;
    }
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
        // Only the frame that was asked may answer.
        var pending = pendingReplies.get(d.id);
        if (pending && pending.state === state) {
          pendingReplies.delete(d.id);
          pending.resolve(d.result);
        }
        return;
      }
      case 'subscribe': {
        var ev = String(d.event);
        var kind = ev.split(':')[0];
        if (kind !== 'action' && !state.plugin.events.has(kind)) {
          // Not allowed: the app notes the attempt once per kind.
          if (EVENT_KINDS.indexOf(kind) >= 0 && !state.plugin.refused.has(kind)) {
            state.plugin.refused.add(kind);
            callDart(state, 'events.subscribe', [kind]);
          }
          return;
        }
        if (isMain(state)) state.plugin.subscriptions.add(ev);
        return;
      }
      case 'emit':
        framesOf(state.plugin.pluginId).forEach(function (f) {
          if (f !== state) send(f, { type: P + 'emit', event: d.event, detail: d.detail });
        });
        // The plugin's frames in the other page.
        if (layer !== 'all') {
          callHandler('pluginEmit', { pluginId: state.plugin.pluginId, event: d.event, detail: d.detail });
        }
        return;
      case 'net':
        if (typeof d.host === 'string' && d.host) reportNetwork(state.plugin.pluginId, d.host, d.blocked);
        return;
      case 'req':
        if (typeof d.id === 'string' && d.id) reportRequest(state.plugin.pluginId, d);
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
  }, true);

  function randomId() {
    var bytes = new Uint8Array(12);
    crypto.getRandomValues(bytes);
    return Array.prototype.map.call(bytes, function (b) { return (b + 256).toString(16).slice(1); }).join('');
  }

  function ask(state, msg, capMs) {
    return new Promise(function (resolve) {
      var id = 'r' + (++replySeq) + '-' + randomId();
      var timer = capMs ? setTimeout(function () {
        pendingReplies.delete(id);
        resolve(null);
      }, capMs) : null;
      pendingReplies.set(id, {
        state: state,
        resolve: function (result) {
          if (timer) clearTimeout(timer);
          resolve(result);
        },
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
    // Nothing of the app's top bar is to be avoided: what panels draw goes
    // over it, so the top bar inset is the status bar alone.
    var next = {
      topSafe: round(safe.top),
      topBar: round(safe.top),
      bottomInput: round(Math.max(safe.bottom, parseFloat(container.style.paddingBottom) || 0)),
      bottomSafe: round(safe.bottom),
      keyboard: 0,
    };
    if (next.topSafe === insets.topSafe && next.topBar === insets.topBar &&
        next.bottomInput === insets.bottomInput && next.bottomSafe === insets.bottomSafe) return;
    applyInsets(next);
  }

  function applyInsets(next) {
    insets = next;
    wrappers.forEach(function (f) { if (f.kind === 'panel') sendInsets(f); });
    // The plugin layer has no message box to measure: it gets the chat's.
    if (layer === 'chat') callHandler('pluginInsets', insets);
  }

  // The plugin layer's insets, as the chat page measured them.
  function setInsets(next) {
    if (layer !== 'panels' || !next) return;
    var num = function (v) { return Math.max(0, +v || 0); };
    applyInsets({
      topSafe: num(next.topSafe),
      topBar: num(next.topBar),
      bottomInput: num(next.bottomInput),
      bottomSafe: num(next.bottomSafe),
      keyboard: 0,
    });
  }

  var insetRaf = 0;
  function scheduleInsets() {
    if (insetRaf) return;
    insetRaf = requestAnimationFrame(function () { insetRaf = 0; refreshInsets(); });
  }

  // A frame fitted above the keyboard measures its insets from the
  // keyboard's top edge, which already covers the gesture strip.
  function insetsFor(f) {
    var kb = f.keyboard || 0;
    if (!kb) return insets;
    return Object.assign({}, insets, {
      bottomInput: Math.max(0, insets.bottomInput - kb),
      bottomSafe: Math.max(0, insets.bottomSafe - kb),
      keyboard: kb,
    });
  }

  function sendInsets(f) {
    send(f, { type: P + 'insets', insets: insetsFor(f) });
  }

  /* ---------- Keyboard ---------- */
  // The soft keyboard lays over the WebView instead of resizing it, and only
  // this page's visual viewport shrinks for it: a frame's own viewport never
  // does. A panel laid out on 100vh, innerHeight or its visualViewport would
  // keep its fields under the keyboard, so the panel frame that has the focus
  // is fitted to the visual viewport while the keyboard is up, the way a
  // browser resizes a page for its own keyboard. Other panels keep the whole
  // page: the keyboard of the message box or of a message edit is not
  // theirs, and resizing them would move their buttons.
  var KEYBOARD_MIN_PX = 8;
  var fitted = null;

  function fit(f, view) {
    var style = f.iframe.style;
    if (view) {
      style.top = view.top + 'px';
      style.height = view.height + 'px';
    } else {
      style.top = '0';
      style.height = '100%';
    }
    var kb = view ? view.keyboard : 0;
    if (kb === (f.keyboard || 0)) return;
    f.keyboard = kb;
    sendInsets(f);
  }

  function refreshKeyboard() {
    var vv = window.visualViewport;
    var kb = vv ? Math.round(window.innerHeight - vv.height) : 0;
    var target = null;
    if (kb >= KEYBOARD_MIN_PX) {
      var active = document.activeElement;
      wrappers.forEach(function (f) { if (f.kind === 'panel' && f.iframe === active) target = f; });
    }
    if (fitted && fitted !== target) fit(fitted, null);
    fitted = target;
    // Top as well as height: a browser that panned the page to reveal the
    // caret moved the visible area down by offsetTop.
    if (target) fit(target, { top: Math.max(0, Math.round(vv.offsetTop)), height: Math.round(vv.height), keyboard: kb });
  }

  var keyboardRaf = 0;
  function scheduleKeyboard() {
    if (keyboardRaf) return;
    keyboardRaf = requestAnimationFrame(function () { keyboardRaf = 0; refreshKeyboard(); });
  }

  /* ---------- Message panels and message actions ---------- */
  var messageFrames = new Map(); // key -> frame state
  var reconcileScheduled = false;

  function scheduleReconcile() {
    if (reconcileScheduled || layer === 'panels') return;
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
          messageFrames.set(key, mountFrame(plugin, 'message', panelDoc(plugin, boot, panel.html), panel.src, {
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
    window.addEventListener('resize', scheduleKeyboard);
    // Focus going into a frame blurs this window; coming back focuses it.
    window.addEventListener('blur', scheduleKeyboard);
    window.addEventListener('focus', scheduleKeyboard);
    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', scheduleKeyboard);
      window.visualViewport.addEventListener('scroll', scheduleKeyboard);
    }
    refreshInsets();
  }

  /* ---------- Public API (called from Dart) ---------- */
  function teardown() {
    wrappers.forEach(removeFrame);
    frames.clear();
    wrappers.clear();
    messageFrames.clear();
    plugins.clear();
    pendingReplies.forEach(function (pending) { pending.resolve(null); });
    pendingReplies.clear();
    document.querySelectorAll('.glaze-plugin-slot,.glaze-plugin-msg-actions').forEach(function (el) { el.remove(); });
  }

  function setup(payload) {
    payload = payload || {};
    teardown();
    P = 'p' + randomId() + ':';
    layer = payload.layer === 'chat' || payload.layer === 'panels' ? payload.layer : 'all';
    if (typeof payload.sdk === 'string') sdkSource = payload.sdk;
    rtcToken = typeof payload.rtcToken === 'string' ? payload.rtcToken : null;
    compatSources = payload.compat || {};
    refreshInsets();
    // The plugin layer is set up first and waits for these.
    if (layer === 'chat') callHandler('pluginInsets', insets);
    var mainHere = layer !== 'panels';
    var panelsHere = layer !== 'chat';
    (payload.plugins || []).forEach(function (p) {
      var plugin = Object.assign({}, p, {
        subscriptions: new Set(),
        // Kinds of hooks and notifications its permissions cover.
        events: new Set(Array.isArray(p.events) ? p.events : []),
        refused: new Set(),
      });
      plugins.set(plugin.pluginId, plugin);
      if (onePage(plugin)) {
        // Where the chat panels are.
        if (!panelsHere) return;
        var chat = plugin.panels.filter(function (p) { return p.placement === 'chat'; });
        var shared = mountFrame(plugin, 'panel',
          panelDoc(plugin, bootFor(plugin, 'panel', { panelId: chat[0].id, main: true }), onePageHtml(plugin)),
          chat[0].src, { panelId: chat[0].id, order: chat[0].order });
        shared.hostsMain = true;
        return;
      }
      if (mainHere && typeof plugin.main === 'string' && plugin.main) {
        mountFrame(plugin, 'main', runScriptsDoc(plugin, bootFor(plugin, 'main'), [{ name: 'main.js', source: plugin.main }]),
          plugin.mainPath);
      }
      (plugin.panels || []).forEach(function (panel) {
        if (!panelsHere || panel.placement !== 'chat') return;
        mountFrame(plugin, 'panel', panelDoc(plugin, bootFor(plugin, 'panel', { panelId: panel.id }), panel.html), panel.src, {
          panelId: panel.id, order: panel.order,
        });
      });
    });
    raisePanels();
    scheduleReconcile();
    return plugins.size;
  }

  function dispatchEvent(type, payload, onlyPluginId) {
    var msg = { type: P + 'event', event: String(type), payload: payload || {} };
    var kind = String(type).split(':')[0];
    wrappers.forEach(function (f) {
      if (f.kind === 'file' || !f.plugin.events.has(kind)) return;
      if (!onlyPluginId || f.plugin.pluginId === onlyPluginId) send(f, msg);
    });
  }

  function pushVars(pluginId, scope, value) {
    framesOf(pluginId).forEach(function (f) { send(f, { type: P + 'vars', scope: scope, value: value || {} }); });
  }

  // An emit of one of the plugin's frames in the other page.
  function relayEmit(pluginId, event, detail) {
    framesOf(String(pluginId)).forEach(function (f) {
      send(f, { type: P + 'emit', event: event, detail: detail });
    });
  }

  function setMessages(list, isBusy, chatId) {
    messageList = Array.isArray(list) ? list : [];
    busy = !!isBusy;
    currentChatId = chatId || null;
    scheduleReconcile();
  }

  // Runs a blocking hook through every subscribed plugin in setup order, or
  // through those of [only] (plugin ids) when given: the app runs a hook
  // through both pages when main scripts are in each.
  // Resolves `{ text, cancelled, cancelledBy?, message? }`.
  async function intercept(type, payload, only) {
    payload = Object.assign({}, payload || {});
    var text = typeof payload.text === 'string' ? payload.text : '';
    var order = Array.from(plugins.values());
    for (var i = 0; i < order.length; i++) {
      var plugin = order[i];
      if (!plugin.subscriptions.has(type)) continue;
      if (Array.isArray(only) && only.indexOf(plugin.pluginId) < 0) continue;
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
      frame = mountFrame(plugin, 'file', runScriptsDoc(plugin, bootFor(plugin, 'file'), scripts), scripts[0].name);
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
    relayEmit: relayEmit,
    setInsets: setInsets,
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
