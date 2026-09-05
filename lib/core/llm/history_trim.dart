/// How the history is cut once it stops fitting the context window.
///
/// The two modes trade the same tokens for different cache behaviour, which is
/// why the setting lives on the connection next to `cacheControlTtl` and
/// `cacheBreakpointMode` rather than in app settings.
abstract final class HistoryTrimMode {
  /// Drop exactly what does not fit, recomputed every turn.
  ///
  /// The oldest message in the prompt moves forward on almost every turn, so
  /// the request prefix differs from the last one and a provider's prefix cache
  /// misses every time. Correct and simple; the default.
  static const String sliding = 'sliding';

  /// Drop a block at a time and hold the start of the history still between
  /// blocks.
  ///
  /// When the anchored window stops fitting, the anchor jumps forward far
  /// enough to leave headroom ([kSteppedRefillTarget]); for the many turns it
  /// takes to spend that headroom the prefix is byte-identical, so
  /// [markStablePrefixCacheControl] can mark a deep breakpoint and the provider
  /// serves the prefix from cache. One big miss instead of one per turn.
  static const String stepped = 'stepped';

  static const List<String> all = [sliding, stepped];

  static String normalize(String? value) =>
      all.contains(value) ? value! : sliding;
}

/// How full the anchored window may get before a stepped trim moves the anchor.
///
/// Below 100 % on purpose: stepping only once the window is already over budget
/// leaves no room for the turn that pushed it there, so the anchor would move
/// again immediately.
const int kDefaultHistoryTrimTriggerPercent = 85;

/// How much of the history budget a step gives back.
///
/// The freed share is the headroom the following turns grow into, and it sets
/// how long the prefix — and with it a provider's cache — holds still. Larger
/// means rarer steps and longer cache runs at the cost of history on screen.
const int kDefaultHistoryTrimStepPercent = 30;
