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

/// How full the prompt may get before a stepped trim moves the anchor, as a
/// share of the context window — the number the prompt inspector shows, with
/// everything the request carries counted in, history included.
///
/// It used to be a share of the *history budget*, the context left once the
/// preset, the character, the lorebooks and memory had taken theirs. That
/// leftover moves with every turn's lorebook activation, so the same setting
/// cut three messages on one turn and thirty on the next; a share of the
/// whole window names a line the reader can see.
///
/// Below 100 % on purpose: stepping only once the window is already over
/// budget leaves no room for the turn that pushed it there, so the anchor
/// would move again immediately.
const int kDefaultHistoryTrimTriggerPercent = 85;

/// How much of the context window a step gives back.
///
/// The freed share is the headroom the following turns grow into, and it sets
/// how long the prefix — and with it a provider's cache — holds still. Larger
/// means rarer steps and longer cache runs at the cost of history on screen.
/// A step larger than the room the history has above the fixed part of the
/// prompt frees half of that room instead: freeing all of it would leave
/// nothing to hold, and the next turn would step again.
const int kDefaultHistoryTrimStepPercent = 30;

/// How far below the refill level a held window may sit before the anchor
/// moves back to it, as a share of the context window.
///
/// A turn whose lorebooks or memory swell cuts the history deep, and the
/// anchor it leaves would otherwise hold that cut for every turn after, long
/// after the room came back. Moving back costs a cache miss, but the prefix
/// that shrank back already missed; the slack keeps the ordinary ebb and flow
/// of a few per cent from moving the anchor every turn.
const int kHistoryAnchorRefillSlackPercent = 5;
