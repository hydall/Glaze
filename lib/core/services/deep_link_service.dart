import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// One OAuth authorization in flight, and the `state` that identifies it.
///
/// The state is what makes an attempt addressable. Without it a callback is
/// just "something for Dropbox", and the only Dropbox thing in memory gets it —
/// which is how a callback from an abandoned attempt came to be handed to its
/// replacement.
class _OAuthAttempt {
  _OAuthAttempt(this.state);

  final String state;
  final Completer<Uri> completer = Completer<Uri>();
}

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  final Map<String, _OAuthAttempt> _pendingOAuth = {};

  /// A callback that arrived with nothing waiting for it. The app can be
  /// cold-started *by* the redirect, and on a warm start the URI can land in
  /// the sliver between the browser closing and the attempt registering, so
  /// these are worth holding — but only for the attempt they belong to.
  /// [beginOAuth] drops one that carries a different state.
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
      if (initialLink != null) handleDeepLink(initialLink);
    } catch (_) {}

    _subscription = _appLinks!.uriLinkStream.listen(
      handleDeepLink,
      onError: (Object e) => debugPrint('DeepLinkService: error: $e'),
    );
  }

  /// Routes an incoming link. Public so a test can deliver one without a
  /// platform channel; in the app it is only ever called by [init]'s stream.
  @visibleForTesting
  void handleDeepLink(Uri uri) {
    debugPrint('DeepLinkService: received $uri');
    final provider = _providerFor(uri);
    if (provider != null) _deliverOAuth(provider, uri);
  }

  String? _providerFor(Uri uri) {
    if (uri.host == 'oauth') return uri.path.replaceFirst('/', '');
    if (uri.scheme.startsWith('db-') && uri.host == 'auth') return 'dropbox';
    // Both halves are load-bearing. Android and desktop get
    // `com.hydall.glaze://oauth/gdrive`, caught above; iOS is handed a reversed
    // client id with a *single* slash — `com.googleusercontent.apps.123:/…` —
    // which parses to an empty host, so matching on the host alone never saw
    // it. (Untestable end to end while the shipped Drive client is revoked.)
    if (uri.host.contains('googleusercontent') ||
        uri.scheme.contains('googleusercontent')) {
      return 'gdrive';
    }
    return null;
  }

  void _deliverOAuth(String provider, Uri uri) {
    final returnedState = uri.queryParameters['state'];
    final attempt = _pendingOAuth[provider];

    if (attempt != null) {
      // Answered already: a duplicate redirect, or the second half of a
      // double-launched browser. The attempt stays registered until its caller
      // retires it, so this is the place that must not fall through and file
      // the duplicate as an early callback for whoever connects next.
      if (attempt.completer.isCompleted) return;

      if (!_belongsTo(attempt, returnedState)) {
        // The answer to a question nobody is still asking: the user finished
        // authorizing in a tab left over from an attempt that already failed.
        // Dropping it is the whole fix — handing it over resolved the live
        // attempt with someone else's state, and every retry failed the same
        // way until the process died and took the map with it.
        debugPrint(
          'DeepLinkService: dropped a $provider callback from another '
          'attempt (state=$returnedState)',
        );
        return;
      }
      // Completed, not removed. The callback can land in the window between
      // registering the attempt and awaiting it, and an attempt dropped here
      // would leave that await with nothing to find.
      attempt.completer.complete(uri);
      return;
    }

    _earlyCallbacks[provider] = uri;
  }

  /// A callback with no state at all is delivered to whatever is waiting: it
  /// is a denial or a malformed redirect, never the successful answer to a
  /// different attempt, and the caller says something useful about it far
  /// sooner than a five-minute timeout does.
  bool _belongsTo(_OAuthAttempt attempt, String? returnedState) =>
      returnedState == null || returnedState == attempt.state;

  /// Registers an attempt *before* its browser is launched, so a callback can
  /// never arrive with nothing to match it against.
  ///
  /// A second call supersedes the first: tapping Connect twice abandons the
  /// earlier attempt rather than leaving two waiting on one provider.
  void beginOAuth(String provider, String state) {
    final previous = _pendingOAuth.remove(provider);
    if (previous != null && !previous.completer.isCompleted) {
      previous.completer.completeError(
        StateError('OAuth attempt superseded by a newer one'),
      );
    }

    final early = _earlyCallbacks[provider];
    if (early != null && early.queryParameters['state'] != state) {
      _earlyCallbacks.remove(provider);
    }

    _pendingOAuth[provider] = _OAuthAttempt(state);
  }

  /// Waits for the callback belonging to the attempt [beginOAuth] registered.
  Future<Uri> awaitOAuthCallback(
    String provider, {
    Duration timeout = const Duration(minutes: 5),
  }) {
    final attempt = _pendingOAuth[provider];
    if (attempt == null) {
      return Future.error(
        StateError('No OAuth attempt in flight for $provider'),
      );
    }

    final early = _earlyCallbacks.remove(provider);
    if (early != null && !attempt.completer.isCompleted) {
      attempt.completer.complete(early);
    }

    return attempt.completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingOAuth.remove(provider);
        throw TimeoutException('OAuth callback for $provider timed out');
      },
    );
  }

  /// Forgets [state]'s attempt, whatever became of it. Called from the
  /// caller's `finally`, so it must not complete anything: by then the awaiting
  /// side is already unwinding and an error raised here would have nobody to
  /// catch it. It is keyed by state because a superseded attempt runs its own
  /// cleanup *after* its replacement has registered.
  void endOAuth(String provider, String state) {
    if (_pendingOAuth[provider]?.state == state) _pendingOAuth.remove(provider);
    if (_earlyCallbacks[provider]?.queryParameters['state'] == state) {
      _earlyCallbacks.remove(provider);
    }
  }

  /// Abandons whatever is in flight for [provider] and fails its waiter.
  void cancelOAuth(String provider) {
    final attempt = _pendingOAuth.remove(provider);
    if (attempt != null && !attempt.completer.isCompleted) {
      attempt.completer.completeError(StateError('OAuth cancelled'));
    }
    _earlyCallbacks.remove(provider);
  }

  void dispose() {
    _subscription?.cancel();
    for (final attempt in _pendingOAuth.values) {
      if (!attempt.completer.isCompleted) {
        attempt.completer.completeError(StateError('Service disposed'));
      }
    }
    _pendingOAuth.clear();
    _earlyCallbacks.clear();
  }

  /// Drops every attempt and every held callback without completing anything.
  /// The instance is process-wide, so a test that leaves state behind poisons
  /// the next one exactly the way the bug poisoned the next connect.
  @visibleForTesting
  void resetForTest() {
    _pendingOAuth.clear();
    _earlyCallbacks.clear();
  }
}
