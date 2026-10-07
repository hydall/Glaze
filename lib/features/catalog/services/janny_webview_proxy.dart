import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../chat/bridge/chat_webview_environment.dart';

void _log(String m) => debugPrint('[Janny-proxy] $m');

/// Thrown when jannyai.com kept answering with a Cloudflare challenge even
/// from inside the WebView.
class JannyCfException implements Exception {
  final int status;
  const JannyCfException(this.status);

  @override
  String toString() => 'catalog_error_janny_cloudflare'.tr();
}

/// Offscreen WebView that loads jannyai.com pages from inside a real Chromium
/// session — the Janny counterpart of `JanitorWebViewProxy`.
///
/// jannyai.com sits behind a Cloudflare managed challenge: Dio gets
/// `403 cf-mitigated: challenge` no matter which User-Agent it sends, because
/// `cf_clearance` is bound to the TLS fingerprint of the client that solved the
/// challenge. A WebView solves the managed challenge on its own just by loading
/// the page, and a `fetch()` run inside that page keeps the same fingerprint and
/// cookie jar, so it passes.
///
/// Only the HTML on jannyai.com needs this. The Meilisearch API at
/// search.jannyai.com and the image CDN are not challenged and stay on Dio.
///
/// No account is involved, so unlike the Janitor proxy there is no session
/// handling: the WebView is booted on demand and torn down after [_idleTtl]
/// without requests, which keeps several card previews in a row on one
/// solved challenge.
class JannyWebViewProxy {
  JannyWebViewProxy._();
  static final JannyWebViewProxy instance = JannyWebViewProxy._();

  static final WebUri _origin = WebUri('https://jannyai.com/');
  static const Duration _idleTtl = Duration(seconds: 60);

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Completer<void>? _starting;
  Completer<void>? _loadStop;

  /// Serializes requests so a reload triggered by one can't race another.
  Future<void> _gate = Future<void>.value();
  int _pending = 0;
  Timer? _idleTimer;

  /// GETs [url] (a jannyai.com URL) from inside the WebView and returns the
  /// body. Throws [JannyCfException] when Cloudflare can't be cleared, or an
  /// [Exception] carrying the status on any other HTTP error.
  Future<String> fetchText(String url) => _enqueue(() => _fetchLocked(url));

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _pending++;
    _idleTimer?.cancel();
    _idleTimer = null;
    _gate = _gate.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _pending--;
        _scheduleIdleShutdown();
      }
    });
    return completer.future;
  }

  void _scheduleIdleShutdown() {
    if (_pending > 0) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTtl, () {
      if (_pending == 0) dispose();
    });
  }

  Future<String> _fetchLocked(String url) async {
    await _ensureStarted();

    var result = await _rawFetch(url);
    // The clearance expired or was never issued: reloading the origin re-runs
    // the managed challenge, which the WebView solves without user input.
    if (result.challenged) {
      _log('CF challenge on fetch — reloading session');
      await _reload();
      result = await _rawFetch(url);
    }
    if (result.challenged) throw JannyCfException(result.status);
    if (result.status < 0) throw Exception('WebView fetch failed');
    if (result.status >= 400) throw Exception('HTTP ${result.status}');
    return result.body;
  }

  Future<void> _ensureStarted() {
    if (_controller != null) return Future<void>.value();
    if (_starting != null) return _starting!.future;
    final c = Completer<void>();
    _starting = c;
    _start().then((_) => c.complete()).catchError((Object e, StackTrace st) {
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
        // Same UA as the Janitor WebViews: version-aligned with the client
        // hints CF validates. Null on mobile → native UA kept.
        userAgent: janitorWebViewUserAgent,
      ),
      webViewEnvironment: defaultTargetPlatform == TargetPlatform.windows
          ? chatWebViewEnvironment
          : null,
      onWebViewCreated: (controller) {
        _controller = controller;
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
    await _waitForPage();
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    _loadStop = Completer<void>();
    await controller.loadUrl(urlRequest: URLRequest(url: _origin));
    await _awaitLoad();
    await _waitForPage();
  }

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

  /// Waits until the WebView sits on the real site rather than the challenge
  /// interstitial.
  ///
  /// `onLoadStop` fires for the "Just a moment…" page too, and a fetch issued
  /// from it would be challenged again. The interstitial defines
  /// `window._cf_chl_opt`; once the challenge is solved CF navigates to the
  /// real page, which doesn't. Polling for that, rather than for the
  /// `cf_clearance` cookie, also returns at once when CF doesn't challenge
  /// this client at all and no cookie is ever issued.
  Future<bool> _waitForPage({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final res = await _controller?.evaluateJavascript(
          source: 'document.readyState === "complete" && '
              '!window._cf_chl_opt && location.hostname === "jannyai.com"',
        );
        if (res == true) {
          _log('page ready');
          return true;
        }
      } catch (_) {
        // Mid-navigation; the next poll lands on the new document.
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _log('challenge not cleared within timeout');
    return false;
  }

  Future<({int status, String body, bool challenged})> _rawFetch(
    String url,
  ) async {
    const failed = (status: -1, body: '', challenged: false);
    final controller = _controller;
    if (controller == null) return failed;
    _log('rawFetch → ${url.length > 80 ? url.substring(0, 80) : url}');
    try {
      // URL inlined as a JSON literal rather than passed through `arguments`,
      // which has been flaky on Android in this plugin version.
      final res = await controller
          .callAsyncJavaScript(
            functionBody: '''
              const r = await fetch(${jsonEncode(url)}, {
                headers: { "Accept": "text/html,application/xhtml+xml,*/*" },
                credentials: "include",
              });
              const body = await r.text();
              return {
                status: r.status,
                body: body,
                challenged: r.headers.get("cf-mitigated") === "challenge",
              };
            ''',
          )
          .timeout(const Duration(seconds: 25));
      if (res == null || res.error != null) {
        _log('rawFetch JS error: ${res?.error}');
        return failed;
      }
      final value = res.value;
      if (value is! Map) return failed;
      final status = (value['status'] as num?)?.toInt() ?? -1;
      final body = value['body']?.toString() ?? '';
      final challenged = value['challenged'] == true ||
          ((status == 403 || status == 503) &&
              body.contains('window._cf_chl_opt'));
      _log('rawFetch ← status=$status bytes=${body.length} '
          'challenged=$challenged');
      return (status: status, body: body, challenged: challenged);
    } on TimeoutException {
      _log('rawFetch TIMEOUT');
      return failed;
    } catch (e) {
      _log('rawFetch exception: $e');
      return failed;
    }
  }

  Future<void> dispose() async {
    _log('disposing headless webview');
    _idleTimer?.cancel();
    _idleTimer = null;
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
