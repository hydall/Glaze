import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// A Coqui XTTS server exposing `/speakers` and `/tts_to_audio/`.
class XttsTtsProvider extends TtsProvider {
  final TtsHttp http;
  const XttsTtsProvider(this.http);

  @override
  String get id => 'xtts';

  @override
  String get displayName => 'XTTSv2';

  @override
  String get description => 'A local Coqui XTTS server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://127.0.0.1:8020'),
    TtsField.text('language', 'Language', defaultValue: 'en'),
    TtsField.number(
      'temperature',
      'Temperature',
      defaultValue: 0.75,
      min: 0,
      max: 1,
      step: 0.05,
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async =>
      voicesFromNames(
        await http.getJson('${config.str('endpoint')}/speakers'),
      );

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) => http.postForAudio(
    '${config.str('endpoint')}/tts_to_audio/',
    body: {
      'text': text,
      'speaker_wav': voiceId,
      'language': config.str('language'),
    },
    mime: 'audio/wav',
    cancelToken: cancelToken,
  );
}
