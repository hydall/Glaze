import 'package:flutter/foundation.dart';

/// Times the retrieval step of one generation for the session log: how long
/// the context took to gather before retrieval, and how long each of the
/// parallel retrieval parts (memory, lorebook vector search, message recall)
/// ran, so a turn stuck on "Recalling memory" says which part held it.
///
/// One line per turn, written even when the turn was stopped mid-retrieval —
/// a reader who gave up waiting is the case the line exists for.
class RetrievalTiming {
  RetrievalTiming(this.sessionId);

  final String sessionId;
  final Stopwatch _watch = Stopwatch()..start();
  int? _preparingMs;
  final Map<String, String> _parts = {};
  final Set<String> _timedOut = {};
  final List<String> _order = [];

  /// Marks the end of the gathering that precedes retrieval.
  void retrievalStarted() => _preparingMs = _watch.elapsedMilliseconds;

  /// Wraps the retrieval part [name]. Call where the part starts, so its time
  /// is measured from its own start. An [active] false part is logged as off.
  Future<T> part<T>(String name, Future<T> future, {required bool active}) {
    _order.add(name);
    if (!active) {
      _parts[name] = 'off';
      return future;
    }
    final startMs = _watch.elapsedMilliseconds;
    return future.whenComplete(() {
      final ms = _watch.elapsedMilliseconds - startMs;
      _parts[name] = _timedOut.contains(name) ? '${ms}ms(timeout)' : '${ms}ms';
    });
  }

  /// The part gave up on its own deadline and returned nothing.
  void timedOut(String name) => _timedOut.add(name);

  /// The log line; a part that had not finished reads `unfinished`.
  String describe({bool aborted = false}) {
    final parts = [
      for (final name in _order) '$name=${_parts[name] ?? 'unfinished'}',
    ].join(' ');
    return '[retrieval] session=$sessionId '
        'preparingMs=${_preparingMs ?? '-'} $parts '
        'totalMs=${_watch.elapsedMilliseconds}${aborted ? ' aborted' : ''}';
  }

  void log({bool aborted = false}) => debugPrint(describe(aborted: aborted));
}
