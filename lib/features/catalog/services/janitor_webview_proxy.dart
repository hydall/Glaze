import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../chat/bridge/chat_webview_environment.dart';
import 'cf_challenge_service.dart';
import 'janitor_separate.dart';

void _log(String m) => debugPrint('[CF-proxy] $m');

/// JS that locates the JanitorAI account access token and returns it (or null).
///
/// JanitorAI uses a Supabase (`@supabase/ssr`) session. The token is stored in
/// **cookies** named `sb-<ref>-auth-token`, split across numbered chunks
/// (`…-auth-token.0`, `.1`, …) whose concatenated value is `base64-<base64 of
/// the session JSON>`. So we: gather the chunks, strip the `base64-` prefix,
/// base64-decode (tolerating base64url), and pull `access_token` out of the
/// JSON. We also fall back to scanning `localStorage` for older/plain layouts.
/// Returns null when logged out (requests stay anonymous).
///
/// Raw string: the regexes use `\d`, `\.` and `$`, which a normal Dart string
/// would mangle. No Dart interpolation is needed here.
const String _findTokenJs = r'''
  const __glazeFindToken = () => {
    const b64decode = (s) => {
      try { return atob(s); } catch (e) {}
      try { return atob(s.replace(/-/g, "+").replace(/_/g, "/")); } catch (e) {}
      return null;
    };
    const extract = (raw) => {
      if (!raw) return null;
      try { raw = decodeURIComponent(raw); } catch (e) {}
      if (raw.indexOf("base64-") === 0) raw = raw.slice(7);
      if (raw.indexOf("eyJ") === 0 && raw.split(".").length === 3) return raw;
      const sources = [b64decode(raw), raw];
      for (let si = 0; si < sources.length; si++) {
        const s = sources[si];
        if (!s) continue;
        const m = s.match(/"access_token":"(eyJ[^"]+)"/);
        if (m) return m[1];
        try {
          const o = JSON.parse(s);
          const c = o && (o.access_token || o.accessToken || o.token ||
            (o.currentSession && o.currentSession.access_token) ||
            (Array.isArray(o) ? o[0] : null));
          if (typeof c === "string" && c.indexOf("eyJ") === 0) return c;
        } catch (e) {}
      }
      return null;
    };
    // 1) Chunked Supabase SSR cookies: sb-<ref>-auth-token(.N)
    try {
      const parts = {};
      const cookies = (document.cookie || "").split("; ");
      for (let i = 0; i < cookies.length; i++) {
        const c = cookies[i];
        const eq = c.indexOf("=");
        if (eq < 0) continue;
        const name = c.slice(0, eq);
        const val = c.slice(eq + 1);
        const m = name.match(/^(sb-.*-auth-token)(?:\.(\d+))?$/);
        if (!m) continue;
        const base = m[1];
        const idx = m[2] ? parseInt(m[2], 10) : 0;
        if (!parts[base]) parts[base] = {};
        parts[base][idx] = val;
      }
      for (const base in parts) {
        const idxs = Object.keys(parts[base]).map(Number).sort((a, b) => a - b);
        let joined = "";
        for (let j = 0; j < idxs.length; j++) joined += parts[base][idxs[j]];
        const t = extract(joined);
        if (t) return t;
      }
    } catch (e) {}
    // 2) localStorage fallback (older / plain layouts)
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const t = extract(localStorage.getItem(localStorage.key(i)));
        if (t) return t;
      }
    } catch (e) {}
    return null;
  };
''';

