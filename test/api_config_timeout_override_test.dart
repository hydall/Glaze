import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';

void main() {
  group('transportReceiveTimeoutMs', () {
    test('is null by default so the transport keeps its own limit', () {
      const config = ApiConfig(id: 'a', firstChunkTimeoutMs: 300000);
      expect(config.firstChunkTimeoutOverridesNetwork, isFalse);
      expect(config.transportReceiveTimeoutMs, isNull);
    });

    test('carries the reply timeout when the switch is on', () {
      const config = ApiConfig(
        id: 'a',
        firstChunkTimeoutMs: 300000,
        firstChunkTimeoutOverridesNetwork: true,
      );
      expect(config.transportReceiveTimeoutMs, 300000);
    });

    test('falls back to two minutes when the timeout is zero', () {
      const config = ApiConfig(
        id: 'a',
        firstChunkTimeoutMs: 0,
        firstChunkTimeoutOverridesNetwork: true,
      );
      expect(config.transportReceiveTimeoutMs, 120000);
    });

    test('a stored config without the field reads as off', () {
      final config = ApiConfig.fromJson({'id': 'a'});
      expect(config.firstChunkTimeoutOverridesNetwork, isFalse);
    });
  });
}
