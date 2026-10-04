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
  // Both preset libraries are read once and cached — `presetListProvider` is an
  // AsyncNotifier over `getAll()`, `studioPresetListProvider` a FutureProvider
  // over the same — where the folder providers are Drift streams that refresh
  // themselves. A sync pull writes presets straight through the repositories,
  // so nothing tells either list it is stale: presets (and the cover images
  // pulled alongside them) stayed invisible until the app was restarted.
  test('a sync pull refreshes both preset libraries', () {
    final body = _methodBody(
      File(
        'lib/features/cloud_sync/services/sync_controller.dart',
      ).readAsStringSync(),
      'Future<void> refreshDataProvidersAfterPull()',
    );

    expect(body, contains('invalidate(presetListProvider)'));
    expect(body, contains('invalidate(studioPresetListProvider)'));
  });

  test('the pull still writes both preset kinds through their repos', () {
    // The guard above only matters while this is true; if a pull ever stops
    // writing presets directly, revisit it rather than deleting it blindly.
    final engine = File(
      'lib/features/cloud_sync/services/sync_engine.dart',
    ).readAsStringSync();

    expect(engine, contains("case 'theme_presets':"));
    expect(engine, contains("case 'studio_preset':"));
  });
}