/// Document-start user script installed before navigating to a chat page when
/// capturing a `generateAlpha` payload. It does two things, mirroring the
/// SillyTavern `janitor-lorebook` plugin's Playwright capture:
///
/// 1. **Intercepts** the assembled prompt. JanitorAI's frontend, in proxy/API
///    mode, calls `…/generateAlpha` and the *response* is the fully-assembled
///    `{messages:[{role:"system", …}]}` — the system message contains the
///    hidden card + the triggered (closed) lorebook entries. We wrap both
///    `fetch` and `XMLHttpRequest` (the site may use either) and stash the last
///    matching payload on `window.__glazeAlpha`.
/// 2. Exposes **`window.__glazeSend(text)`** which types [text] into the chat
///    input and submits — the trigger that makes the server assemble + return
///    the prompt. Ported from `capture.cjs` `_send`/`_autoTrigger`, including
///    the React controlled-input trick (native value setter + `input` event;
///    a plain `el.value = …` leaves React's state empty and the send no-ops).
///
/// Injected at document start so it hooks the network *before* page scripts
/// capture their own `fetch` reference. **Brittle by nature:** the input/send
/// selectors track JanitorAI's chat DOM, exactly like the plugin's Playwright
/// selectors — tune [_captureUserScript] if the site changes.
const String _captureUserScript = r'''
  (function () {
    if (window.__glazeHooked) return;
    window.__glazeHooked = true;
    window.__glazeAlpha = null;

    const looksLikePayload = (o) =>
      o && Array.isArray(o.messages) &&
      o.messages.some((m) => m && m.role === 'system' && typeof m.content === 'string');

    // --- fetch hook ---
    const origFetch = window.fetch ? window.fetch.bind(window) : null;
    if (origFetch) {
      window.fetch = async function (...args) {
        const res = await origFetch(...args);
        try {
          const a0 = args[0];
          const url = (a0 && a0.url) ? a0.url : (typeof a0 === 'string' ? a0 : '');
          if (typeof url === 'string' && url.indexOf('/generateAlpha') >= 0) {
            res.clone().json().then((j) => {
              if (looksLikePayload(j)) window.__glazeAlpha = j;
            }).catch(() => {});
          }
        } catch (e) {}
        return res;
      };
    }

    // --- XMLHttpRequest hook ---
    const OrigXHR = window.XMLHttpRequest;
    if (OrigXHR) {
      const open = OrigXHR.prototype.open;
      OrigXHR.prototype.open = function (method, url) {
        this.__glazeUrl = url;
        return open.apply(this, arguments);
      };
      OrigXHR.prototype.addEventListener &&
        (function () {
          const send = OrigXHR.prototype.send;
          OrigXHR.prototype.send = function () {
            this.addEventListener('load', function () {
              try {
                if (typeof this.__glazeUrl === 'string' &&
                    this.__glazeUrl.indexOf('/generateAlpha') >= 0) {
                  const j = JSON.parse(this.responseText);
                  if (looksLikePayload(j)) window.__glazeAlpha = j;
                }
              } catch (e) {}
            });
            return send.apply(this, arguments);
          };
        })();
    }

    // --- chat input + send ---
    const SEL = ['textarea[placeholder]', 'form textarea', 'textarea', 'div[contenteditable="true"]'];
    const findInput = () => {
      for (const s of SEL) {
        const els = document.querySelectorAll(s);
        for (let i = els.length - 1; i >= 0; i--) {
          const el = els[i];
          if (el && el.offsetParent !== null) return el;
        }
      }
      return null;
    };
    const setReactValue = (el, val) => {
      if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
        const proto = el.tagName === 'TEXTAREA'
          ? window.HTMLTextAreaElement.prototype
          : window.HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(el, val);
        el.dispatchEvent(new Event('input', { bubbles: true }));
      } else {
        el.focus();
        el.textContent = val;
        el.dispatchEvent(new InputEvent('input', { bubbles: true }));
      }
    };
    const pressEnter = (el) => {
      for (const type of ['keydown', 'keypress', 'keyup']) {
        const ev = new KeyboardEvent(type, {
          key: 'Enter', code: 'Enter', bubbles: true, cancelable: true,
        });
        // The KeyboardEvent constructor ignores keyCode/which (they stay 0), but
        // legacy "send on Enter" handlers often gate on e.keyCode/e.which === 13.
        // Force them so a synthetic Enter can still trigger a send.
        try {
          Object.defineProperty(ev, 'keyCode', { get: () => 13 });
          Object.defineProperty(ev, 'which', { get: () => 13 });
        } catch (e) {}
        el.dispatchEvent(ev);
      }
    };
    // Whether a button is a live, clickable "send" control (not a stop/cancel).
    // aria-label stays English across UI locales (confirmed on a Polish client),
    // so it's the reliable signal; the hashed `_sendButton_…` class is a backup.
    const isSendBtn = (b) => {
      if (!b || b.offsetParent === null || b.disabled) return false;
      const label = (b.getAttribute('aria-label') || '').toLowerCase();
      if (label.indexOf('stop') >= 0 || label.indexOf('cancel') >= 0) return false;
      return true;
    };
    // Locate the composer's send button. JanitorAI's composer no longer submits
    // on a bare Enter in every layout (the text just sits unsent), so we click
    // its send button: `<button aria-label="Send" class="_sendButton_…">` (not a
    // submit, not inside a <form>). Fall back to the last live button in the
    // container holding the input.
    const findSendButton = (input) => {
      const cands = document.querySelectorAll(
        'button[aria-label*="send" i], ' +
        'button[class*="sendButton" i], ' +
        'button[type="submit"]');
      for (let i = 0; i < cands.length; i++) {
        if (isSendBtn(cands[i])) return cands[i];
      }
      const scope = input.closest('form') || input.parentElement;
      if (scope) {
        const btns = Array.prototype.slice
          .call(scope.querySelectorAll('button')).filter(isSendBtn);
        if (btns.length) return btns[btns.length - 1];
      }
      return null;
    };
    // A visible stop/cancel button means a previous send is still streaming (or
    // hanging against the unreachable dummy proxy), which disables the composer.
    const findStopButton = () => {
      const btns = document.querySelectorAll(
        'button[aria-label*="stop" i], button[aria-label*="cancel" i]');
      for (let i = 0; i < btns.length; i++) {
        if (btns[i].offsetParent !== null && !btns[i].disabled) return btns[i];
      }
      return null;
    };
    // JanitorAI occasionally throws a modal over the chat (persona picker,
    // content disclaimer, "what's new" popup…). Its backdrop (`_modalOverlay_…`)
    // sits above the composer and swallows the interaction, so the send never
    // lands. Best-effort dismiss: click an explicit close control inside the
    // dialog, else press Escape, and wait for the overlay to detach. No-op when
    // nothing is open. Port of JAR's dismissModals().
    const findOverlay = () => {
      const els = document.querySelectorAll(
        '[class*="modalOverlay" i], [class*="ModalOverlay"]');
      for (let i = els.length - 1; i >= 0; i--) {
        if (els[i] && els[i].offsetParent !== null) return els[i];
      }
      return null;
    };
    const pressEscape = () => {
      for (const type of ['keydown', 'keypress', 'keyup']) {
        const ev = new KeyboardEvent(type, {
          key: 'Escape', code: 'Escape', bubbles: true, cancelable: true,
        });
        // The KeyboardEvent constructor leaves keyCode/which at 0; legacy
        // "close on Escape" handlers gate on e.keyCode === 27, so force it.
        try {
          Object.defineProperty(ev, 'keyCode', { get: () => 27 });
          Object.defineProperty(ev, 'which', { get: () => 27 });
        } catch (e) {}
        (document.activeElement || document.body).dispatchEvent(ev);
        document.dispatchEvent(ev);
      }
    };
    const dismissModals = async (timeout) => {
      const deadline = Date.now() + (timeout || 4000);
      while (Date.now() < deadline) {
        const overlay = findOverlay();
        if (!overlay) return;
        // Prefer an explicit close button inside the dialog over dismissing blindly.
        const close = document.querySelector(
          '[class*="modal" i] button[aria-label*="close" i], ' +
          '[role="dialog"] button[aria-label*="close" i]');
        if (close && close.offsetParent !== null) {
          close.click();
        } else {
          pressEscape();
        }
        await new Promise((r) => setTimeout(r, 300));
      }
    };
    window.__glazeSend = async (text) => {
      // 0) A modal overlay (persona picker, disclaimer, promo popup…) can sit
      //    over the composer and swallow the interaction; clear it before we
      //    touch the input. Mirrors JAR's dismissModals() call in sendMessage.
      await dismissModals();
      const el = findInput();
      if (!el) return { ok: false, reason: 'no-input' };
      // 1) Abort any leftover generation from a previous send — it may still be
      //    streaming / hanging against the unreachable dummy proxy, which keeps
      //    the composer disabled so the next message can't go out. We already
      //    captured the generateAlpha payload (it fires BEFORE the proxy POST),
      //    so aborting the dead-proxy call is safe.
      const abortDeadline = Date.now() + 15000;
      while (Date.now() < abortDeadline) {
        const stop = findStopButton();
        if (!stop) break;
        stop.click();
        await new Promise((r) => setTimeout(r, 300));
      }
      // 2) Type the message into the now-idle composer.
      el.focus();
      setReactValue(el, text);
      // 3) Poll for the enabled send button (it enables a few frames after React
      //    ingests the value) and click it. A new overlay may have slipped in
      //    between the dismiss above and now (JanitorAI pops the persona picker
      //    on the first send of a fresh chat), so clear it once more first.
      await dismissModals();
      let btn = null;
      const deadline = Date.now() + 15000;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 200));
        btn = findSendButton(el);
        if (btn) break;
      }
      if (btn) { btn.click(); } else { pressEnter(el); }
      return { ok: true, sent: btn ? 'click' : 'enter' };
    };
  })();
''';

