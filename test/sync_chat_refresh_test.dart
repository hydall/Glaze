import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Body of the method named [signature] in [source], by brace matching.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThan(-1), reason: 'missing $signature');
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unbalanced braces after $signature');
}

void main() {
  // A pull writes chat sessions straight into the database, past the two
  // layers that serve them: `ChatSessionService` keeps a static, process-
  // lifetime cache, and `ChatNotifier` reads its session once in `build()` and
  // calls `keepAlive()`, so neither ever notices. That is what was reported —
  // freshly pulled messages appearing only after the app was closed and
  // reopened, because killing the process was the only thing that cleared
  // either one. Both are dropped here now; this is what keeps them dropped.
  String controller() => File(
    'lib/features/cloud_sync/services/sync_controller.dart',
  ).readAsStringSync();

  test('a sync pull drops both in-memory chat layers', () {
    final refresh = _methodBody(
      controller(),
      'Future<void> refreshDataProvidersAfterPull()',
    );
    expect(refresh, contains('ChatSessionService.clearCache()'));
    expect(refresh, contains('invalidate(chatProvider, asReload: true)'));
  });

  test('every manual sync that pulls runs the refresh', () {
    // A pull the reader triggered by hand is the path the report came from, so
    // 'pull' and 'full' both have to reach it; 'push' sends and changes
    // nothing locally.
    final doSync = _methodBody(
      controller(),
      "Future<String?> doSync(String mode)",
    );
    for (final mode in ["case 'pull':", "case 'full':"]) {
      final start = doSync.indexOf(mode);
      expect(start, greaterThan(-1), reason: 'missing $mode');
      final next = doSync.indexOf("case '", start + mode.length);
      final branch = doSync.substring(start, next == -1 ? doSync.length : next);
      expect(
        branch,
        contains('refreshDataProvidersAfterPull()'),
        reason: '$mode pulls but never refreshes',
      );
    }
  });

  test('the pull still writes chat sessions behind those layers', () {
    // The guard above only matters while this is true. If a pull ever starts
    // going through the notifier instead, revisit it rather than deleting it.
    final engine = File(
      'lib/features/cloud_sync/services/sync_engine.dart',
    ).readAsStringSync();
    expect(engine, contains('_chatRepo.put(ChatSession.fromJson('));
  });
}
