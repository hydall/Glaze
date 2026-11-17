import 'dart:async';

/// Runs the image redraws of one block row one after another.
///
/// A redraw reads the row, draws, and writes the whole content back. Two of
/// them running side by side both start from the same text, so the one that
/// finishes last writes over the other and the first new picture is lost:
/// still on disk, paid for, and referenced by nothing (issue #839). Queued, the
/// second one starts from what the first one wrote.
///
/// A tap on a picture that is already being redrawn is dropped rather than
/// queued: it is almost always a double tap, and drawing the same picture a
/// second time is a second paid request the reader did not mean to make.
class BlockImageRerunQueue {
  final Map<String, Future<void>> _tails = {};
  final Map<String, Set<int?>> _waiting = {};

  /// Whether a redraw of [rowId] is running or waiting.
  bool isBusy(String rowId) => _tails.containsKey(rowId);

  /// Runs [body] once every redraw already queued for [rowId] has finished.
  ///
  /// [imageIndex] is the picture being redrawn (null: the block's header
  /// control, which redraws them all). Returns false without running [body]
  /// when a redraw of the same picture of the same row is already running or
  /// waiting.
  Future<bool> run(
    String rowId,
    int? imageIndex,
    Future<void> Function() body,
  ) async {
    final waiting = _waiting.putIfAbsent(rowId, () => <int?>{});
    if (!waiting.add(imageIndex)) return false;

    final previous = _tails[rowId];
    final done = Completer<void>();
    final tail = done.future;
    _tails[rowId] = tail;
    try {
      // Never fails: every tail is completed normally in the `finally` below.
      if (previous != null) await previous;
      await body();
      return true;
    } finally {
      waiting.remove(imageIndex);
      if (waiting.isEmpty) _waiting.remove(rowId);
      _tails.removeWhere((_, pending) => identical(pending, tail));
      done.complete();
    }
  }
}
