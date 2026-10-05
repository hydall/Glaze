import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;

import '../models/tts_types.dart';
import 'tts_provider.dart';

/// The operating system's own voices through `flutter_tts`.
///
/// On Android the engine can render to a WAV file, so these clips get a
/// duration, a waveform and the cache like any other provider. Elsewhere the
/// OS only speaks aloud: the pill then offers play and stop, nothing more.
/// Linux has no backend in the plugin.
class SystemTtsProvider extends TtsProvider {
  final String Function() tempDir;
  SystemTtsProvider({required this.tempDir});

  FlutterTts? _tts;
  FlutterTts get _engine => _tts ??= FlutterTts();
  int _fileSeq = 0;

  @override
  String get id => 'system';

  @override
  String get displayName => 'System';

  @override
  String get description => 'Voices installed in the operating system.';

  @override
  bool get producesAudio => Platform.isAndroid;

  @override
  List<TtsField> get fields => const [
    TtsField.number(
      'rate',
      'Rate',
      defaultValue: 0.5,
      min: 0.1,
      max: 1,
      step: 0.01,
      hint: '0.5 is normal speed',
    ),
    TtsField.number(
      'pitch',
      'Pitch',
      defaultValue: 1,
      min: 0.5,
      max: 2,
      step: 0.01,
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    if (Platform.isLinux) {
      throw const TtsNotConfigured('System voices are not available on Linux');
    }
    final raw = await _engine.getVoices;
    if (raw is! List) return const [];
    final voices = <TtsVoice>[];
    for (final v in raw) {
      if (v is! Map) continue;
      final name = v['name']?.toString() ?? '';
      final locale = v['locale']?.toString() ?? '';
      if (name.isEmpty) continue;
      voices.add(
        TtsVoice(
          name: locale.isEmpty ? name : '$name ($locale)',
          voiceId: '$name|$locale',
          lang: locale,
        ),
      );
    }
    voices.sort(
      (a, b) => (a.lang ?? '').compareTo(b.lang ?? '') != 0
          ? (a.lang ?? '').compareTo(b.lang ?? '')
          : a.name.compareTo(b.name),
    );
    return voices;
  }

  Future<void> _configure(String voiceId, TtsProviderConfig config) async {
    final sep = voiceId.indexOf('|');
    if (sep > 0) {
      await _engine.setVoice({
        'name': voiceId.substring(0, sep),
        'locale': voiceId.substring(sep + 1),
      });
    }
    await _engine.setSpeechRate(config.number('rate'));
    await _engine.setPitch(config.number('pitch'));
  }

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) async {
    if (!producesAudio) {
      throw const TtsException('System voices cannot render audio here');
    }
    await _configure(voiceId, config);
    await _engine.awaitSynthCompletion(true);
    final dir = Directory(tempDir());
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'system_${_fileSeq++}.wav'));
    await _engine.synthesizeToFile(text, file.path, true);
    if (!await file.exists()) {
      throw const TtsException('The system voice produced no audio');
    }
    final bytes = await file.readAsBytes();
    await file.delete();
    return TtsAudio(bytes, 'audio/wav');
  }

  @override
  Future<void> speak(
    String text,
    String voiceId,
    TtsProviderConfig config,
  ) async {
    await _configure(voiceId, config);
    await _engine.awaitSpeakCompletion(true);
    await _engine.speak(text);
  }

  @override
  Future<void> stopSpeaking() async {
    await _tts?.stop();
  }
}