/// Thrown when the proxy could not obtain a CF-cleared response.
class JanitorCfException implements Exception {
  final int status;
  JanitorCfException(this.status);
  @override
  String toString() => 'JanitorCfException(status=$status)';
}

/// Persistent offscreen WebView that runs janitorai.com API requests from
/// inside a real Chromium session.
///
/// **Why this exists.** Cloudflare binds `cf_clearance` to the TLS/JA3
/// fingerprint of the client that solved the Turnstile challenge. A cookie
/// obtained in a WebView cannot be replayed by Dio — the Dart HTTP stack
/// produces a different TLS handshake, so CF answers 403 even with the exact
/// same cookie + User-Agent. Running `fetch()` *inside* the page keeps the same
/// fingerprint and cookie jar, so the request passes.
///
/// **Turnstile.** The non-interactive (managed) challenge janitorai.com serves
/// is solved transparently just by loading the page — no user interaction. If CF
/// escalates to an interactive challenge, [_escalateToVisible] surfaces the
/// existing visible WebView ([CfChallengeService] / `_CfChallengeWebView`) for
/// the user to solve once; the offscreen session is then reused.
class JanitorWebViewProxy {
  JanitorWebViewProxy._();
  static final JanitorWebViewProxy instance = JanitorWebViewProxy._();

  static final WebUri _origin = WebUri('https://janitorai.com');

