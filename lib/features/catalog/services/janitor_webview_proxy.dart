import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../chat/bridge/chat_webview_environment.dart';
import 'cf_challenge_service.dart';
import 'janitor_separate.dart';
import 'janitor_session.dart';

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

    // Every `/generateAlpha` round trip we observe, matched or not. A capture
    // that times out is otherwise indistinguishable between "the request never
    // fired", "it fired and the server refused" and "the body wasn't a prompt";
    // the Dart side reads this log on timeout and reports which one happened.
    window.__glazeAlphaLog = [];
    const noteAlpha = (entry) => {
      try {
        entry.t = Math.round(performance.now());
        window.__glazeAlphaLog.push(entry);
        // Bounded: a long capture must not grow the page's memory unbounded.
        while (window.__glazeAlphaLog.length > 12) window.__glazeAlphaLog.shift();
      } catch (e) {}
    };
    // Records one response body and, when it is the assembled prompt, keeps it.
    const takeAlpha = (via, status, text) => {
      let j = null;
      try { j = JSON.parse(text); } catch (e) {}
      const matched = !!looksLikePayload(j);
      if (matched) window.__glazeAlpha = j;
      noteAlpha({
        via: via,
        status: status,
        matched: matched,
        body: matched ? '' : (text || '').slice(0, 300),
      });
    };
    const isAlphaUrl = (u) =>
      typeof u === 'string' && u.indexOf('/generateAlpha') >= 0;

    // --- fetch hook ---
    const origFetch = window.fetch ? window.fetch.bind(window) : null;
    if (origFetch) {
      window.fetch = async function (...args) {
        let alpha = false;
        try {
          const a0 = args[0];
          alpha = isAlphaUrl((a0 && a0.url) ? a0.url : a0);
        } catch (e) {}
        let res;
        try {
          res = await origFetch(...args);
        } catch (e) {
          // A transport-level failure never reaches the `load` path below, so
          // log it here or the timeout would look like silence.
          if (alpha) noteAlpha({ via: 'fetch', status: 0, matched: false, body: 'network error: ' + e });
          throw e;
        }
        try {
          if (alpha) {
            const status = res.status;
            res.clone().text()
              .then((txt) => takeAlpha('fetch', status, txt))
              .catch((e) => noteAlpha({ via: 'fetch', status: status, matched: false, body: 'unreadable body: ' + e }));
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
                if (isAlphaUrl(this.__glazeUrl)) {
                  takeAlpha('xhr', this.status, this.responseText);
                }
              } catch (e) {}
            });
            this.addEventListener('error', function () {
              try {
                if (isAlphaUrl(this.__glazeUrl)) {
                  noteAlpha({ via: 'xhr', status: this.status || 0, matched: false, body: 'network error' });
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
    // The text currently sitting in the tagged composer ('' when it is gone).
    const composerText = () => {
      const t = document.querySelector('[data-glaze-composer]');
      if (!t) return '';
      return (t.value !== undefined && t.value !== null ? t.value : t.textContent) || '';
    };
    const waitComposerCleared = async (ms) => {
      const until = Date.now() + ms;
      while (Date.now() < until) {
        await new Promise((r) => setTimeout(r, 400));
        if (!composerText().trim()) return true;
      }
      return false;
    };
    // A compact snapshot of the composer area for the error message: which text
    // boxes exist, which one we drove, and what buttons sit next to it. Enough
    // to tell "an overlay is up" from "we typed into the wrong box".
    const describeComposer = () => {
      try {
        const areas = [];
        const nodes = document.querySelectorAll('textarea, div[contenteditable="true"]');
        for (let i = 0; i < nodes.length && i < 6; i++) {
          const t = nodes[i];
          areas.push({
            ph: (t.placeholder || '').slice(0, 20),
            shown: t.offsetParent !== null,
            chosen: t.hasAttribute('data-glaze-composer'),
            value: ((t.value !== undefined && t.value !== null ? t.value : t.textContent) || '').slice(0, 12),
            disabled: !!t.disabled,
          });
        }
        const btns = [];
        const all = document.querySelectorAll('button');
        for (let i = 0; i < all.length && btns.length < 8; i++) {
          const b = all[i];
          if (b.offsetParent === null) continue;
          btns.push({
            label: ((b.getAttribute('aria-label') || b.textContent || '').trim()).slice(0, 20),
            disabled: !!b.disabled,
          });
        }
        return JSON.stringify({ overlay: !!findOverlay(), areas: areas, buttons: btns });
      } catch (e) {
        return 'unreadable';
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
      // 2) Type the message into the now-idle composer. Tag it so the
      //    "did it actually send?" check below reads THIS box and not whichever
      //    hidden textarea (character notes, drawers) comes first in the DOM.
      const stale = document.querySelectorAll('[data-glaze-composer]');
      for (let i = 0; i < stale.length; i++) {
        stale[i].removeAttribute('data-glaze-composer');
      }
      el.setAttribute('data-glaze-composer', '1');
      el.focus();
      setReactValue(el, text);
      // 3) Poll for the enabled send button (it enables a few frames after React
      //    ingests the value) and click it. A new overlay may have slipped in
      //    between the dismiss above and now (JanitorAI pops the persona picker
      //    on the first send of a fresh chat), so clear it once more first.
      await dismissModals();
      let btn = null;
      // Generous: on a slow phone React can take many seconds to enable the
      // button after it ingests the value, and giving up early loses the run.
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 200));
        btn = findSendButton(el);
        if (btn) break;
      }
      // 4) Send, then VERIFY. The composer clears on a real send, so text still
      //    sitting in it means the send was swallowed — a modal that reopened, a
      //    disabled composer, or a click React never saw. Without this check a
      //    swallowed send is indistinguishable from a model that never answered:
      //    the Dart side just waits out its whole timeout.
      let how;
      if (btn) { btn.click(); how = 'click'; } else { pressEnter(el); how = 'enter'; }
      let cleared = await waitComposerCleared(3000);
      if (!cleared && btn) {
        // The click didn't take. Some layouts only send on Enter; and a fresh
        // overlay may have eaten the click, so clear it and try the key path.
        await dismissModals(2000);
        pressEnter(el);
        how += '+enter';
        cleared = await waitComposerCleared(3000);
      }
      return { ok: true, sent: how, cleared: cleared, diag: cleared ? '' : describeComposer() };
    };
    // Whether the chat composer has hydrated (React mounted a visible input).
    // The Dart side POLLS this instead of sleeping a fixed interval: how long
    // hydration takes depends on the device and the network, so any constant is
    // either too short on a slow phone or wasted time on a fast one.
    window.__glazeComposerReady = () => !!findInput();
  })();
''';

/// Everything one capture run recovers: the assembled `generateAlpha` [payload]
/// plus the material that only exists around it.
///
/// [greetings] come from the chat object JanitorAI creates for the capture
/// (`GET /hampter/chats/{id}` → `character.first_messages`), which carries the
/// greetings verbatim even when the character endpoint withholds them — the same
/// source SillyTavern-CharacterLibrary reads. Index 0 is the primary greeting,
/// the rest are alternates.
///
/// [bakedUserName] is set only when the throwaway `{{user}}` persona could NOT be
/// created: JanitorAI then substitutes the account's own persona/display name
/// into the prompt, and the caller swaps that name back to the macro. It is null
/// on the normal path, where the persona makes the substitution a no-op.
class JanitorCaptureResult {
  final Map<String, dynamic> payload;

  /// The assembled prompt from the capture's FIRST send (a bare `"."`), kept as
  /// the "before the trigger fired" snapshot the field diff subtracts from
  /// [payload] — see `janitor_field_diff.dart`. Null when the second send never
  /// produced a payload of its own, in which case [payload] IS the probe and
  /// diffing it against itself would say nothing.
  final Map<String, dynamic>? probePayload;

  final List<String> greetings;
  final String? bakedUserName;

  const JanitorCaptureResult({
    required this.payload,
    this.probePayload,
    this.greetings = const [],
    this.bakedUserName,
  });
}

/// Thrown when the proxy could not obtain a CF-cleared response.
class JanitorCfException implements Exception {
  final int status;
  JanitorCfException(this.status);
  @override
  String toString() => 'JanitorCfException(status=$status)';
}

/// Thrown when janitorai.com rejected the session itself (HTTP 401).
///
/// The account cookie/JWT the offscreen WebView holds went stale — the user is
/// still "logged in" as far as Glaze knows, but every account call now fails.
/// Only a fresh login fixes it, so the UI asks for one instead of reporting a
/// generic HTTP error.
class JanitorAuthException implements Exception {
  const JanitorAuthException();

  @override
  String toString() => 'Janitor.AI session expired (401)';
}

/// Thrown when JanitorAI itself refused to assemble the prompt: `/generateAlpha`
/// answered with an HTTP error instead of a payload.
///
/// The common case is [isProxyForbidden] — the creator restricted the character
/// to JanitorAI's own model, so the proxy preset the capture installs is
/// rejected and no closed card or lorebook can ever be recovered for it. That is
/// a permanent property of the character, not a transient failure, so the UI
/// says so up front instead of offering a retry.
class JanitorRefusedException implements Exception {
  /// HTTP status of the refused `/generateAlpha` response (0 = transport error).
  final int status;

  /// The server's own wording, e.g. `Proxies are forbidden for this character`.
  final String message;

  const JanitorRefusedException(this.status, this.message);

  /// The refusal a character with `allow_proxy: false` is going to produce,
  /// built from its catalog metadata before any capture runs. The wording is
  /// JanitorAI's own, so it reads identically whether it was predicted here or
  /// read off a real 403.
  const JanitorRefusedException.proxyForbidden()
      : status = 403,
        message = 'Proxies are forbidden for this character';

  bool get isProxyForbidden => message.toLowerCase().contains('prox');

  @override
  String toString() => message.isEmpty ? 'generateAlpha failed ($status)' : message;
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
  /// Pipeline (serialized through [_gate]): ensure a persona named `{{user}}`,
  /// create a fresh chat bound to it, navigate the offscreen WebView to it with
  /// [_captureUserScript] installed, send `"."` to surface the card, then re-send
  /// the card text (+ optional [triggerText], e.g. the catalog description) to
  /// maximise lorebook keyword matches, and return the captured payload. Pass
  /// `includeCard: false` to leave the recovered card out of that second send —
  /// the user deselected it as a trigger source. The chat, the
  /// persona and the throwaway proxy preset are all removed afterwards, and the
  /// account's API settings are restored. Throws on timeout / login / CF failure.
  ///
  /// The run is serialized on purpose: it mutates shared account state (selected
  /// proxy preset, generation settings, persona), so two captures overlapping
  /// would restore each other's snapshots and leave the account misconfigured.
  Future<JanitorCaptureResult> captureGenerateAlpha({
    required String characterId,
    String triggerText = '',
    bool includeCard = true,
    void Function(String phase)? onPhase,
  }) {
    final completer = Completer<JanitorCaptureResult>();
    _gate = _gate.then((_) async {
      try {
        completer.complete(await _captureLocked(
            characterId, triggerText, includeCard, onPhase));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<JanitorCaptureResult> _captureLocked(
    String characterId,
    String triggerText,
    bool includeCard,
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
    // The capture spends the session across a dozen account calls and cannot
    // retry from the middle, so it starts on a token that is known good.
    await _refreshSession();

    // Force the account into proxy mode against an unreachable dummy preset (and
    // context_length 0) so the captured `/generateAlpha` prompt keeps its
    // wrappers and isn't truncated/reordered. Restored in the finally below.
    // Without this, an account on JLLM ("janitor") never assembles a proxy
    // prompt — the send just runs on Janitor's own model.
    phase('configuring proxy');
    final apiSettingsSnapshot = await _enterExtractionMode();
    String? chatId;
    String? personaId;
    String? bakedUserName;
    Map<String, dynamic>? profileNameSnapshot;
    try {
      // 1) Close the first-chat profile gate. An account whose profile has no
      //    name gets the "set up your profile" modal instead of a reply on its
      //    first chat, and that modal eats the message we send. The gate is on
      //    the profile name, so seeding one stops it appearing; the original is
      //    put back in the finally. Same fix SillyTavern-CharacterLibrary uses —
      //    prevention rather than dismissing a mandatory modal that comes back.
      phase('checking profile');
      final seeded = await _seedProfileName();
      profileNameSnapshot = seeded.snapshot;

      // 2) Ensure a persona literally named `{{user}}`. JanitorAI substitutes the
      //    ACTIVE persona's name into the assembled prompt, so a persona with
      //    that name makes the substitution a no-op and the macro survives in the
      //    captured card / lorebook entries. When the persona can't be created we
      //    remember the name that WILL be baked in, so the caller can swap it back.
      phase('preparing persona');
      personaId = await _ensureUserMacroPersona();
      // The seeded sentinel is swapped back unconditionally: it is a random hex
      // run that can never occur in genuine card text, and JanitorAI may bake the
      // profile name in even with a persona bound. Without a seed, only the
      // persona-less path needs the account's own name swapped.
      bakedUserName = seeded.sentinel ??
          (personaId == null ? await _activePersonaName() : null);
      if (personaId == null) {
        _log('no {{user}} persona — baked name fallback: '
            '${bakedUserName ?? 'unknown'}');
      }

      // 3) Create a fresh chat for this character, bound to that persona.
      phase('creating chat');
      final chatBody = await _fetchLocked(
        'https://janitorai.com/hampter/chats',
        method: 'POST',
        body: jsonEncode({
          'character_id': characterId,
          'persona_id': ?personaId,
        }),
      );
      final chatJson = jsonDecode(chatBody);
      chatId = (chatJson is Map ? chatJson['id'] : null)?.toString();
      if (chatId == null || chatId.isEmpty) {
        throw Exception('Could not create chat (no id in response).');
      }

      // 4) The chat's embedded character carries the greetings verbatim even when
      //    the character endpoint withholds them for a closed card, so read them
      //    here rather than reconstructing them from the prompt.
      final greetings = await _fetchChatGreetings(chatId);

      final controller = _controller;
      if (controller == null) throw Exception('WebView not available.');

      // 5) Install the capture hook at document start, then open the chat.
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

        // Wait for the React chat app to actually mount its composer instead of
        // sleeping a constant: hydration takes as long as the device and the
        // network make it take.
        phase('waiting for chat UI');
        if (!await _waitForComposer(const Duration(seconds: 60))) {
          _log('composer never appeared — sending anyway');
        }

        // 6) Send "." → capture the card.
        phase('triggering (card)');
        final dot = await _captureOneSend('.', const Duration(seconds: 60));
        // A refusal applies to the character, not to this particular message —
        // the second send would be refused identically, so stop here.
        if (dot.refusal != null) throw _refusalError(characterId, dot.refusal!);
        final card = dot.payload != null ? extractCard(dot.payload!) : '';

        // 7) Send card (+ the selected context) → maximise lorebook triggers.
        final parts = <String>[
          if (includeCard && card.isNotEmpty) card,
          if (triggerText.trim().isNotEmpty) triggerText.trim(),
        ];
        final trigger = parts.isEmpty ? '.' : parts.join('\n\n');
        phase('triggering (lorebook)');
        await _resetCapture();
        final full =
            await _captureOneSend(trigger, const Duration(seconds: 120));
        final result = full.payload ?? dot.payload;
        if (result == null) {
          final refusal = full.refusal ?? dot.refusal;
          if (refusal != null) throw _refusalError(characterId, refusal);
          // Prefer the concrete reason the send failed over a bare timeout.
          throw Exception(full.problem ??
              dot.problem ??
              'Timed out waiting for a generateAlpha capture.');
        }
        phase('captured');
        return JanitorCaptureResult(
          payload: result,
          // Only a real second capture leaves a usable BEFORE snapshot: when the
          // trigger send produced nothing we fell back to the probe's own
          // payload above, and it cannot be both sides of the diff.
          probePayload: full.payload != null ? dot.payload : null,
          greetings: greetings,
          bakedUserName: bakedUserName,
        );
      } finally {
        try {
          await controller.removeAllUserScripts();
        } catch (_) {}
      }
    } finally {
      // Clean up everything the capture created, in dependency order: the chat
      // references the persona, the persona outlives neither. Each step is
      // best-effort — a failure here must not mask the capture's own result.
      if (chatId != null) {
        phase('deleting chat');
        await _deleteChat(chatId);
      }
      if (personaId != null) {
        await _deletePersona(personaId);
      }
      if (profileNameSnapshot != null) {
        await _restoreProfileName(profileNameSnapshot);
      }
      if (apiSettingsSnapshot != null) {
        phase('restoring settings');
        await _restoreProfile(apiSettingsSnapshot);
      }
    }
  }

  /// Polls the injected `__glazeComposerReady()` until the chat composer exists
  /// or [timeout] elapses. Returns whether it appeared.
  Future<bool> _waitForComposer(Duration timeout) async {
    final controller = _controller;
    if (controller == null) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res = await controller.evaluateJavascript(
          source: 'window.__glazeComposerReady ? '
              '!!window.__glazeComposerReady() : false',
        );
        if (res == true) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  /// Deletes the chat created for a capture. It exists only so JanitorAI would
  /// assemble the prompt; leaving it behind adds one dead entry to the account's
  /// chat list per extraction.
  Future<void> _deleteChat(String chatId) async {
    try {
      await _fetchLocked(
        'https://janitorai.com/hampter/chats/$chatId',
        method: 'DELETE',
      );
      _log('deleted capture chat $chatId');
    } catch (e) {
      _log('chat delete failed: $e');
    }
  }

  static const String _personasUrl = 'https://janitorai.com/hampter/personas';
  static const String _profileUrl =
      'https://janitorai.com/hampter/profiles/mine';

  /// The macro we want left untouched in the captured prompt. JanitorAI
  /// substitutes a persona's `name` verbatim, so a persona named exactly this
  /// turns the substitution into `{{user}}` -> `{{user}}`.
  static const String _userMacroName = '{{user}}';

  /// Finds (or creates) a persona literally named `{{user}}` and returns its id.
  /// Idempotent — a leftover persona from an interrupted run is reused instead of
  /// piling up duplicates. Returns null when the account's personas can neither
  /// be listed nor created; the capture then falls back to swapping the baked
  /// name back to the macro (see [JanitorCaptureResult.bakedUserName]).
  Future<String?> _ensureUserMacroPersona() async {
    try {
      final body = await _fetchLocked(_personasUrl);
      final parsed = jsonDecode(body);
      final list = parsed is List
          ? parsed
          : (parsed is Map && parsed['personas'] is List)
              ? parsed['personas'] as List
              : (parsed is Map && parsed['data'] is List)
                  ? parsed['data'] as List
                  : const <dynamic>[];
      for (final p in list) {
        if (p is Map && p['name'] == _userMacroName && p['id'] != null) {
          _log('reusing {{user}} persona ${p['id']}');
          return p['id'].toString();
        }
      }
    } catch (e) {
      // A failed list is not fatal — fall through and try to create one.
      _log('could not list personas: $e');
    }
    try {
      // Body mirrors the JanitorAI web client's POST exactly (empty
      // appearance/avatar, null group/pronouns) so the server accepts it.
      final body = await _fetchLocked(
        _personasUrl,
        method: 'POST',
        body: jsonEncode({
          'appearance': '',
          'avatar': '',
          'groupId': null,
          'name': _userMacroName,
          'pronouns': null,
        }),
      );
      final parsed = jsonDecode(body);
      final id = (parsed is Map ? (parsed['id'] ?? parsed['data']?['id']) : null)
          ?.toString();
      if (id != null && id.isNotEmpty) {
        _log('created {{user}} persona $id');
        return id;
      }
    } catch (e) {
      _log('could not create {{user}} persona: $e');
    }
    return null;
  }

  /// Deletes the throwaway `{{user}}` persona. Best-effort.
  Future<void> _deletePersona(String personaId) async {
    try {
      await _fetchLocked('$_personasUrl/$personaId', method: 'DELETE');
      _log('deleted persona $personaId');
    } catch (e) {
      _log('persona delete failed: $e');
    }
  }

  /// Seeds the account's profile name when it is empty, so the first-chat
  /// profile modal never opens and swallows the message we are about to send.
  ///
  /// Returns the [snapshot] to hand [_restoreProfileName] (null when nothing was
  /// changed) and the [sentinel] that is now standing in for the user's name —
  /// a random hex run, so swapping it back to `{{user}}` afterwards can never
  /// hit genuine card text.
  Future<({Map<String, dynamic>? snapshot, String? sentinel})>
      _seedProfileName() async {
    try {
      final body = await _fetchLocked(_profileUrl);
      final parsed = jsonDecode(body);
      if (parsed is! Map) return (snapshot: null, sentinel: null);
      final priorName = (parsed['name'] is String) ? parsed['name'] as String : '';
      final priorAppearance =
          (parsed['profile'] is String) ? parsed['profile'] as String : '';
      if (priorName.trim().isNotEmpty) return (snapshot: null, sentinel: null);

      final sentinel = _randomString(24).toUpperCase();
      await _fetchLocked(
        _profileUrl,
        method: 'PATCH',
        body: jsonEncode({'name': sentinel, 'profile': priorAppearance}),
      );
      _log('seeded an empty profile name (first-chat modal gate)');
      return (
        snapshot: {'name': priorName, 'profile': priorAppearance},
        sentinel: sentinel,
      );
    } catch (e) {
      // Non-fatal: the modal may not appear at all, and the send has its own
      // overlay dismissal as a second line of defence.
      _log('profile name seed failed: $e');
      return (snapshot: null, sentinel: null);
    }
  }

  /// Puts the profile name back the way [_seedProfileName] found it.
  Future<void> _restoreProfileName(Map<String, dynamic> snapshot) async {
    try {
      await _fetchLocked(
        _profileUrl,
        method: 'PATCH',
        body: jsonEncode(snapshot),
      );
      _log('restored profile name');
    } catch (e) {
      _log('profile name restore failed: $e');
    }
  }

  /// The name JanitorAI will bake into `{{user}}` when no persona of ours is
  /// bound to the chat — the account's own persona/display name. Null when it
  /// can't be read.
  Future<String?> _activePersonaName() async {
    try {
      final body = await _fetchLocked(_profileUrl);
      final parsed = jsonDecode(body);
      if (parsed is Map) {
        for (final key in const ['name', 'user_name']) {
          final v = parsed[key];
          if (v is String && v.trim().isNotEmpty) return v.trim();
        }
      }
    } catch (e) {
      _log('could not read profile name: $e');
    }
    return null;
  }

  /// Greetings from the chat's embedded character (`first_message` +
  /// `first_messages`). A closed card withholds these from
  /// `/hampter/characters/{id}`, but the chat object still carries them.
  /// Index 0 is the primary greeting. Empty on any failure.
  Future<List<String>> _fetchChatGreetings(String chatId) async {
    try {
      final body =
          await _fetchLocked('https://janitorai.com/hampter/chats/$chatId');
      final parsed = jsonDecode(body);
      if (parsed is! Map) return const [];
      final nested = parsed['data'];
      final character = parsed['character'] ??
          (nested is Map ? nested['character'] : null);
      if (character is! Map) return const [];

      final out = <String>[];
      void add(dynamic g) {
        final text = g is String
            ? g
            : (g is Map ? (g['first_message'] ?? g['message'] ?? '') : '')
                .toString();
        final trimmed = text.trim();
        // JanitorAI pads the array with nulls and invisible-character
        // placeholders that would import as blank greetings.
        if (trimmed.isEmpty) return;
        if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(trimmed)) return;
        if (out.contains(trimmed)) return;
        out.add(trimmed);
      }

      add(character['first_message']);
      final list = character['first_messages'];
      if (list is List) list.forEach(add);
      _log('chat greetings: ${out.length}');
      return out;
    } catch (e) {
      _log('chat greetings fetch failed: $e');
      return const [];
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
      // An account with no proxy presets of its own was on JLLM before we
      // touched it: there is no previous selection to put back, so the restore
      // must explicitly return it to JLLM instead of leaving our (deleted)
      // dummy selected in proxy mode.
      final hadOwnPresets = (before is Map && before['proxy_configs'] is List)
          ? (before['proxy_configs'] as List).isNotEmpty
          : false;

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
        'hadOwnPresets': hadOwnPresets,
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
  ///
  /// Two cases the naive "put back what was there" misses, and both leave the
  /// account broken for the user's own chats:
  ///  * the account had **no proxy presets** — there is nothing to re-select, so
  ///    it goes back to JLLM (`source: janitor`, no selected preset) rather than
  ///    staying in proxy mode pointed at the preset we are about to delete;
  ///  * the account had **no readable generation settings** — we still forced
  ///    `context_length: 0` on it, so a skipped restore would leave every real
  ///    chat with a zero context. A sane default goes back instead.
  static const int _defaultContextLength = 4096;

  Future<void> _restoreProfile(Map<String, dynamic> snapshot) async {
    final hadOwnPresets = snapshot['hadOwnPresets'] == true;
    final originalGen = snapshot['generationSettings'];

    final patch = <String, dynamic>{
      'selected_proxy_config_id':
          hadOwnPresets ? snapshot['selectedProxyConfigId'] : null,
    };
    if (!hadOwnPresets) {
      patch['source'] = 'janitor'; // JLLM
    } else if (snapshot['source'] != null) {
      patch['source'] = snapshot['source'];
    }

    if (originalGen is Map && originalGen['context_length'] is num) {
      patch['generation_settings'] = originalGen;
    } else {
      patch['generation_settings'] = {
        ...?(originalGen is Map ? Map<String, dynamic>.from(originalGen) : null),
        'context_length': _defaultContextLength,
      };
      _log('no original context_length — restoring the '
          '$_defaultContextLength default');
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

  /// Clears the last captured payload — and the `/generateAlpha` log that
  /// explains a timeout — so the next send's capture is unambiguous.
  Future<void> _resetCapture() async {
    try {
      await _controller?.evaluateJavascript(
        source: 'window.__glazeAlpha = null; window.__glazeAlphaLog = [];',
      );
    } catch (_) {}
  }

  /// Characters JanitorAI has already refused to assemble a prompt for, by
  /// character id. A refusal is a property of the card (its creator disabled
  /// proxies), so it holds for the whole session: the UI checks this before
  /// starting a capture that is guaranteed to fail, and explains instead.
  final Map<String, JanitorRefusedException> _refusals = {};

  /// The refusal already recorded for [characterId], if any.
  JanitorRefusedException? refusalFor(String characterId) =>
      _refusals[characterId];

  /// The error to throw for [refusal], remembering it against [characterId]
  /// when it is a property of the character.
  ///
  /// A 401 is not: the session went stale mid-capture, and it would be wrong to
  /// mark the character as unextractable — after a fresh login it works. Those
  /// become a [JanitorAuthException] and are never cached.
  Object _refusalError(String characterId, JanitorRefusedException refusal) {
    if (refusal.status == 401) return const JanitorAuthException();
    _refusals[characterId] = refusal;
    return refusal;
  }

  /// Reads the injected `/generateAlpha` log.
  Future<List<dynamic>> _readAlphaLog() async {
    try {
      final res = await _controller?.evaluateJavascript(
        source: 'JSON.stringify(window.__glazeAlphaLog || [])',
      );
      if (res is String && res.isNotEmpty && res != 'null') {
        final decoded = jsonDecode(res);
        if (decoded is List) return decoded;
      }
    } catch (_) {}
    return const [];
  }

  /// The refusal in [log], if JanitorAI answered `/generateAlpha` with an HTTP
  /// error. Reads the server's own wording out of the JSON body (`message` /
  /// `error` / `detail`) so the UI can quote it verbatim; falls back to the raw
  /// body when it isn't JSON. Returns null while every entry is a 2xx — those
  /// are "the body wasn't a prompt", which is a different problem.
  JanitorRefusedException? _refusalIn(List<dynamic> log) {
    for (final entry in log.reversed) {
      if (entry is! Map) continue;
      if (entry['matched'] == true) continue;
      final status = (entry['status'] as num?)?.toInt() ?? 0;
      if (status > 0 && status < 400) continue;
      final body = (entry['body'] ?? '').toString();
      String message = '';
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          for (final key in const ['message', 'error', 'detail']) {
            final v = decoded[key];
            if (v is String && v.trim().isNotEmpty) {
              message = v.trim();
              break;
            }
          }
        }
      } catch (_) {}
      if (message.isEmpty) {
        message = body.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
      return JanitorRefusedException(status, message);
    }
    return null;
  }

  /// Turns the log into one sentence a user can act on. Called only when a send
  /// produced no payload: the three failures that look identical from the
  /// outside — the request never fired, it fired and the server refused, it
  /// returned something that is not an assembled prompt — are told apart here.
  Future<String> _describeAlphaTimeout() async {
    final log = await _readAlphaLog();
    if (log.isEmpty) {
      return 'No /generateAlpha request left the page — the message was sent '
          'but JanitorAI never asked the server to assemble a prompt '
          '(generation refused, or the chat is still busy).';
    }
    // Newest first: the last attempt is the one that should have produced the
    // payload. Two is enough context without dumping a wall of HTML.
    final parts = <String>[];
    for (final entry in log.reversed.take(2)) {
      if (entry is! Map) continue;
      final status = entry['status'];
      final matched = entry['matched'] == true;
      final body = (entry['body'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ');
      parts.add(matched
          ? '$status returned a prompt that arrived too late'
          : '$status: ${body.isEmpty ? 'empty body' : body}');
    }
    return 'JanitorAI answered /generateAlpha with ${parts.join(' | ')}';
  }

  /// Drives one `__glazeSend(text)` and polls `window.__glazeAlpha` until a
  /// payload appears, JanitorAI refuses, or [timeout] elapses.
  ///
  /// [problem] describes a send that visibly did not leave the composer (an
  /// overlay swallowed the click, the box stayed disabled, React ignored the
  /// synthetic key). The poll still runs its full course afterwards — the check
  /// is a heuristic and a send can succeed with text left behind — but when
  /// nothing arrives the caller can say what actually went wrong instead of
  /// reporting a bare timeout.
  ///
  /// [refusal] is set when `/generateAlpha` came back with an HTTP error. That
  /// is a final answer, so the poll stops there rather than sitting out the rest
  /// of its timeout waiting for a payload that will never arrive.
  Future<
      ({
        Map<String, dynamic>? payload,
        String? problem,
        JanitorRefusedException? refusal,
      })> _captureOneSend(
    String text,
    Duration timeout,
  ) async {
    final controller = _controller;
    if (controller == null) {
      return (
        payload: null,
        problem: 'WebView not available.',
        refusal: null,
      );
    }

    String? problem;
    try {
      final res = await controller.callAsyncJavaScript(
        functionBody: 'return await window.__glazeSend(${jsonEncode(text)});',
      );
      final value = res?.value;
      if (res?.error != null) {
        problem = 'The send script failed: ${res!.error}';
      } else if (value is Map) {
        if (value['ok'] != true) {
          problem = 'Could not reach the chat composer '
              '(${value['reason'] ?? 'unknown'}).';
        } else if (value['cleared'] == false) {
          problem = 'The message would not send — it stayed in the composer '
              '(${value['diag'] ?? 'no detail'}).';
        }
        _log('send sent=${value['sent']} cleared=${value['cleared']}');
      }
    } catch (e) {
      problem = 'Send failed: $e';
    }
    if (problem != null) _log(problem);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      try {
        final res = await controller.evaluateJavascript(
          source: 'window.__glazeAlpha ? JSON.stringify(window.__glazeAlpha) : null',
        );
        if (res is String && res.isNotEmpty && res != 'null') {
          final decoded = jsonDecode(res);
          if (decoded is Map<String, dynamic>) {
            return (payload: decoded, problem: null, refusal: null);
          }
          if (decoded is Map) {
            return (
              payload: Map<String, dynamic>.from(decoded),
              problem: null,
              refusal: null,
            );
          }
        }
      } catch (_) {}
      // An HTTP error on /generateAlpha is JanitorAI's final answer (the
      // character forbids proxies, the account is rate-limited…). Waiting out
      // the remaining minute cannot change it, so stop as soon as one lands.
      final refusal = _refusalIn(await _readAlphaLog());
      if (refusal != null) {
        _log('generateAlpha refused: ${refusal.status} ${refusal.message}');
        return (payload: null, problem: refusal.message, refusal: refusal);
      }
    }
    // Nothing arrived. Say why, keeping any earlier send-side problem in front
    // of it — a swallowed send explains the silence that follows.
    final diag = await _describeAlphaTimeout();
    _log(diag);
    return (
      payload: null,
      problem: problem == null ? diag : '$problem $diag',
      refusal: null,
    );
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

  /// The account access token as the page currently sees it, or null when the
  /// page holds no session at all.
  Future<String?> _readAccessToken() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final res = await controller
          .callAsyncJavaScript(
            functionBody: '$_findTokenJs return __glazeFindToken();',
          )
          .timeout(const Duration(seconds: 10));
      final value = res?.value;
      return (value is String && value.isNotEmpty) ? value : null;
    } catch (e) {
      _log('readAccessToken error: $e');
      return null;
    }
  }

  /// Gives the page a chance to mint a fresh access token before one is spent.
  ///
  /// The stored session carries a short-lived JWT next to a long-lived refresh
  /// token, and only JanitorAI's own Supabase client trades one for the other —
  /// on page load. Opening the app the day after a login therefore starts with
  /// an expired JWT that 401s every authenticated call, which the UI can only
  /// report as "session expired, log in again" even though the session is fine.
  /// Reloading the page and waiting for the refresh to land recovers it without
  /// touching the user.
  ///
  /// [force] reloads even when the token still looks valid — the answer to a
  /// 401 that came back anyway (a rotated or server-side revoked token).
  /// Returns true when a usable token is in place afterwards.
  Future<bool> _refreshSession({bool force = false}) async {
    final token = await _readAccessToken();
    if (token == null) return false;
    if (!force && !isJanitorTokenExpired(token)) return true;
    _log('access token stale (force=$force) — reloading to refresh it');
    await _reload();
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      final fresh = await _readAccessToken();
      if (fresh != null && !isJanitorTokenExpired(fresh)) {
        _log('session refreshed in-page');
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _log('session still stale after reload — the refresh token is gone too');
    return false;
  }

  /// Commits the WebView cookie jar to disk.
  ///
  /// Android keeps cookies in memory and writes them out on its own schedule,
  /// so a login followed by a quick app kill is simply lost. The plugin exposes
  /// no flush of its own, but every cookie write it performs flushes the whole
  /// store — hence the throwaway cookie on an origin that is never requested.
  static Future<void> flushCookies() async {
    try {
      final url = WebUri('https://glaze-cookie-flush.invalid/');
      await CookieManager.instance().setCookie(
        url: url,
        name: 'gz_flush',
        value: '1',
        path: '/',
      );
      await CookieManager.instance().deleteCookie(url: url, name: 'gz_flush');
    } catch (e) {
      _log('cookie flush error: $e');
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
    // 401 is the session, not the request: the capture creates a persona, a
    // chat and a proxy preset on the account, and all of them start failing at
    // once when the JWT goes stale. A stale JWT is recoverable, though — the
    // refresh token beside it outlives it by weeks — so reload the page for a
    // fresh one and try again before telling the user to log in.
    if (result.status == 401) {
      _log('401 — refreshing the session and retrying once');
      if (await _refreshSession(force: true)) {
        result = await _rawFetch(url, method: method, body: body);
      }
    }
    // Refused again, and the session could not be saved — the refresh token
    // beside the JWT is gone too. Browsing needs no account, so a public read
    // is asked once more with the dead token left off instead of being
    // reported as "log in again": that sentence names a fix that does not
    // apply, and the feed and the search box both stopped there. The stored
    // session is deliberately left alone; a JWT the server would not take is
    // not evidence that the login is finished.
    if (result.status == 401 && janitorReadIsPublic(url, method: method)) {
      _log('401 persists — retrying the read without the account token');
      result = await _rawFetch(url, method: method, anonymous: true);
    }
    if (result.status == 401) {
      throw const JanitorAuthException();
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
    // A session stored before the app was last closed usually comes back with
    // an expired access token; catch it here, once per proxy lifetime, rather
    // than on the first authenticated call.
    await _refreshSession();
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
    bool anonymous = false,
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
              const token = ${anonymous ? 'null' : '__glazeFindToken()'};
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
