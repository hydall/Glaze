// Tests for the `ConnectionProfileResolver`.
//
// The resolver answers `glaze.generateText({ preset })` with the connection
// the active extension preset runs on. A preset has one, so `big` / `medium` /
// `small` all resolve to it:
//
//   * When the preset names a connection, the matching [ApiConfig] is
//     returned (or the resolver falls through to the active fallback
//     when the id no longer exists in the config list).
//   * When it names none, the resolver falls through to the active API
//     config (this is the legacy single-config behaviour).
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

    test('a preset naming no connection falls back to active config', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'No connection',
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

    test('every profile resolves to the preset\'s one connection', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Has a connection',
        blocks: const [],
        apiConfigId: 'b',
      );
      for (final profile in ConnectionProfile.values) {
        expect(
          resolver.resolve(preset, profile, activeFallback, configs),
          same(configs[1]),
          reason: 'the requested profile does not change the connection',
        );
      }
    });

    test('a preset stored with connection profiles keeps its connection', () {
      // Written before the three profiles collapsed into one.
      final preset = ExtensionPreset.fromJson(const {
        'id': 'p1',
        'name': 'Legacy',
        'blocks': <Map<String, dynamic>>[],
        'connectionProfiles': {'big': '', 'medium': 'c', 'small': 'a'},
      });
      expect(preset.apiConfigId, 'c');
      expect(
        resolver.resolve(
          preset,
          ConnectionProfile.big,
          activeFallback,
          configs,
        ),
        same(configs[2]),
      );
    });

    test('configured id missing from the config list falls through', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Stale id',
        blocks: const [],
        apiConfigId: 'deleted-id',
      );
      final got = resolver.resolve(
        preset,
        ConnectionProfile.big,
        activeFallback,
        configs,
      );
      expect(
        got,
        same(activeFallback),
        reason: 'fall-through when the configured id no longer exists',
      );
    });

    test('returns null when no config and no fallback', () {
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Empty',
        blocks: const [],
        apiConfigId: 'missing',
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
