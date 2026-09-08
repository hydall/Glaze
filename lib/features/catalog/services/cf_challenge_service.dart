import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _cfLog(String msg) => debugPrint('[CF] $msg');

const _cookieKey = 'gz_cf_clearance_janitor';
const _expiryKey = 'gz_cf_expiry_janitor';
const _uaKey = 'gz_cf_ua_janitor';

/// Browser UA passed in every Dio request to janitorai.com.
/// Must match what the challenge WebView sends, otherwise CF rejects the cookie.
const cfBrowserUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

/// Coordinates the Cloudflare Turnstile challenge for janitorai.com.
///
/// Flow:
///   1. [_janitorFetch] receives 403 → calls [solve].
///   2. [solve] flips [isPending] to `true` and blocks on a [Completer].
///   3. [CatalogGrid] reacts to [isPending] and shows an [InAppWebView].
///   4. The WebView finds `cf_clearance` → calls [completeChallengeWith].
///   5. [solve] returns the cookie, [_janitorFetch] retries.
class CfChallengeService {
  CfChallengeService._();
  static final CfChallengeService instance = CfChallengeService._();

  /// `true` while waiting for the UI WebView to obtain `cf_clearance`.
  final isPending = ValueNotifier<bool>(false);

  String? _cached;
  String? _savedUA;
  Completer<String?>? _pending;

  /// The UA that the challenge WebView used — must match subsequent API requests.
  String? get activeUA => _savedUA;

  void setWebViewUA(String ua) => _savedUA = ua;

  /// Returns the cached `cf_clearance` cookie if still within TTL, else null.
  Future<String?> getCookie() async {
    if (_cached != null) return _cached;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_cookieKey);
    final expiry = prefs.getInt(_expiryKey) ?? 0;
    if (stored != null && DateTime.now().millisecondsSinceEpoch < expiry) {
      _cached = stored;
      _savedUA ??= prefs.getString(_uaKey);
      return stored;
    }
    return null;
  }

  /// Signals the UI to show the challenge WebView and waits until
  /// [completeChallengeWith] is called. Concurrent callers share the same wait.
  Future<String?> solve() async {
    if (_pending != null) {
      _cfLog('solve() — reusing existing pending challenge');
      return _pending!.future;
    }
    _cfLog('solve() — starting new challenge');
    final c = Completer<String?>();
    _pending = c;
    isPending.value = true;
    try {
      final result = await c.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          _cfLog('solve() — TIMEOUT after 90s');
          return null;
        },
      );
      _cfLog('solve() — completed, cookie=${result != null ? 'present' : 'null'}');
      return result;
    } finally {
      isPending.value = false;
      _pending = null;
    }
  }

  /// Called by the catalog WebView widget when `cf_clearance` is found.
  void completeChallengeWith(String? cookie) {
    if (_pending == null || _pending!.isCompleted) {
      _cfLog('completeChallengeWith() — no pending challenge, ignoring');
      return;
    }
    _cfLog('completeChallengeWith() — cookie=${cookie != null ? 'present' : 'null'}');
    if (cookie != null) unawaited(_persist(cookie));
    _pending!.complete(cookie);
  }

  /// Drops the cached cookie so the next request triggers a fresh challenge.
  /// Does NOT clear [_savedUA] — the WebView UA is an environment property
  /// that survives cookie invalidation and must stay consistent with the
  /// cf_clearance cookie that will be issued by the next challenge.
  void invalidate() {
    _cfLog('invalidate() called');
    _cached = null;
    SharedPreferences.getInstance().then((p) {
      p.remove(_cookieKey);
      p.remove(_expiryKey);
    });
  }

  Future<void> _persist(String value) async {
    _cached = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cookieKey, value);
    if (_savedUA != null) await prefs.setString(_uaKey, _savedUA!);
    await prefs.setInt(
      _expiryKey,
      DateTime.now().add(const Duration(hours: 20)).millisecondsSinceEpoch,
    );
  }
}
