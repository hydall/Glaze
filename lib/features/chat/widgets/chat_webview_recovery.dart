/// Budget for throwing the chat WebView away and building a new one.
///
/// The page behind the chat can die while the app still believes it is there.
/// On Android the render process is killed under memory pressure — a
/// keep-alive WebView that sat in the background while another app ran is the
/// ordinary case — and on iOS the web content process can terminate for the
/// same reason. Afterwards nothing renders, `window.bridge` is gone, and every
/// call the app makes into the page returns without doing anything. That is
/// the reported "the messages are not there and the buttons under a message do
/// nothing": the bridge was lost and only reopening the chat rebuilt it.
///
/// Recovery is to discard the native view and build another one, which is
/// cheap and usually works. What it must not become is a loop: a page that
/// dies again the moment it is rebuilt is telling us the device cannot keep it
/// alive right now, and the reader is better served by being told than by
/// watching the chat flicker. So rebuilds are rationed, and a chat that
/// finishes initializing pays nothing — the budget exists to bound a storm,
/// not to count the lifetime of the app.
class ChatWebViewRecovery {
  ChatWebViewRecovery({
    this.maxAttempts = 3,
    this.window = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       assert(maxAttempts > 0);

  /// Rebuilds allowed inside [window].
  final int maxAttempts;
  final Duration window;
  final DateTime Function() _clock;
  final List<DateTime> _attempts = [];

  /// Rebuilds spent inside the current window.
  int get attemptsInWindow {
    _prune(_clock());
    return _attempts.length;
  }

  /// Books a rebuild. `false` once [maxAttempts] have been spent inside
  /// [window]: the caller must tell the reader instead of trying again.
  bool requestRebuild() {
    final now = _clock();
    _prune(now);
    if (_attempts.length >= maxAttempts) return false;
    _attempts.add(now);
    return true;
  }

  /// Called when the chat finished initializing. The page is alive, so
  /// whatever it took to get here is no longer evidence of a storm.
  void noteHealthy() => _attempts.clear();

  void _prune(DateTime now) =>
      _attempts.removeWhere((at) => now.difference(at) > window);
}