  // JanitorAI migrated proxy presets out of the profile blob (`/profiles/mine`)
  // into a dedicated REST resource under `/hampter/api-settings` (July 2026):
  //   GET    /hampter/api-settings                  → { proxy_configs, settings }
  //   POST   /hampter/api-settings/proxy-configs     → create a preset (we own
  //                                                    `client_id`, server assigns `id`)
  //   PATCH  /hampter/api-settings                   → partial settings merge
  //   DELETE /hampter/api-settings/proxy-configs/{id} → remove a preset
  static const String _apiSettingsUrl =
      'https://janitorai.com/hampter/api-settings';
  static const String _proxyConfigsUrl =
      'https://janitorai.com/hampter/api-settings/proxy-configs';

  /// Builds the throwaway proxy preset (the POST `/proxy-configs` body). The URL
  /// is intentionally unreachable: we capture the `/generateAlpha` RESPONSE (the
  /// assembled prompt) BEFORE the client ever POSTs to the proxy, so the proxy
  /// never needs to answer.
  ///
  /// `client_id` is a fresh random UUID every run: JanitorAI permanently burns
  /// each client_id, so reusing one (even after deleting its preset) returns 409
  /// API_SETTINGS_PROXY_CONFIG_CONFLICT. The name/port/api_key are randomised so
  /// the preset isn't fingerprintable by a constant string/port, and a non-blank
  /// api_key is required (the frontend rejects presets with a blank key).
  static Map<String, dynamic> _buildDummyPreset() {
    final port = 8001 + Random().nextInt(57000); // 8001..65000
    return {
      'api_key': 'sk-${_randomString(48)}',
      'api_url': 'http://127.0.0.1:$port/v1/chat/completions',
      'model': 'gpt-4o',
      'name': _randomString(12),
      'prompt_id': null,
      'client_id': _uuidV4(),
    };
  }

