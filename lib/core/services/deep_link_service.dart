import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  final Map<String, Completer<Uri>> _pendingOAuth = {};
  final Map<String, Uri> _earlyCallbacks = {};
  AppLinks? _appLinks;
  StreamSubscription<Uri>? _subscription;

  Future<void> init() async {
    // Guard against repeated init (widget tests pump the app multiple
    // times, and `_appLinks` is a process-wide singleton). The first
    // init wins; later calls are no-ops.
    if (_appLinks != null) return;
    _appLinks = AppLinks();

    try {
      final initialLink = await _appLinks!.getInitialLink();
      if (initialLink != null) _handleDeepLink(initialLink);
    } catch (_) {}

    _subscription = _appLinks!.uriLinkStream.listen(
      _handleDeepLink,
      onError: (Object e) => debugPrint('DeepLinkService: error: $e'),
    );
  }

  void _handleDeepLink(Uri uri) {
    debugPrint('DeepLinkService: received $uri');
    if (uri.host == 'oauth') {
      final provider = uri.path.replaceFirst('/', '');
      final completer = _pendingOAuth.remove(provider);
      if (completer != null && !completer.isCompleted) {
        completer.complete(uri);
      } else {
        _earlyCallbacks[provider] = uri;
      }
      return;
    }
    if (uri.scheme.startsWith('db-') && uri.host == 'auth') {
      final completer = _pendingOAuth.remove('dropbox');
      if (completer != null && !completer.isCompleted) {
        completer.complete(uri);
      } else {
        _earlyCallbacks['dropbox'] = uri;
      }
      return;
    }
    final host = uri.host;
    if (host.contains('googleusercontent')) {
      final completer = _pendingOAuth.remove('gdrive');
      if (completer != null && !completer.isCompleted) {
        completer.complete(uri);
      } else {
        _earlyCallbacks['gdrive'] = uri;
      }
    }
  }

  Future<Uri> waitForOAuthCallback(
    String provider, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final early = _earlyCallbacks.remove(provider);
    if (early != null) return early;

    final completer = Completer<Uri>();
    _pendingOAuth[provider] = completer;
    return completer.future.timeout(timeout, onTimeout: () {
      _pendingOAuth.remove(provider);
      throw TimeoutException('OAuth callback for $provider timed out');
    });
  }

  void cancelOAuth(String provider) {
    final completer = _pendingOAuth.remove(provider);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('OAuth cancelled'));
    }
  }

  void dispose() {
    _subscription?.cancel();
    for (final completer in _pendingOAuth.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Service disposed'));
      }
    }
    _pendingOAuth.clear();
  }
}
