import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What a run of the app was doing when it was last heard from.
enum SessionState {
  /// On screen. A run that is still `foreground` at the next launch ended
  /// without going through the background first — a crash, as seen from here.
  foreground,

  /// Off screen. The OS reclaims background apps without notice; a run that
  /// ends here is not a crash.
  background,

  /// The window was closed (desktop) or the engine detached.
  closed,
}

class SessionRecord {
  /// Log file of that run, relative to the logs root.
  final String logFile;
  final DateTime startedAt;
  final SessionState state;

  const SessionRecord({
    required this.logFile,
    required this.startedAt,
    required this.state,
  });

  Map<String, Object?> toJson() => {
    'log': logFile,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'state': state.name,
  };

  static SessionRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final log = raw['log'];
    final started = raw['startedAt'];
    final state = SessionState.values.asNameMap()[raw['state']];
    if (log is! String || started is! int || state == null) return null;
    return SessionRecord(
      logFile: log,
      startedAt: DateTime.fromMillisecondsSinceEpoch(started),
      state: state,
    );
  }

  SessionRecord copyWith({SessionState? state}) => SessionRecord(
    logFile: logFile,
    startedAt: startedAt,
    state: state ?? this.state,
  );
}

/// Keeps `logs/session.json` in step with the app's lifecycle, so the next
/// launch can tell how this one ended.
///
/// The marker is written synchronously on every change: the moments that
/// matter are exactly the ones where an async write would never land.
class SessionTracker {
  final File _marker;
  SessionRecord _current;

  SessionTracker._(this._marker, this._current);

  static const markerName = 'session.json';

  /// Reads the previous run's record, then replaces it with this run's.
  static (SessionTracker, SessionRecord?) begin({
    required String logsRoot,
    required SessionRecord current,
  }) {
    final marker = File(p.join(logsRoot, markerName));
    SessionRecord? previous;
    try {
      if (marker.existsSync()) {
        previous = SessionRecord.fromJson(
          jsonDecode(marker.readAsStringSync()),
        );
      }
    } catch (_) {
      // Torn write from a crash mid-update; nothing to learn from it.
    }
    final tracker = SessionTracker._(marker, current).._write();
    return (tracker, previous);
  }

  SessionState get state => _current.state;

  void update(SessionState state) {
    if (state == _current.state) return;
    _current = _current.copyWith(state: state);
    _write();
  }

  void _write() {
    try {
      _marker.parent.createSync(recursive: true);
      _marker.writeAsStringSync(jsonEncode(_current.toJson()), flush: true);
    } catch (_) {
      // Read-only or full disk: crash detection degrades, the app does not.
    }
  }
}
