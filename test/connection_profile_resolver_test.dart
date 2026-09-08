// Tests for the `ConnectionProfileResolver`.
//
// The resolver maps `glaze.generateText({ preset })`'s `big` / `medium` /
// `small` request to an [ApiConfig] from the user's list. The mapping
// comes from the active extension preset's [ConnectionProfiles]:
//
//   * When a profile slot is configured, the matching [ApiConfig] is
//     returned (or the resolver falls through to the active fallback
//     when the id no longer exists in the config list).
//   * When the slot is empty, the resolver falls through to the
//     active API config (this is the legacy single-config behaviour).
//   * When the active fallback is also `null`, the resolver returns
//     `null` and the bridge surfaces a `StateError`.

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/extensions/models/connection_profiles.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/services/connection_profile_resolver.dart';

ApiConfig _config(String id, String name) => ApiConfig(
      id: id,
      name: name,
      endpoint: 'https://example.com/v1',
      apiKey: 'k-$id',
      model: 'm-$id',
    );

void main() {
  group('ConnectionProfileX.parse', () {
    test('returns null for null/non-string', () {
      expect(ConnectionProfileX.parse(null), isNull);
      expect(ConnectionProfileX.parse(7), isNull);
    });

    test('returns null for unknown names', () {
      expect(ConnectionProfileX.parse('tiny'), isNull);
      expect(ConnectionProfileX.parse(''), isNull);
    });

    test('parses big/medium/small case-insensitively', () {
      expect(ConnectionProfileX.parse('big'), ConnectionProfile.big);
      expect(ConnectionProfileX.parse('Big'), ConnectionProfile.big);
      expect(ConnectionProfileX.parse('BIG'), ConnectionProfile.big);
      expect(ConnectionProfileX.parse('medium'), ConnectionProfile.medium);
      expect(ConnectionProfileX.parse('small'), ConnectionProfile.small);
    });
  });

  group('ConnectionProfileResolver.resolve', () {
    const resolver = ConnectionProfileResolver();
    final configs = [
      _config('a', 'Alpha'),
      _config('b', 'Beta'),
      _config('c', 'Gamma'),
    ];
    final activeFallback = _config('a', 'Alpha');

    test('empty preset falls back to active config', () {
      final got = resolver.resolve(
        null,
        ConnectionProfile.big,
        activeFallback,
        configs,
      );
      expect(got, same(activeFallback));
    });

    test('empty profile slot falls back to active config', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'No profiles',
        blocks: const [],
      );
      final got = resolver.resolve(
        preset,
        ConnectionProfile.medium,
        activeFallback,
        configs,
      );
      expect(got, same(activeFallback));
    });

    test('configured big slot resolves to the matching config', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Has big',
        blocks: const [],
        connectionProfiles:
            const ConnectionProfiles(big: 'b', medium: 'a', small: 'c'),
      );
      expect(
        resolver.resolve(preset, ConnectionProfile.big, activeFallback, configs),
        same(configs[1]),
      );
      expect(
        resolver.resolve(
            preset, ConnectionProfile.medium, activeFallback, configs),
        same(configs[0]),
      );
      expect(
        resolver.resolve(
            preset, ConnectionProfile.small, activeFallback, configs),
        same(configs[2]),
      );
    });

    test('configured id missing from the config list falls through', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Stale id',
        blocks: const [],
        connectionProfiles: const ConnectionProfiles(big: 'deleted-id'),
      );
      final got = resolver.resolve(
        preset,
        ConnectionProfile.big,
        activeFallback,
        configs,
      );
      expect(got, same(activeFallback),
          reason: 'fall-through when the configured id no longer exists');
    });

    test('returns null when no config and no fallback', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Empty',
        blocks: const [],
        connectionProfiles: const ConnectionProfiles(big: 'missing'),
      );
      final got = resolver.resolve(
        preset,
        ConnectionProfile.big,
        null,
        configs,
      );
      expect(got, isNull);
    });
  });
}
