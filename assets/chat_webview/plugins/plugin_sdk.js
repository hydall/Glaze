// Glaze plugin SDK. Runs inside a plugin iframe (sandbox="allow-scripts",
// null origin) — never in the chat page itself — and defines `glaze`.
//
// The host (plugin_host.js) writes `window.__pluginBoot` first:
//   { pluginId, kind: 'main'|'panel'|'message'|'file', panelId?, messageId?,
//     channel, config, i18n, vars: { chat, global }, storage, methods: [...],
//     insets, compat, network, rtcToken, package, main? }
// Every call goes to the parent as a `<channel>call` postMessage; the parent
// attributes it to this frame's plugin and forwards it to Dart.
//
// What the plugin can see of this file is only the API: the boot data and
// the script tags go once read, and the functions wrapped to watch the
// network read as the browser's own.
(function () {
  'use strict';
  var boot = window.__pluginBoot || {};
  try { delete window.__pluginBoot; } catch (e) { window.__pluginBoot = undefined; }
  var P = typeof boot.channel === 'string' ? boot.channel : 'p0:';
  (function dropScripts() {
    var own = document.currentScript;
    var bootScript = own && own.previousElementSibling;
    if (bootScript && bootScript.tagName === 'SCRIPT' && /__pluginBoot/.test(bootScript.textContent)) bootScript.remove();
    if (own) own.remove();
  })();
  // The host is the chat page, past the wrapper frame this one sits in.
  var parentWin = window.parent.parent;
  var kind = boot.kind || 'main';
  // A chat panel may share its page with the main script (`main`).
  var isMain = kind === 'main' || boot.main === true;
  var seq = 0;
  var pending = new Map();

  function post(msg) {
    try { parentWin.postMessage(msg, '*'); } catch (e) { /* host gone */ }
  }

  function call(method, args) {
    return new Promise(function (resolve, reject) {
      var id = 'c' + (++seq);
      pending.set(id, { resolve: resolve, reject: reject });
      post({ type: P + 'call', id: id, method: method, params: args || [] });
    });
  }

  function fire(method, args) {
    call(method, args).catch(function (e) { console.warn('[plugin]', method, e && e.message); });
  }

  // Wrapped browser functions print as the originals.
  var nativeToString = Function.prototype.toString;
  var disguised = new WeakMap();
  function disguise(fn, as) { disguised.set(fn, as); return fn; }
  var toString = function toString() { return nativeToString.call(disguised.get(this) || this); };
  disguised.set(toString, nativeToString);
  try {
    Object.defineProperty(Function.prototype, 'toString', { value: toString, writable: true, configurable: true });
  } catch (e) { /* left as is */ }

  function clone(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); }
  function isPlain(v) { return v != null && typeof v === 'object' && !Array.isArray(v); }

  /* ---------- Network log ---------- */
  // Reports each host this frame loads from (or is stopped from loading
  // from) so the plugin's page can list them. Installed before any plugin
  // code runs; it sees fetch/XHR/WebSocket/EventSource calls, every resource
  // the page loads and every request the frame's policy blocks.
  // The calls themselves (what was sent and what came back) also go to the
  // app's request log, which the Prompt Inspector shows.
  (function watchNetwork() {
    var seen = new Set();
    var network = boot.network;
    var local = boot.localNetwork === true;
    // The plugin's own package, served on the loopback ('…/plugins/<id>/'):
    // its own files, not the network.
    var pkg = typeof boot.package === 'string' ? boot.package : null;
    function own(url) {
      if (!pkg) return false;
      try { return new URL(String(url), location.href).href.indexOf(pkg) === 0; } catch (e) { return false; }
    }
    // Same rule as the host's frame policy, which is what actually blocks.
    // Loopback is this device, not the local network: the switch for that does
    // not gate it.
    function isLoopbackHost(host) {
      host = String(host).toLowerCase().replace(/^\[|\]$/g, '');
      if (host === 'localhost' || /\.localhost$/.test(host)) return true;
      var v4 = /^127\.(\d+)\.(\d+)\.(\d+)$/.exec(host);
      if (v4) return +v4[1] <= 255 && +v4[2] <= 255 && +v4[3] <= 255;
      return host === '::1' || host === '0:0:0:0:0:0:0:1';
    }
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
    function allowed(host) {
      if (!local && !isLoopbackHost(host) && isLocalHost(host)) return false;
      if (network === true) return true;
      if (!Array.isArray(network)) return false;
      return network.some(function (rule) {
        return rule.indexOf('*.') === 0 ? host.slice(-(rule.length - 1)) === rule.slice(1) : host === rule;
      });
    }
    function report(url, blocked) {
      var host;
      try { host = new URL(String(url), location.href).hostname; } catch (e) { return; }
      if (!host) return;
      host = host.toLowerCase();
      if (blocked === undefined) blocked = !allowed(host);
      var key = (blocked ? '!' : '') + host;
      if (seen.has(key)) return;
      seen.add(key);
      post({ type: P + 'net', host: host, blocked: !!blocked });
    }
    function remote(url) { return /^(https?|wss?):/i.test(String(url)) && !own(url); }
    function hostOf(url) {
      try { return new URL(String(url), location.href).hostname.toLowerCase(); } catch (e) { return ''; }
    }
    // A call to the local network without access to it fails like a
    // network error, before anything is sent.
    function refused(url) {
      var host = hostOf(url);
      return !local && network !== false && remote(url) &&
        !isLoopbackHost(host) && isLocalHost(host);
    }

    /* Request log: a 'req' message when a call goes out, one when it ends. */
    var CAP = 200000;
    var reqPrefix = Math.random().toString(36).slice(2, 10);
    var reqSeq = 0;
    function capText(t) { t = String(t); return t.length > CAP ? t.slice(0, CAP) : t; }
    function decode(bytes) {
      if (bytes.byteLength > CAP * 4) return '[binary, ' + bytes.byteLength + ' bytes]';
      try { return capText(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
      catch (e) { return '[binary, ' + bytes.byteLength + ' bytes]'; }
    }
    function bodyText(b) {
      try {
        if (b == null) return Promise.resolve(null);
        if (typeof b === 'string') return Promise.resolve(capText(b));
        if (typeof URLSearchParams !== 'undefined' && b instanceof URLSearchParams) return Promise.resolve(capText(b));
        if (typeof FormData !== 'undefined' && b instanceof FormData) {
          var parts = [];
          b.forEach(function (v, k) {
            parts.push(k + '=' + (typeof v === 'string' ? v : '[file ' + (v.name || '') + ', ' + v.size + ' bytes]'));
          });
          return Promise.resolve(capText(parts.join('\n')));
        }
        if (typeof Blob !== 'undefined' && b instanceof Blob) {
          if (b.size > CAP * 4 || /^(image|audio|video|font)\//.test(b.type)) {
            return Promise.resolve('[' + (b.type || 'binary') + ', ' + b.size + ' bytes]');
          }
          return b.arrayBuffer().then(function (buf) { return decode(new Uint8Array(buf)); });
        }
        if (b instanceof ArrayBuffer) return Promise.resolve(decode(new Uint8Array(b)));
        if (ArrayBuffer.isView(b)) return Promise.resolve(decode(new Uint8Array(b.buffer, b.byteOffset, b.byteLength)));
        if (typeof ReadableStream !== 'undefined' && b instanceof ReadableStream) return Promise.resolve('[stream]');
        if (b && typeof b.then === 'function') return b.then(bodyText, function () { return null; });
        return Promise.resolve(capText(b));
      } catch (e) { return Promise.resolve(null); }
    }
    // Returns the function that reports the end; it waits for the start.
    function logRequest(via, method, url, headers, body) {
      var id = reqPrefix + '-' + (++reqSeq);
      var abs;
      try { abs = new URL(String(url), location.href).href; } catch (e) { abs = String(url); }
      var started = bodyText(body).then(function (text) {
        post({ type: P + 'req', phase: 'start', id: id, via: via, method: String(method || 'GET').toUpperCase(),
          url: abs, headers: headers || [], body: text });
      });
      return function (status, text, error) {
        started.then(function () {
          post({ type: P + 'req', phase: 'end', id: id, status: status == null ? null : status,
            body: text == null ? null : capText(text), error: error ? String(error) : null });
        });
      };
    }
    function pairs(h) {
      var out = [];
      try { new Headers(h || undefined).forEach(function (v, n) { out.push([n, v]); }); } catch (e) { /* none */ }
      return out;
    }
    function binaryType(type) { return /^(image|audio|video|font)\/|octet-stream|pdf|zip|protobuf/i.test(type || ''); }
    // Reads a copy of the response, so the plugin's own read is untouched.
    function readResponse(res, end) {
      var type = res.headers.get('content-type') || '';
      if (binaryType(type)) {
        var len = res.headers.get('content-length');
        end(res.status, '[' + type.split(';')[0] + (len ? ', ' + len + ' bytes' : '') + ']');
        return;
      }
      var copy;
      try { copy = res.clone(); } catch (e) { end(res.status, null); return; }
      if (!copy.body || !copy.body.getReader) {
        copy.text().then(function (t) { end(res.status, t); }, function (e) { end(res.status, null, e && e.message); });
        return;
      }
      var reader = copy.body.getReader(), dec = new TextDecoder(), text = '';
      (function pump() {
        reader.read().then(function (r) {
          if (!r.done) text += dec.decode(r.value, { stream: true });
          if (r.done || text.length >= CAP) {
            if (!r.done) reader.cancel().catch(function () {});
            end(res.status, text);
            return;
          }
          pump();
        }, function (e) { end(res.status, text || null, e && e.message || 'The response failed'); });
      })();
    }

    try {
      new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (e) { if (remote(e.name)) report(e.name); });
      }).observe({ type: 'resource', buffered: true });
    } catch (e) { /* no resource timing */ }
    document.addEventListener('securitypolicyviolation', function (e) {
      if (remote(e.blockedURI)) report(e.blockedURI, true);
    });
    var nativeFetch = window.fetch;
    if (nativeFetch) {
      window.fetch = function (input, init) {
        var url = input && typeof input === 'object' && 'url' in input ? input.url : input;
        var end = null;
        if (remote(url)) {
          report(url);
          try {
            var isRequest = typeof Request !== 'undefined' && input instanceof Request;
            var method = (init && init.method) || (isRequest ? input.method : 'GET');
            var body = init && init.body != null ? init.body : null;
            if (body == null && isRequest && !/^(GET|HEAD)$/i.test(method) && !input.bodyUsed) {
              body = input.clone().arrayBuffer();
            }
            end = logRequest('fetch', method, url, pairs((init && init.headers) || (isRequest ? input.headers : null)), body);
          } catch (e) { /* not logged */ }
        }
        if (refused(url)) {
          if (end) end(null, null, 'Local network access is not allowed');
          return Promise.reject(new TypeError('Failed to fetch'));
        }
        var result = nativeFetch.apply(this, arguments);
        if (end) {
          result.then(function (res) { readResponse(res, end); },
            function (e) { end(null, null, (e && e.name === 'AbortError') ? 'aborted' : (e && e.message) || 'Failed to fetch'); });
        }
        return result;
      };
      disguise(window.fetch, nativeFetch);
    }
    var open = XMLHttpRequest.prototype.open;
    var xhrs = new WeakMap();
    XMLHttpRequest.prototype.open = function (method, url) {
      if (remote(url)) report(url);
      if (refused(url)) throw new DOMException('Local network access is not allowed for this plugin', 'SecurityError');
      xhrs.set(this, remote(url) ? { method: method, url: url, headers: [] } : null);
      return open.apply(this, arguments);
    };
    disguise(XMLHttpRequest.prototype.open, open);
    var setHeader = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
      var info = xhrs.get(this);
      if (info) info.headers.push([String(name).toLowerCase(), String(value)]);
      return setHeader.apply(this, arguments);
    };
    disguise(XMLHttpRequest.prototype.setRequestHeader, setHeader);
    var send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (body) {
      var info = xhrs.get(this);
      if (info) {
        xhrs.set(this, null);
        var xhr = this;
        var end = logRequest('xhr', info.method, info.url, info.headers, body);
        var done = function (error) {
          var text = null;
          try {
            if (xhr.responseType === '' || xhr.responseType === 'text') text = xhr.responseText;
            else if (xhr.responseType === 'json') text = JSON.stringify(xhr.response);
            else if (xhr.response && xhr.response.byteLength != null) text = '[binary, ' + xhr.response.byteLength + ' bytes]';
            else if (xhr.response && xhr.response.size != null) text = '[' + (xhr.response.type || 'binary') + ', ' + xhr.response.size + ' bytes]';
          } catch (e) { /* unreadable */ }
          end(xhr.status || null, text, error);
        };
        xhr.addEventListener('load', function () { done(null); });
        xhr.addEventListener('error', function () { done('The request failed'); });
        xhr.addEventListener('abort', function () { done('aborted'); });
        xhr.addEventListener('timeout', function () { done('timeout'); });
      }
      return send.apply(this, arguments);
    };
    disguise(XMLHttpRequest.prototype.send, send);
    if (navigator.sendBeacon) {
      var beacon = navigator.sendBeacon;
      navigator.sendBeacon = function (url, data) {
        var sent = beacon.apply(navigator, arguments);
        if (remote(url)) {
          report(url);
          logRequest('beacon', 'POST', url, [], data)(null, null, sent ? null : 'Not queued');
        }
        return sent;
      };
      disguise(navigator.sendBeacon, beacon);
    }
    ['WebSocket', 'EventSource'].forEach(function (name) {
      var Native = window[name];
      if (!Native) return;
      var Wrapped = function (url) {
        if (remote(url)) report(url);
        if (refused(url)) throw new DOMException('Local network access is not allowed for this plugin', 'SecurityError');
        var made = new (Function.prototype.bind.apply(Native, [null].concat(Array.prototype.slice.call(arguments))))();
        if (remote(url)) {
          // A connection, not one call: logged when it opens or fails.
          var end = logRequest(name === 'WebSocket' ? 'websocket' : 'eventsource', 'GET', made.url || url, [], null);
          var once = function (status, text, error) { if (end) { end(status, text, error); end = null; } };
          made.addEventListener('open', function () {
            once(name === 'WebSocket' ? 101 : 200, '[' + name + ' open]');
          });
          made.addEventListener('error', function () { once(null, null, name + ' failed'); });
        }
        return made;
      };
      Wrapped.prototype = Native.prototype;
      Object.keys(Native).forEach(function (k) { Wrapped[k] = Native[k]; });
      ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { if (k in Native) Wrapped[k] = Native[k]; });
      window[name] = disguise(Wrapped, Native);
    });
  })();

  /* ---------- WebRTC ---------- */
  // The WebView strips WebRTC from plugin frames (it reaches the network
  // past every policy). A plugin that may reach any host gets it back; any
  // other gets stubs that refuse and log the attempt.
  (function webrtc() {
    var take = window.__rtcGate;
    try { delete window.__rtcGate; } catch (e) { /* not ours to remove */ }
    var key = boot.rtcToken;
    delete boot.rtcToken;
    var kept = boot.network === true && typeof take === 'function' && key ? take(key) : null;
    var logged = false;
    function log(blocked) {
      if (logged) return;
      logged = true;
      post({ type: P + 'net', host: 'webrtc', blocked: blocked });
    }
    if (kept) {
      Object.keys(kept).forEach(function (name) { window[name] = kept[name]; });
    } else if (boot.network === true) {
      // No WebView guard on this platform: WebRTC was never taken away.
    } else {
      Object.getOwnPropertyNames(window).forEach(function (name) {
        if (/^(webkit)?RTC/.test(name)) { try { delete window[name]; } catch (e) { /* kept */ } }
      });
      ['RTCPeerConnection', 'webkitRTCPeerConnection'].forEach(function (name) {
        window[name] = disguise(function () {
          log(true);
          throw new DOMException('WebRTC is not allowed for this plugin', 'NotAllowedError');
        }, { toString: function () { return 'function ' + name + '() { [native code] }'; } });
      });
      return;
    }
    ['RTCPeerConnection', 'webkitRTCPeerConnection'].forEach(function (name) {
      var Native = window[name];
      if (typeof Native !== 'function') return;
      var Wrapped = function () {
        log(false);
        return new (Function.prototype.bind.apply(Native, [null].concat(Array.prototype.slice.call(arguments))))();
      };
      Wrapped.prototype = Native.prototype;
      Object.setPrototypeOf(Wrapped, Native);
      window[name] = disguise(Wrapped, Native);
    });
  })();

  /* ---------- Bridged namespaces, built from the granted method list ---------- */
  var glaze = {};
  var available = new Set(boot.methods || []);
  available.forEach(function (method) {
    var parts = method.split('.');
    var node = glaze;
    for (var i = 0; i < parts.length - 1; i++) {
      if (typeof node[parts[i]] !== 'object' || node[parts[i]] === null) {
        node[parts[i]] = typeof node[parts[i]] === 'function' ? node[parts[i]] : {};
      }
      node = node[parts[i]];
    }
    node[parts[parts.length - 1]] = function () {
      return call(method, Array.prototype.slice.call(arguments));
    };
  });

  /* ---------- Variables (async, plus a synchronous cache) ---------- */
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
  function cacheScope(scope) {
    if (scope && typeof scope === 'object') scope = scope.scope;
    // `message` and `shared` are not cached.
    return scope === 'global' ? 'global' : scope === 'message' || scope === 'shared' ? null : 'chat';
  }
  if (glaze.variables) {
    var v = glaze.variables;
    var set = v.set, update = v.update, del = v['delete'];
    v.set = function (name, value, scope) {
      var s = cacheScope(scope);
      if (s) setAt(varCache[s], name, clone(value));
      return set(name, value, scope);
    };
    v.update = function (name, value, scope) {
      var s = cacheScope(scope);
      if (s) {
        var prev = getAt(varCache[s], name);
        setAt(varCache[s], name, isPlain(prev) && isPlain(value) ? Object.assign({}, prev, clone(value)) : clone(value));
      }
      return update(name, value, scope);
    };
    v['delete'] = function (name, scope) {
      var s = cacheScope(scope);
      if (s) {
        var parts = splitPath(name);
        var parent = parts.length > 1 ? getAt(varCache[s], parts.slice(0, -1).join('.')) : varCache[s];
        if (parent && typeof parent === 'object') delete parent[parts[parts.length - 1]];
      }
      return del(name, scope);
    };
    /** Synchronous read of the last known chat/global values. */
    v.peek = function (name, scope) {
      var s = cacheScope(scope) || 'chat';
      return clone(name == null ? varCache[s] : getAt(varCache[s], name));
    };
  }

  /* ---------- Files ---------- */
  var FILE_PATH = /^files\/(chat|global|tmp)\/[^/]+$/;
  if (glaze.files) {
    /** Virtual path of a plugin file (no existence check). */
    glaze.files.url = function (name, scope) {
      name = String(name);
      return FILE_PATH.test(name) ? name : 'files/' + (scope || 'chat') + '/' + name;
    };
    // Images, audio and links in plugin HTML may point at plugin files; a
    // null-origin frame cannot load those, so swap in data URLs.
    var resolved = new Map();
    var resolveElement = function (el) {
      ['src', 'href', 'poster'].forEach(function (attr) {
        var value = el.getAttribute && el.getAttribute(attr);
        if (!value || !FILE_PATH.test(value)) return;
        var job = resolved.get(value);
        if (!job) {
          job = glaze.files.dataUrl(value).catch(function () { return null; });
          resolved.set(value, job);
        }
        job.then(function (url) { if (url && el.getAttribute(attr) === value) el.setAttribute(attr, url); });
      });
    };
    var scan = function (root) {
      if (root.nodeType !== 1) return;
      resolveElement(root);
      root.querySelectorAll('[src],[href],[poster]').forEach(resolveElement);
    };
    var watchFiles = function () {
      scan(document.documentElement);
      new MutationObserver(function (records) {
        records.forEach(function (r) {
          if (r.type === 'attributes') resolveElement(r.target);
          r.addedNodes && r.addedNodes.forEach(scan);
        });
      }).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['src', 'href', 'poster'] });
    };
    if (document.documentElement) watchFiles();
    else document.addEventListener('DOMContentLoaded', watchFiles);
  }

  /* ---------- Requests through the app ---------- */
  // glaze.net.fetch takes what fetch() takes and resolves to a Response. The
  // app makes the request, so the page's cross-origin rules do not apply;
  // the plugin's internet rules do.
  if (glaze.net && glaze.net.fetch) {
    var appFetch = glaze.net.fetch, appAbort = glaze.net.abort;
    delete glaze.net.abort;
    var NULL_BODY = { 204: 1, 205: 1, 304: 1 };
    var toBase64 = function (bytes) {
      var bin = '';
      for (var i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      }
      return btoa(bin);
    };
    var fromBase64 = function (s) {
      var bin = atob(s), out = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    };
    var aborted = function (signal) {
      return signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
    };
    glaze.net.fetch = function (input, init) {
      var request;
      try { request = new Request(input, init); } catch (e) { return Promise.reject(e); }
      var signal = request.signal;
      if (signal.aborted) return Promise.reject(aborted(signal));
      var id = 'n' + (++seq);
      var timeout = init && typeof init.timeout === 'number' ? init.timeout : undefined;
      var body = request.method === 'GET' || request.method === 'HEAD' ? Promise.resolve(null) : request.arrayBuffer();
      return new Promise(function (resolve, reject) {
        var onAbort = function () {
          if (appAbort) appAbort(id).catch(function () {});
          reject(aborted(signal));
        };
        signal.addEventListener('abort', onAbort);
        var done = function () { signal.removeEventListener('abort', onAbort); };
        body.then(function (buf) {
          if (signal.aborted) return;
          var headers = [];
          request.headers.forEach(function (value, name) { headers.push([name, value]); });
          return appFetch(request.url, {
            id: id, method: request.method, headers: headers, timeout: timeout,
            body: buf && buf.byteLength ? toBase64(new Uint8Array(buf)) : null,
          }).then(function (r) {
            done();
            var res = new Response(r.body == null || NULL_BODY[r.status] ? null : fromBase64(r.body), {
              status: r.status, statusText: r.statusText || '', headers: r.headers || [],
            });
            Object.defineProperty(res, 'url', { value: r.url });
            Object.defineProperty(res, 'redirected', { value: !!r.redirected });
            resolve(res);
          });
        }).catch(function (e) {
          done();
          reject(e && e.code === 'aborted' && signal.aborted ? aborted(signal) : e);
        });
      });
    };
  }

  /* ---------- Events, hooks and actions ---------- */
  var handlers = new Map();
  var emitHandlers = new Map();
  var fileHandlers = new Map();
  var HOOKS = ['send:before', 'send:after', 'generation:prepare', 'generation:success',
    'generation:error', 'generation:cancelled'];
  var BLOCKING = ['send:before', 'generation:prepare', 'generation:success'];
  var NOTIFY = /^(chat|message):/;

  function remove(map, key, fn) {
    var list = map.get(key);
    if (!list) return;
    var i = list.indexOf(fn);
    if (i >= 0) list.splice(i, 1);
  }

  function canonical(type) { return type === 'chat:changed' ? 'chat:updated' : type; }

  function on(type, handler) {
    if (typeof handler !== 'function') throw new Error('Event handler must be a function: ' + type);
    if (typeof type !== 'string' || !type) throw new Error('Event name is required');
    type = canonical(type);
    var known = HOOKS.indexOf(type) >= 0 || NOTIFY.test(type) || type.indexOf('action:') === 0;
    if (!known) {
      // Any other name is a plugin-private event delivered by emit().
      if (!emitHandlers.has(type)) emitHandlers.set(type, []);
      emitHandlers.get(type).push(handler);
      return function () { remove(emitHandlers, type, handler); };
    }
    // Hooks and actions belong to the main script; panels may listen to
    // chat and message notifications.
    if (!isMain && !NOTIFY.test(type)) {
      throw new Error('Only the main script can register ' + type);
    }
    if (!handlers.has(type)) handlers.set(type, []);
    handlers.get(type).push(handler);
    post({ type: P + 'subscribe', event: type });
    return function () { remove(handlers, type, handler); };
  }

  function emit(name, detail) {
    if (typeof name !== 'string' || !name) throw new Error('Event name is required');
    var payload;
    try { payload = detail === undefined ? null : JSON.parse(JSON.stringify(detail)); } catch (e) { payload = null; }
    post({ type: P + 'emit', event: name, detail: payload });
  }

  function actionRegistrar(where) {
    return function (id, handler) {
      if (typeof id !== 'string' || !id) throw new Error('Action id is required');
      return on('action:' + where + ':' + id, handler);
    };
  }

  /* ---------- Settings and i18n ---------- */
  var configValues = Object.freeze(Object.assign({}, boot.config || {}));
  var settings = Object.freeze({
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

  var plugin = {
    id: boot.pluginId,
    kind: kind,
    panelId: boot.panelId || null,
    messageId: boot.messageId || null,
    on: on,
    emit: emit,
    onComposerAction: actionRegistrar('composer'),
    onToolsAction: actionRegistrar('tools'),
    onMessageAction: actionRegistrar('message'),
    registerFileHandler: function (id, handler) {
      if (typeof id !== 'string' || !id) throw new Error('File handler id is required');
      if (!handler || typeof handler.extract !== 'function') throw new Error('File handler needs extract()');
      if (fileHandlers.has(id)) throw new Error('File handler already registered: ' + id);
      fileHandlers.set(id, handler);
    },
    settings: settings,
  };
  if (i18n) plugin.i18n = i18n;
  glaze.plugin = Object.freeze(plugin);

  /* ---------- UI insets ---------- */
  var insets = Object.freeze(Object.assign({ topSafe: 0, topBar: 0, bottomInput: 0, bottomSafe: 0, keyboard: 0 }, boot.insets || {}));
  var insetListeners = new Set();
  var INSET_VARS = { topSafe: 'top-safe', topBar: 'top-bar', bottomInput: 'bottom-input', bottomSafe: 'bottom-safe', keyboard: 'keyboard' };
  function applyInsetVars() {
    var root = document.documentElement;
    // A converted plugin gets its own app's names from the compat layer.
    if (!root || boot.compat) return;
    Object.keys(INSET_VARS).forEach(function (k) {
      root.style.setProperty('--glaze-inset-' + INSET_VARS[k], insets[k] + 'px');
    });
  }
  applyInsetVars();
  glaze.ui = glaze.ui || {};
  glaze.ui.insets = function () { return insets; };
  glaze.ui.onInsetsChanged = function (fn) {
    if (typeof fn !== 'function') throw new Error('onInsetsChanged handler must be a function');
    insetListeners.add(fn);
    return function () { insetListeners.delete(fn); };
  };

  Object.keys(glaze).forEach(function (k) {
    if (glaze[k] && typeof glaze[k] === 'object' && k !== 'plugin') Object.freeze(glaze[k]);
  });
  glaze = Object.freeze(glaze);
  try {
    // The compat layer takes it away from converted plugins.
    Object.defineProperty(window, 'glaze', { value: glaze, writable: false, configurable: !!boot.compat });
  } catch (e) { window.glaze = glaze; }

  /* ---------- localStorage shim ---------- */
  // A null-origin frame has no Web Storage; keep a per-plugin copy in Glaze
  // and persist every write.
  var store = Object.assign({}, boot.storage || {});
  // Kept in UTF-8 bytes, as the app counts; a write past the quota throws
  // like a full browser storage and is not kept.
  var quota = boot.storageQuota > 0 ? boot.storageQuota : Infinity;
  var encoder = new TextEncoder();
  function bytes(s) { return encoder.encode(s).length; }
  var used = 0;
  Object.keys(store).forEach(function (k) { used += bytes(k) + bytes(store[k]); });
  var storage = {
    get length() { return Object.keys(store).length; },
    key: function (i) { var k = Object.keys(store); return i >= 0 && i < k.length ? k[i] : null; },
    getItem: function (k) { k = String(k); return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
    setItem: function (k, v) {
      k = String(k); v = String(v);
      var had = Object.prototype.hasOwnProperty.call(store, k);
      var next = used - (had ? bytes(k) + bytes(store[k]) : 0) + bytes(k) + bytes(v);
      if (next > quota) {
        throw new DOMException("Failed to execute 'setItem' on 'Storage': Setting the value of '" + k +
          "' exceeded the quota.", 'QuotaExceededError');
      }
      used = next;
      store[k] = v;
      fire('storage.set', [{ key: k, value: v }]);
    },
    removeItem: function (k) {
      k = String(k);
      if (!Object.prototype.hasOwnProperty.call(store, k)) return;
      used -= bytes(k) + bytes(store[k]);
      delete store[k];
      fire('storage.remove', [{ key: k }]);
    },
    clear: function () { store = {}; used = 0; fire('storage.clear', []); },
  };
  try { Object.defineProperty(window, 'localStorage', { value: storage, configurable: true }); } catch (e) { /* keep native */ }

  /* ---------- Host -> frame messages ---------- */
  function errorFrom(err) {
    var e = new Error((err && err.message) || 'Plugin call failed');
    if (err && err.code) e.code = err.code;
    return e;
  }

  function runHandlers(list, event) {
    (list || []).slice().forEach(function (fn) {
      try {
        var r = fn(event);
        if (r && typeof r.catch === 'function') r.catch(function (e) { console.error('[plugin]', e); });
      } catch (e) { console.error('[plugin]', e); }
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
    var cancellable = type === 'send:before';
    var allowEmpty = type !== 'generation:success';
    var timeout = type === 'generation:prepare' ? 0 : 5000;
    for (var i = 0; i < list.length; i++) {
      var draft = text, cancelled = false, reason = null, active = true;
      var event = Object.create(null);
      Object.keys(payload).forEach(function (k) {
        if (k !== 'text') Object.defineProperty(event, k, { value: payload[k], enumerable: true });
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
        console.error('[plugin] ' + type, e);
      }
    }
    return { text: text, cancelled: false };
  }

  async function runFileHandler(handlerId, file) {
    var handler = fileHandlers.get(handlerId);
    if (!handler) return { ok: false, error: { code: 'unregistered', message: 'Handler not registered' } };
    var controller = new AbortController();
    try {
      var result = await handler.extract(Object.freeze(Object.assign({}, file)), { signal: controller.signal });
      if (!result || typeof result.content !== 'string') {
        return { ok: false, error: { code: 'invalid_result', message: 'extract() must return { content: string }' } };
      }
      return { ok: true, content: result.content };
    } catch (e) {
      return { ok: false, error: { code: (e && e.code) || 'failed', message: String((e && e.message) || e).slice(0, 500) } };
    }
  }

  window.addEventListener('message', function (e) {
    if (e.source !== parentWin) return;
    var d = e.data;
    if (!d || typeof d.type !== 'string' || d.type.indexOf(P) !== 0) return;
    switch (d.type.slice(P.length)) {
      case 'result': {
        var p = pending.get(d.id);
        if (!p) return;
        pending.delete(d.id);
        if (d.ok) p.resolve(d.result === undefined ? null : d.result);
        else p.reject(errorFrom(d.error));
        return;
      }
      case 'event': {
        var type = canonical(d.event);
        var ev = Object.assign({}, d.payload || {}, { type: type, pluginId: boot.pluginId });
        runHandlers(handlers.get(type), Object.freeze(ev));
        if (/^message:(added|updated|deleted)$/.test(type)) {
          runHandlers(handlers.get('message:changed'), Object.freeze(Object.assign({}, ev, { type: 'message:changed' })));
        }
        return;
      }
      case 'vars':
        varCache[d.scope === 'global' ? 'global' : 'chat'] = d.value || {};
        return;
      case 'emit':
        runHandlers(emitHandlers.get(d.event), d.detail);
        return;
      case 'intercept':
        runInterceptor(d.event, d.payload || {}).then(function (result) {
          post({ type: P + 'reply', id: d.id, result: result });
        });
        return;
      case 'action': {
        var fn = (handlers.get(d.event) || [])[0];
        if (!fn) { post({ type: P + 'reply', id: d.id, result: { ok: false, reason: 'missing-handler' } }); return; }
        Promise.resolve().then(function () { return fn(d.args ? Object.freeze(d.args) : undefined); }).then(
          // What the handler returns rides along when it survives JSON.
          function (value) {
            var result = { ok: true };
            try { if (value != null) result.value = JSON.parse(JSON.stringify(value)); } catch (e) { /* dropped */ }
            post({ type: P + 'reply', id: d.id, result: result });
          },
          function (err) {
            console.error('[plugin] action', err);
            post({ type: P + 'reply', id: d.id, result: { ok: false, reason: 'handler-error', message: String(err && err.message || err) } });
          });
        return;
      }
      case 'file':
        runFileHandler(d.handlerId, d.file || {}).then(function (result) {
          post({ type: P + 'reply', id: d.id, result: result });
        });
        return;
      case 'insets':
        insets = Object.freeze(Object.assign({}, insets, d.insets || {}));
        applyInsetVars();
        insetListeners.forEach(function (fn) { try { fn(insets); } catch (err) { console.error(err); } });
        return;
      case 'i18n':
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

  /* ---------- Floating windows stay reachable ---------- */
  // A panel's draggable window could be dropped onto the message box, the
  // status bar or the system gesture strip, where a finger can no longer pick
  // it up (the strip belongs to the OS, and dragging out of it is the home
  // gesture) — and a plugin that saves its position put it back there on
  // every open. Fixed boxes are moved back between the safe top and the
  // message box after a drag, when they appear and when the insets settle.
  // A box covering the whole viewport is a panel meant to cover it, and stays
  // put.
  function keepFloatersReachable() {
    var MARGIN = 8;
    // The keyboard, or a bottom inset this tall (a drawer): temporary, and
    // moving buttons out from under it would strand them mid-screen.
    var MAX_RESTING_INSET = 0.35;
    var dragged = null;
    var known = new Set();
    var scanTimer = 0;

    var band = function () {
      return {
        top: (insets.topSafe || 0) + MARGIN,
        bottom: window.innerHeight - (insets.bottomInput || 0) - MARGIN,
        left: MARGIN,
        right: window.innerWidth - MARGIN,
      };
    };

    // Moves [el] by [delta] through the edge the plugin anchors it by, so its
    // next drag starts from the rescued spot instead of fighting a second one.
    var shift = function (el, cs, delta, start, end) {
      var s = el.style;
      var set = function (p) { var v = s.getPropertyValue(p); return !!v && v !== 'auto'; };
      if (set(end) && !set(start)) {
        s.setProperty(end, (parseFloat(cs.getPropertyValue(end)) || 0) - delta + 'px');
        return;
      }
      var hadStart = set(start);
      s.setProperty(start, (parseFloat(cs.getPropertyValue(start)) || 0) + delta + 'px');
      // Anchored by a stylesheet: let go of the other edge, or an auto-sized
      // box would stretch instead of move.
      if (!hadStart) s.setProperty(end, 'auto');
    };

    var rescue = function (el) {
      if (!el.isConnected) return;
      var cs = getComputedStyle(el);
      if (cs.position !== 'fixed' || cs.display === 'none' || cs.visibility !== 'visible' ||
          cs.pointerEvents === 'none') return;
      var r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return;
      // A panel covering the viewport exactly is a page of its own, not a
      // window: it is drawn behind the status bar on purpose.
      var vw = window.innerWidth, vh = window.innerHeight;
      if (r.left >= -0.5 && r.left <= 0.5 && r.top >= -0.5 && r.top <= 0.5 &&
          r.right >= vw - 0.5 && r.right <= vw + 0.5 &&
          r.bottom >= vh - 0.5 && r.bottom <= vh + 0.5) return;
      var b = band();
      // A box taller (or wider) than the band cannot fit whole: bring the off
      // edge back, so its handle stays on screen instead of vanishing past
      // the safe area.
      var tall = r.height > b.bottom - b.top;
      var wide = r.width > b.right - b.left;
      var dy = tall
        ? (r.top < b.top ? b.top - r.top : r.top > b.bottom ? b.top - r.top : 0)
        : (r.bottom > b.bottom ? b.bottom - r.bottom : r.top < b.top ? b.top - r.top : 0);
      var dx = wide
        ? (r.left < b.left ? b.left - r.left : r.left > b.right ? b.left - r.left : 0)
        : (r.right > b.right ? b.right - r.right : r.left < b.left ? b.left - r.left : 0);
      if (Math.abs(dy) >= 1) shift(el, cs, dy, 'top', 'bottom');
      if (Math.abs(dx) >= 1) shift(el, cs, dx, 'left', 'right');
    };

    var scan = function () {
      scanTimer = 0;
      if (insets.keyboard || (insets.bottomInput || 0) > window.innerHeight * MAX_RESTING_INSET) return;
      known.forEach(function (el) { if (!el.isConnected) known.delete(el); });
      var seen = new Set(known);
      var walk = function (el, depth) {
        for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
          seen.add(c);
          if (depth < 2) walk(c, depth + 1);
        }
      };
      // From <html>, as the hit boxes are: a box may hang next to <body>.
      walk(document.documentElement, -1);
      seen.delete(document.head);
      seen.delete(document.body);
      seen.forEach(rescue);
    };
    var scheduleScan = function (ms) {
      clearTimeout(scanTimer);
      scanTimer = setTimeout(scan, ms);
    };

    window.addEventListener('pointerdown', function (e) {
      dragged = null;
      for (var n = e.target; n && n.nodeType === 1 && n !== document.body; n = n.parentElement) {
        if (getComputedStyle(n).position === 'fixed') { dragged = n; break; }
      }
    }, true);
    ['pointerup', 'pointercancel', 'touchend', 'mouseup'].forEach(function (type) {
      window.addEventListener(type, function () {
        var el = dragged;
        if (!el) return;
        dragged = null;
        known.add(el);
        // After the plugin's own release handler has placed it, and again
        // after a snap-to-edge animation.
        setTimeout(function () { rescue(el); }, 50);
        setTimeout(function () { rescue(el); }, 450);
      }, true);
    });
    var watch = function () {
      new MutationObserver(function () { scheduleScan(300); })
        .observe(document.body, { childList: true, subtree: true });
      scheduleScan(300);
    };
    if (document.body) watch();
    else document.addEventListener('DOMContentLoaded', watch);
    insetListeners.add(function () { scheduleScan(500); });
    // Width only: a rotation. A height-only change is the keyboard.
    var lastWidth = window.innerWidth;
    window.addEventListener('resize', function () {
      if (window.innerWidth === lastWidth) return;
      lastWidth = window.innerWidth;
      scheduleScan(500);
    });
  }

  /* ---------- Layout reports ---------- */
  if (kind === 'panel') {
    // A chat panel covers the whole page, but only the boxes the plugin
    // draws may take touches; the host clips the frame to these rectangles.
    var SKIP = { HEAD: 1, SCRIPT: 1, STYLE: 1, LINK: 1, META: 1, TEMPLATE: 1, NOSCRIPT: 1 };
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
      // From <html>: a script may hang its boxes there, next to <body>.
      walk(document.documentElement, null);
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
      post({ type: P + 'hit', rects: out });
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
    keepFloatersReachable();
  } else if (kind === 'message') {
    // Message panels sit in the message flow; the host sizes the frame to
    // the content height reported here.
    var lastHeight = -1;
    var report = function () {
      var body = document.body;
      if (!body) return;
      var h = Math.ceil(Math.max(body.scrollHeight, document.documentElement.scrollHeight));
      if (!body.firstElementChild && !body.textContent.trim()) h = 0;
      if (h === lastHeight) return;
      lastHeight = h;
      post({ type: P + 'size', height: h });
    };
    var start = function () {
      document.documentElement.style.overflow = 'hidden';
      if (typeof ResizeObserver === 'function') new ResizeObserver(report).observe(document.documentElement);
      new MutationObserver(report).observe(document.documentElement, { subtree: true, childList: true, attributes: true });
      window.addEventListener('load', report);
      report();
    };
    if (document.body) start();
    else document.addEventListener('DOMContentLoaded', start);
  }

  post({ type: P + 'ready' });
})();
