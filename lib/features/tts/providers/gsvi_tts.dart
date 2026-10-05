import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// GSVI (GPT-SoVITS inference) server. It answers `GET /tts` with audio and
/// lists characters from `/character_list`.
class GsviTtsProvider extends TtsProvider {
  final TtsHttp http;
  const GsviTtsProvider(this.http);

  @override
  String get id => 'gsvi';

  @override
  String get displayName => 'GSVI';

  @override
  String get description => 'A local GSVI server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://localhost:5100'),
    TtsField.text('language', 'Text language', defaultValue: 'zh'),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.5,
      max: 2,
      step: 0.05,
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async =>
      voicesFromNames(
        await http.getJson('${config.str('endpoint')}/character_list'),
      );

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) => http.getForAudio(
    '${config.str('endpoint')}/tts',
    query: {
      'text': text,
      'cha_name': voiceId,
      'text_language': config.str('language'),
      'speed': config.number('speed'),
    },
    mime: 'audio/ogg',
    cancelToken: cancelToken,
  );
}