  /// Random lowercase-alphanumeric string of [len] chars.
  static String _randomString(int len) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List.generate(len, (_) => alphabet[rand.nextInt(alphabet.length)])
        .join();
  }

  /// RFC-4122 v4 UUID — the Dart equivalent of JAR's `crypto.randomUUID()`,
  /// used for the proxy preset's `client_id`.
  static String _uuidV4() {
    final rand = Random.secure();
    final b = List<int>.generate(16, (_) => rand.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Completer<void>? _starting;

  /// Completes on the next `onLoadStop` for a janitorai.com page. Reset before
  /// every navigation so we can await the document actually being loaded —
  /// `callAsyncJavaScript` hangs forever if invoked while the page is still
  /// `about:blank`, so we must never fetch before a real load lands.
  Completer<void>? _loadStop;

  /// Serializes navigations / solves so concurrent [fetch] calls can't race on
  /// reload or escalation. Requests run one at a time; each is a single in-page
  /// round trip, so the latency cost is negligible for catalog browsing.
  Future<void> _gate = Future<void>.value();

  /// Whether the JanitorAI catalog is currently the foreground view. Driven by
  /// [setActive] from the UI so the offscreen WebView only lives while the
  /// catalog is open — it is never kept warm in the background.
  bool _active = false;
  Timer? _shutdownTimer;

  /// Called by the catalog UI to mark the JanitorAI catalog visible/hidden.
  /// On hide we tear the WebView down after a short grace period (debounces the
  /// branch cross-fade and sub-tab toggles); on show we just cancel any pending
  /// shutdown — the WebView itself is (re)created lazily on the next [fetch].
  void setActive(bool active) {
    if (active) {
      _shutdownTimer?.cancel();
      _shutdownTimer = null;
      if (!_active) _log('catalog active');
      _active = true;
    } else {
      if (!_active) return;
      _active = false;
      _log('catalog hidden — scheduling shutdown');
      _shutdownTimer?.cancel();
      _shutdownTimer = Timer(const Duration(seconds: 3), () {
        if (!_active) dispose();
      });
    }
  }

  /// Fetches [url] (must be a janitorai.com URL) from inside the WebView session
  /// and returns the raw response body. Throws [JanitorCfException] if CF cannot
  /// be cleared, or [Exception] on other HTTP errors.
  ///
  /// [method] defaults to GET; pass e.g. `'PATCH'` with a JSON [body] string to
  /// mutate account data (the body is sent as `application/json`). Mutating
  /// requests need an account session — the bearer token is attached in-page.
  Future<String> fetch(String url, {String method = 'GET', String? body}) {
    final completer = Completer<String>();
    _gate = _gate.then((_) async {
      try {
        completer.complete(await _fetchLocked(url, method: method, body: body));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Captures the assembled `generateAlpha` payload for [characterId] — the
  /// fully-built system prompt containing the hidden character card and the
  /// triggered (closed) lorebook entries. Port of the SillyTavern
  /// `janitor-lorebook` plugin's `runFromUrl`/`_autoTrigger`.
  ///
  /// Pipeline (serialized through [_gate]): create a fresh chat, navigate the
  /// offscreen WebView to it with [_captureUserScript] installed, send `"."` to
  /// surface the card, then re-send the card text (+ optional [triggerText],
  /// e.g. the first message) to maximise lorebook keyword matches, and return
  /// the captured payload. Throws on timeout / login / CF failure.
  Future<Map<String, dynamic>> captureGenerateAlpha({
    required String characterId,
    String triggerText = '',
    void Function(String phase)? onPhase,
  }) {
    final completer = Completer<Map<String, dynamic>>();
    _gate = _gate.then((_) async {
      try {
        completer.complete(
            await _captureLocked(characterId, triggerText, onPhase));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<Map<String, dynamic>> _captureLocked(
    String characterId,
    String triggerText,
    void Function(String phase)? onPhase,
  ) async {
    void phase(String p) {
      _log('capture phase: $p');
      onPhase?.call(p);
    }

    phase('starting');
    await _ensureStarted();

    if (!await isLoggedIn()) {
      throw Exception('Not logged into JanitorAI — log in first (Menu → JanitorAI).');
    }

    // Force the account into proxy mode against an unreachable dummy preset (and
    // context_length 0) so the captured `/generateAlpha` prompt keeps its
    // wrappers and isn't truncated/reordered. Restored in the finally below.
    // Without this, an account on JLLM ("janitor") never assembles a proxy
    // prompt — the send just runs on Janitor's own model.
    phase('configuring proxy');
    final profileSnapshot = await _enterExtractionMode();
    try {
      // 1) Create a fresh chat for this character.
      phase('creating chat');
      final chatBody = await _fetchLocked(
        'https://janitorai.com/hampter/chats',
        method: 'POST',
        body: jsonEncode({'character_id': characterId}),
      );
      final chatJson = jsonDecode(chatBody);
      final chatId = (chatJson is Map ? chatJson['id'] : null)?.toString();
      if (chatId == null || chatId.isEmpty) {
        throw Exception('Could not create chat (no id in response).');
      }

      final controller = _controller;
      if (controller == null) throw Exception('WebView not available.');

      // 2) Install the capture hook at document start, then open the chat.
      phase('opening chat');
      await controller.removeAllUserScripts();
      await controller.addUserScript(
        userScript: UserScript(
          source: _captureUserScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
      try {
        _loadStop = Completer<void>();
        await controller.loadUrl(
          urlRequest: URLRequest(
            url: WebUri('https://janitorai.com/chats/$chatId'),
          ),
        );
        await _awaitLoad();
        await _waitForClearance();

        // JanitorAI caches the selected proxy preset in its client store, so the
        // dummy preset switched in by _enterExtractionMode() above may not take
        // effect on the first chat load — the captured `/generateAlpha` would
        // then run against the previous (e.g. JLLM) preset and lose its wrappers.
        // Reload the chat page once to force the new preset to take effect before
        // triggering. The AT_DOCUMENT_START capture hook re-injects on reload.
        phase('reloading for preset');
        _loadStop = Completer<void>();
        await controller.reload();
        await _awaitLoad();
        await _waitForClearance();

        // Give the React chat app time to hydrate before driving the input.
        await Future<void>.delayed(const Duration(milliseconds: 2500));

        // 3) Send "." → capture the card.
        phase('triggering (card)');
        final dot = await _captureOneSend('.', const Duration(seconds: 60));
        final card = dot != null ? extractCard(dot) : '';

        // 4) Send card (+ first message) → maximise lorebook triggers.
        final parts = <String>[
          if (card.isNotEmpty) card,
          if (triggerText.trim().isNotEmpty) triggerText.trim(),
        ];
        final trigger = parts.isEmpty ? '.' : parts.join('\n\n');
        phase('triggering (lorebook)');
        await _resetCapture();
        final full =
            await _captureOneSend(trigger, const Duration(seconds: 120));
        final result = full ?? dot;
        if (result == null) {
          throw Exception('Timed out waiting for a generateAlpha capture.');
        }
        phase('captured');
        return result;
      } finally {
        try {
          await controller.removeAllUserScripts();
        } catch (_) {}
      }
    } finally {
      if (profileSnapshot != null) {
        phase('restoring profile');
        await _restoreProfile(profileSnapshot);
      }
    }
  }

  /// Reshapes the JanitorAI API settings so a capture yields a clean, tag-wrapped
  /// prompt, returning a snapshot to restore afterwards. Port of JAR `profile.js`
  /// (the `/hampter/api-settings` rewrite). Two things must hold:
  ///  1. a custom OpenAI-compatible PROXY preset must be selected (not JLLM) —
  ///     only then does the client assemble the prompt for a proxy and fire
  ///     `/generateAlpha` with the `<…Persona>` / `<Scenario>` wrappers that
  ///     [separate] relies on;
  ///  2. `generation_settings.context_length` must be 0, or the server
  ///     compresses/reorders the prompt to fit and unwraps the persona block.
  ///
  /// We snapshot the current selection + generation settings, create + select a
  /// throwaway proxy preset and force context_length 0, run the capture, then
  /// restore the snapshot and delete the dummy (see [_restoreProfile]). Returns
  /// null if the settings could not be read/patched (capture proceeds against
  /// whatever the account has selected).
  Future<Map<String, dynamic>?> _enterExtractionMode() async {
    String? dummyServerId;
    try {
      final before = jsonDecode(await _fetchLocked(_apiSettingsUrl));
      final settings = (before is Map && before['settings'] is Map)
          ? Map<String, dynamic>.from(before['settings'] as Map)
          : <String, dynamic>{};
      final originalSelectedId = settings['selected_proxy_config_id'];
      final originalSource = settings['source'];
      final originalGen = settings['generation_settings'] is Map
          ? Map<String, dynamic>.from(settings['generation_settings'] as Map)
          : null;

      // Create the throwaway preset, then re-read to resolve the server-assigned
      // id (the POST body only carries our client_id).
      final dummy = _buildDummyPreset();
      await _fetchLocked(_proxyConfigsUrl,
          method: 'POST', body: jsonEncode(dummy));
      final after = jsonDecode(await _fetchLocked(_apiSettingsUrl));
      final configs = (after is Map && after['proxy_configs'] is List)
          ? (after['proxy_configs'] as List)
          : const <dynamic>[];
      final created = configs.firstWhere(
        (p) => p is Map && p['client_id'] == dummy['client_id'],
        orElse: () => null,
      );
      dummyServerId = (created is Map ? created['id'] : null)?.toString();
      if (dummyServerId == null || dummyServerId.isEmpty) {
        throw Exception('dummy proxy preset not found after create');
      }

      // Select it as the active proxy. This is the must-have.
      await _patchApiSettings({'selected_proxy_config_id': dummyServerId});

      // Best-effort extras, isolated so a rejection can't undo the selection:
      // ensure proxy mode, and force context_length 0.
      try {
        await _patchApiSettings({'source': 'proxy'});
      } catch (e) {
        _log('could not force source=proxy: $e');
      }
      try {
        await _patchApiSettings({
          'generation_settings': {...?originalGen, 'context_length': 0},
        });
      } catch (e) {
        _log('could not force context_length 0: $e');
      }

      _log('extraction mode on (dummy proxy $dummyServerId selected, '
          'context_length 0)');
      return {
        'selectedProxyConfigId': originalSelectedId,
        'source': originalSource,
        'generationSettings': originalGen,
        'dummyServerId': dummyServerId,
      };
    } catch (e) {
      _log('enterExtractionMode failed (capture proceeds anyway): $e');
      // If we created the dummy before failing, remove it so it doesn't orphan.
      if (dummyServerId != null && dummyServerId.isNotEmpty) {
        try {
          await _deleteProxyConfig(dummyServerId);
        } catch (_) {}
      }
      return null;
    }
  }

  /// Restores the original selection / source / generation settings and deletes
  /// the injected dummy preset.
  Future<void> _restoreProfile(Map<String, dynamic> snapshot) async {
    final patch = <String, dynamic>{
      'selected_proxy_config_id': snapshot['selectedProxyConfigId'],
    };
    if (snapshot['source'] != null) patch['source'] = snapshot['source'];
    if (snapshot['generationSettings'] != null) {
      patch['generation_settings'] = snapshot['generationSettings'];
    }
    try {
      await _patchApiSettings(patch);
    } catch (e) {
      _log('restore settings failed: $e');
    }
    final dummyServerId = snapshot['dummyServerId'];
    if (dummyServerId is String && dummyServerId.isNotEmpty) {
      try {
        await _deleteProxyConfig(dummyServerId);
      } catch (e) {
        _log('dummy delete failed: $e');
      }
    }
    _log('restored api-settings (selection + generation settings, dummy removed)');
  }

  /// Partial merge-PATCH of the top-level api-settings (selected proxy, source,
  /// generation_settings…).
  Future<void> _patchApiSettings(Map<String, dynamic> patch) async {
    await _fetchLocked(_apiSettingsUrl,
        method: 'PATCH', body: jsonEncode(patch));
  }

  /// DELETE a proxy preset by its server-assigned id.
  Future<void> _deleteProxyConfig(String serverId) async {
    await _fetchLocked('$_proxyConfigsUrl/$serverId', method: 'DELETE');
  }

  /// Clears the last captured payload so the next send's capture is unambiguous.
  Future<void> _resetCapture() async {
    try {
      await _controller?.evaluateJavascript(source: 'window.__glazeAlpha = null;');
    } catch (_) {}
  }

  /// Drives one `__glazeSend(text)` and polls `window.__glazeAlpha` until a
  /// payload appears or [timeout] elapses. Returns null on timeout.
  Future<Map<String, dynamic>?> _captureOneSend(String text, Duration timeout) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      await controller.callAsyncJavaScript(
        functionBody: 'return await window.__glazeSend(${jsonEncode(text)});',
      );
    } catch (e) {
      _log('send error: $e');
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      try {
        final res = await controller.evaluateJavascript(
          source: 'window.__glazeAlpha ? JSON.stringify(window.__glazeAlpha) : null',
        );
        if (res is String && res.isNotEmpty && res != 'null') {
          final decoded = jsonDecode(res);
          if (decoded is Map<String, dynamic>) return decoded;
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return null;
  }

  /// Whether a JanitorAI account session is present (a JWT lives in the shared
  /// `localStorage`). Boots the offscreen WebView if needed.
  Future<bool> isLoggedIn() async {
    await _ensureStarted();
    final controller = _controller;
    if (controller == null) return false;
    try {
      final res = await controller
          .callAsyncJavaScript(
            functionBody: '$_findTokenJs return __glazeFindToken() != null;',
          )
          .timeout(const Duration(seconds: 10));
      return res?.value == true;
    } catch (e) {
      _log('isLoggedIn error: $e');
      return false;
    }
  }

  /// Returns true if a JanitorAI account token is detectable from [controller]'s
  /// page (shared cookie jar / `localStorage`). The login sheet uses this to
  /// confirm the session was actually persisted before it auto-closes — the
  /// sheet's visible WebView shares the same storage as this headless proxy, so
  /// a token visible here will be visible to catalog requests too.
  static Future<bool> hasSessionToken(InAppWebViewController controller) async {
    try {
      final res = await controller
          .callAsyncJavaScript(
            functionBody: '$_findTokenJs return __glazeFindToken() != null;',
          )
          .timeout(const Duration(seconds: 8));
      return res?.value == true;
    } catch (e) {
      _log('hasSessionToken error: $e');
      return false;
    }
  }

  /// Reads the signed-in JanitorAI profile's `user_name` from [controller]'s
  /// page, mirroring the request the site front-end makes after login
  /// (`GET /hampter/profiles/mine`). Runs in-page so it shares the cookie jar and
  /// CF fingerprint, and attaches the Supabase bearer token like [_rawFetch].
  /// Returns null when logged out or on any error.
  static Future<String?> fetchUserName(
    InAppWebViewController controller,
  ) async {
    try {
      final res = await controller
          .callAsyncJavaScript(
            functionBody: '''
              $_findTokenJs
              const token = __glazeFindToken();
              if (!token) return null;
              const r = await fetch(
                "https://janitorai.com/hampter/profiles/mine",
                {
                  headers: {
                    "Accept": "application/json, text/plain, */*",
                    "authorization": "Bearer " + token,
                  },
                  credentials: "include",
                },
              );
              if (!r.ok) return null;
              const j = await r.json();
              return (j && typeof j.user_name === "string") ? j.user_name : null;
            ''',
          )
          .timeout(const Duration(seconds: 10));
      final value = res?.value;
      return (value is String && value.isNotEmpty) ? value : null;
    } catch (e) {
      _log('fetchUserName error: $e');
      return null;
    }
  }

  /// Clears the JanitorAI account session (cookies + DOM storage) and reloads
  /// the offscreen page so subsequent requests are anonymous again.
  Future<void> logout() async {
    final controller = _controller;
    if (controller != null) {
      try {
        await controller.evaluateJavascript(
          source: 'try { localStorage.clear(); sessionStorage.clear(); } catch (e) {}',
        );
      } catch (_) {}
    }
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {}
    await _reload();
  }

  Future<String> _fetchLocked(
    String url, {
    String method = 'GET',
    String? body,
  }) async {
    await _ensureStarted();

    var result = await _rawFetch(url, method: method, body: body);

    // Soft block: reload the page to re-run Turnstile and refresh cf_clearance.
    if (_isCfBlocked(result)) {
      _log('CF block on fetch — reloading session');
      await _reload();
      result = await _rawFetch(url, method: method, body: body);
    }

    // Still blocked: CF wants an interactive challenge. Surface the visible
    // WebView for the user, then reuse the refreshed session.
    if (_isCfBlocked(result)) {
      _log('CF block persists — escalating to visible challenge');
      await _escalateToVisible();
      await _reload();
      result = await _rawFetch(url, method: method, body: body);
    }

    if (_isCfBlocked(result)) {
      throw JanitorCfException(result.status);
    }
    if (result.status < 0) {
      throw Exception('WebView fetch failed');
    }
    if (result.status >= 400) {
      throw Exception('HTTP ${result.status}');
    }
    return result.body;
  }

  Future<void> _ensureStarted() {
    if (_controller != null) return Future<void>.value();
    if (_starting != null) return _starting!.future;
    final c = Completer<void>();
    _starting = c;
    _start().then((_) {
      c.complete();
    }).catchError((Object e, StackTrace st) {
      _starting = null;
      c.completeError(e, st);
    });
    return c.future;
  }

  Future<void> _start() async {
    _log('starting headless webview');
    final created = Completer<void>();
    _loadStop = Completer<void>();
    final hv = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: _origin),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        cacheEnabled: true,
        thirdPartyCookiesEnabled: true,
        isInspectable: false,
        useHybridComposition: true,
        // Match the visible login sheet's UA: Edg-stripped but version-aligned
        // with the client hints CF validates. Null on mobile → native UA kept.
        userAgent: janitorWebViewUserAgent,
      ),
      webViewEnvironment: defaultTargetPlatform == TargetPlatform.windows
          ? chatWebViewEnvironment
          : null,
      onWebViewCreated: (controller) async {
        _controller = controller;
        try {
          final ua =
              await controller.evaluateJavascript(source: 'navigator.userAgent');
          if (ua is String && ua.isNotEmpty) {
            CfChallengeService.instance.setWebViewUA(ua);
            _log('UA: $ua');
          }
        } catch (_) {}
        if (!created.isCompleted) created.complete();
      },
      onLoadStop: (controller, url) {
        _log('onLoadStop: $url');
        final c = _loadStop;
        if (c != null && !c.isCompleted) c.complete();
      },
    );
    await hv.run();
    _webView = hv;
    await created.future;
    await _awaitLoad();
    await _waitForClearance();
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    _loadStop = Completer<void>();
    await controller.loadUrl(urlRequest: URLRequest(url: _origin));
    await _awaitLoad();
    await _waitForClearance();
  }

  /// Waits for the in-flight navigation to finish loading (bounded), so JS is
  /// never evaluated against `about:blank`.
  Future<void> _awaitLoad({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final c = _loadStop;
    if (c == null || c.isCompleted) return;
    try {
      await c.future.timeout(timeout);
    } on TimeoutException {
      _log('onLoadStop timeout — proceeding anyway');
    }
  }

  Future<void> _escalateToVisible() async {
    CfChallengeService.instance.invalidate();
    // solve() flips isPending → CatalogGrid mounts the visible _CfChallengeWebView
    // which solves interactively and lands cf_clearance in the shared cookie jar.
    await CfChallengeService.instance.solve();
  }

  /// Polls the shared cookie jar until `cf_clearance` appears for janitorai.com.
  Future<bool> _waitForClearance({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final cookies = await CookieManager.instance().getCookies(url: _origin);
        for (final c in cookies) {
          if (c.name == 'cf_clearance') {
            final value = c.value?.toString() ?? '';
            if (value.isNotEmpty) {
              _log('cf_clearance present');
              return true;
            }
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _log('cf_clearance NOT obtained within timeout');
    return false;
  }

  Future<({int status, String body})> _rawFetch(
    String url, {
    String method = 'GET',
    String? body,
  }) async {
    final controller = _controller;
    if (controller == null) return (status: -1, body: '');
    _log('rawFetch $method → ${url.length > 80 ? url.substring(0, 80) : url}');
    try {
      // Inline the URL / method / body as JSON-escaped JS literals rather than
      // passing them via `arguments` (which has been flaky on Android in this
      // plugin version).
      final res = await controller
          .callAsyncJavaScript(
            functionBody: '''
              $_findTokenJs
              const token = __glazeFindToken();
              const headers = { "Accept": "application/json, text/plain, */*" };
              if (token) headers["authorization"] = "Bearer " + token;
              const opts = {
                method: ${jsonEncode(method)},
                headers: headers,
                credentials: "include",
              };
              ${body == null ? '' : 'headers["Content-Type"] = "application/json"; opts.body = ${jsonEncode(body)};'}
              const r = await fetch(${jsonEncode(url)}, opts);
              const respBody = await r.text();
              return { status: r.status, body: respBody, auth: token ? 1 : 0 };
            ''',
          )
          .timeout(const Duration(seconds: 25));
      if (res == null || res.error != null) {
        _log('rawFetch JS error: ${res?.error}');
        return (status: -1, body: '');
      }
      final value = res.value;
      if (value is Map) {
        final status = (value['status'] as num?)?.toInt() ?? -1;
        final body = value['body']?.toString() ?? '';
        final auth = (value['auth'] as num?)?.toInt() == 1;
        _log('rawFetch ← status=$status bytes=${body.length} auth=$auth');
        return (status: status, body: body);
      }
      _log('rawFetch ← unexpected value type: ${value.runtimeType}');
      return (status: -1, body: '');
    } on TimeoutException {
      _log('rawFetch TIMEOUT (JS call did not return in 25s)');
      return (status: -1, body: '');
    } catch (e) {
      _log('rawFetch exception: $e');
      return (status: -1, body: '');
    }
  }

  bool _isCfBlocked(({int status, String body}) r) {
    if (r.status == 403 || r.status == 503) return true;
    // CF interstitials can also return 200 with the challenge HTML.
    if (r.status == 200 && r.body.contains('Access Restricted')) return true;
    return false;
  }

  /// Tears the offscreen WebView down. Invoked when the catalog is hidden (see
  /// [setActive]); the next [fetch] transparently recreates it.
  Future<void> dispose() async {
    _log('disposing headless webview');
    _shutdownTimer?.cancel();
    _shutdownTimer = null;
    final webView = _webView;
    _webView = null;
    _controller = null;
    _starting = null;
    _loadStop = null;
    try {
      await webView?.dispose();
    } catch (_) {}
  }
}
