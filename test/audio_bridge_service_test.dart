// Tests for the `AudioBridgeService` audio backend.
//
// The service routes `glaze.playAudio(source, options)` calls to:
//   * Built-in cues (`click`, `alert`, `haptic`) — `SystemSound` /
//     `HapticFeedback`. These do not require a real audio player.
//   * `file://` / `http://` / `https://` URLs / absolute paths / `data:`
//     URIs — `audioplayers` with the matching source type.
//
// We don't bind to a real audio session in unit tests (the
// `audioplayers` plugin has no desktop/web test implementation). The
// routing table is tested via the `@visibleForTesting`
// [AudioBridgeService.routeSource] helper, which is a pure function
// that maps a source string to a [Source] subclass (or `null` for
// built-in cues / un-routable inputs). The built-in cues are tested
// directly because they don't touch the audio plugin.

import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/services/audio_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioBridgeService built-in cues', () {
    test('click routes to SystemSound.play(click)', () async {
      final service = AudioBridgeService();
      // Built-in cues bypass the audio player; we just verify the
      // service does not throw.
      await service.play('click', const {});
      await service.dispose();
    });

    test('alert routes to SystemSound.play(alert)', () async {
      final service = AudioBridgeService();
      await service.play('alert', const {});
      await service.dispose();
    });

    test('haptic routes to HapticFeedback.mediumImpact', () async {
      final service = AudioBridgeService();
      await service.play('haptic', const {});
      await service.dispose();
    });

    test('empty source is a no-op', () async {
      final service = AudioBridgeService();
      await service.play('', const {});
      await service.play('   ', const {});
      await service.dispose();
    });

    test('null source defaults to click', () async {
      final service = AudioBridgeService();
      await service.play(null, const {});
      await service.dispose();
    });

    test('case-insensitive cue names', () async {
      final service = AudioBridgeService();
      await service.play('CLICK', const {});
      await service.play('Haptic', const {});
      await service.play('Alert', const {});
      await service.dispose();
    });
  });

  group('AudioBridgeService.routeSource routing table', () {
    test('built-in cues return null (handled by the player-less path)', () {
      expect(AudioBridgeService.routeSource('click'), isNull);
      expect(AudioBridgeService.routeSource('alert'), isNull);
      expect(AudioBridgeService.routeSource('haptic'), isNull);
      expect(AudioBridgeService.routeSource('CLICK'), isNull);
      expect(AudioBridgeService.routeSource(''), isNull);
    });

    test('http(s) URL routes to UrlSource', () {
      final routed =
          AudioBridgeService.routeSource('https://example.com/sound.mp3');
      expect(routed, isA<UrlSource>());
      expect((routed as UrlSource).url, 'https://example.com/sound.mp3');

      final http = AudioBridgeService.routeSource('http://x/s.mp3');
      expect(http, isA<UrlSource>());
      expect((http as UrlSource).url, 'http://x/s.mp3');
    });

    test('file:// URL routes to UrlSource (player decodes it)', () {
      final routed = AudioBridgeService.routeSource('file:///tmp/sound.wav');
      expect(routed, isA<UrlSource>());
      expect((routed as UrlSource).url, 'file:///tmp/sound.wav');
    });

    test('absolute POSIX path routes to DeviceFileSource', () {
      final routed = AudioBridgeService.routeSource('/tmp/sound.wav');
      expect(routed, isA<DeviceFileSource>());
    });

    test('data: URI routes to BytesSource with the decoded payload', () {
      // 4-byte payload `0x00 0x01 0x02 0x03` → `AAECAw==`.
      final routed =
          AudioBridgeService.routeSource('data:audio/wav;base64,AAECAw==');
      expect(routed, isA<BytesSource>());
      expect((routed as BytesSource).bytes, [0x00, 0x01, 0x02, 0x03]);
    });

    test('data: URI with missing padding still decodes', () {
      // `AAECAw` (no `=`) — the decoder tolerates missing padding.
      final routed =
          AudioBridgeService.routeSource('data:audio/wav;base64,AAECAw');
      expect(routed, isA<BytesSource>());
      expect((routed as BytesSource).bytes, [0x00, 0x01, 0x02, 0x03]);
    });

    test('data: URI without base64 encoding returns null', () {
      // `data:text/plain,Hello` — not a base64 data URI; we don't
      // support plain-text data URIs, so this is a no-op.
      expect(
        AudioBridgeService.routeSource('data:text/plain,Hello'),
        isNull,
      );
    });

    test('malformed data: URI (no comma) returns null', () {
      expect(
        AudioBridgeService.routeSource('data:audio/wav;base64'),
        isNull,
      );
    });

    test('bare relative path falls through to DeviceFileSource (non-web)', () {
      final routed = AudioBridgeService.routeSource('audio_files/click.wav');
      expect(routed, isA<DeviceFileSource>());
    });
  });

  group('AudioBridgeService.decodeDataUri', () {
    test('roundtrips arbitrary bytes', () {
      final payload = List<int>.generate(32, (i) => i % 256);
      final encoded = base64UrlEncode(payload).replaceAll('=', '');
      final decoded =
          AudioBridgeService.decodeDataUri('data:audio/wav;base64,$encoded');
      expect(decoded, isNotNull);
      expect(decoded!.toList(), payload);
    });

    test('returns null on invalid base64', () {
      expect(
        AudioBridgeService.decodeDataUri('data:audio/wav;base64,***not-base64'),
        isNull,
      );
    });

    test('returns null when `;base64` is missing', () {
      expect(
        AudioBridgeService.decodeDataUri('data:audio/wav,AAECAw=='),
        isNull,
      );
    });
  });

  group('AudioBridgeService dispose', () {
    test('is idempotent and does not throw when never played', () async {
      final service = AudioBridgeService();
      await service.dispose();
      await service.dispose();
    });
  });
}
