import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  group('Stage 5 — StudioConfig defaults', () {
    test('StudioConfig: defaults are correct', () {
      const config = StudioConfig(sessionId: 's1');
      expect(config.enabled, isFalse);
      expect(config.finalPresetId, '');
    });

    test('finalPresetId can be overridden', () {
      const config = StudioConfig(
        sessionId: 's1',
        finalPresetId: 'custom',
      );
      expect(config.finalPresetId, 'custom');
    });
  });
}
