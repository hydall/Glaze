import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/tts/models/tts_types.dart';
import 'package:glaze_flutter/features/tts/services/tts_audio_analysis.dart';
import 'package:glaze_flutter/features/tts/services/tts_audio_cache.dart';
import 'package:glaze_flutter/features/tts/services/tts_http.dart';

/// One second of 16-bit mono PCM: silence for the first half, a sine wave
/// for the second.
Uint8List halfSilentPcm(int rate) {
  final data = ByteData(rate * 2);
  for (var i = 0; i < rate; i++) {
    final v = i < rate ~/ 2 ? 0 : (math.sin(i / 10) * 20000).round();
    data.setInt16(i * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('analysis', () {
    test('reads duration and peaks from a WAV', () {
      final wav = TtsAudioAnalysis.pcm16ToWav(halfSilentPcm(8000), sampleRate: 8000);
      final info = TtsAudioAnalysis.analyzeWav(wav, buckets: 10)!;
      expect(info.durationMs, 1000);
      expect(info.peaks, hasLength(10));
      // Silence sits at the floor, the loud half is normalised to 1.
      expect(info.peaks.first, closeTo(0.08, 0.001));
      expect(info.peaks.last, closeTo(1, 0.05));
    });

    test('rejects non-WAV bytes', () {
      expect(TtsAudioAnalysis.analyzeWav(Uint8List(100)), isNull);
    });

    test('merges clips proportionally to duration', () {
      final merged = TtsAudioAnalysis.mergePeaks(const [
        TtsClipInfo(durationMs: 1000, peaks: [0.2, 0.2]),
        TtsClipInfo(durationMs: 3000, peaks: [1, 1]),
      ], buckets: 4);
      expect(merged, [0.2, 1, 1, 1]);
    });

    test('sniffs audio containers', () {
      final wav = TtsAudioAnalysis.pcm16ToWav(Uint8List(32), sampleRate: 8000);
      expect(sniffAudioMime(wav), 'audio/wav');
      expect(sniffAudioMime(Uint8List.fromList([0x49, 0x44, 0x33, ...List.filled(20, 0)])), 'audio/mpeg');
      expect(sniffAudioMime(Uint8List.fromList('OggS'.codeUnits + List.filled(20, 0))), 'audio/ogg');
    });
  });

  group('cache key', () {
    String key({String text = 'Hello', String voice = 'a', String fp = 'x'}) =>
        ttsClipKey(
          providerId: 'openai',
          voiceId: voice,
          settingsFingerprint: fp,
          text: text,
        );

    test('is stable', () => expect(key(), key()));
    test('changes with the text', () => expect(key(text: 'Hello!'), isNot(key())));
    test('changes with the voice', () => expect(key(voice: 'b'), isNot(key())));
    test('changes with settings', () => expect(key(fp: 'y'), isNot(key())));
  });

  group('cache store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tts_cache_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('persists clips and their info across loads', () async {
      final cache = TtsAudioCache(dir.path);
      await cache.load();
      const info = TtsClipInfo(durationMs: 1200, peaks: [0.5, 1]);
      await cache.put(
        'k1',
        TtsAudio(Uint8List.fromList([1, 2, 3]), 'audio/mpeg'),
        info,
        persistent: true,
      );
      await cache.flush();

      final reloaded = TtsAudioCache(dir.path);
      await reloaded.load();
      final clip = await reloaded.lookup('k1', usePersistent: true);
      expect(clip, isNotNull);
      expect(clip!.path, endsWith('k1.mp3'));
      expect(clip.info!.durationMs, 1200);
      expect(await reloaded.lookup('k1', usePersistent: false), isNull);
    });

    test('session clips do not survive a restart', () async {
      final cache = TtsAudioCache(dir.path);
      await cache.load();
      await cache.put(
        'k2',
        TtsAudio(Uint8List.fromList([1]), 'audio/wav'),
        null,
        persistent: false,
      );
      expect(await cache.lookup('k2', usePersistent: false), isNotNull);

      final restarted = TtsAudioCache(dir.path);
      await restarted.load();
      expect(await restarted.lookup('k2', usePersistent: true), isNull);
    });

    test('clearAll empties the cache', () async {
      final cache = TtsAudioCache(dir.path);
      await cache.load();
      await cache.put(
        'k3',
        TtsAudio(Uint8List.fromList([1]), 'audio/wav'),
        null,
        persistent: true,
      );
      await cache.clearAll();
      expect(await cache.lookup('k3', usePersistent: true), isNull);
      expect(await cache.persistentSize(), 0);
    });
  });
}
