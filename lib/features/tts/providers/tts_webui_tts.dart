import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// The TTS-WebUI server (an OpenAI-compatible `/v1/audio/speech` shape with
/// a `/voices/{model}` listing).
class TtsWebuiProvider extends TtsProvider {
  final TtsHttp http;
  const TtsWebuiProvider(this.http);

  @override
  String get id => 'tts_webui';

  @override
  String get displayName => 'TTS WebUI';

  @override
  String get description => 'A local TTS-WebUI server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url(
      'endpoint',
      'Server',
      defaultValue: 'http://127.0.0.1:7778/v1/audio/speech',
    ),
    TtsField.text('model', 'Model', defaultValue: 'chatterbox'),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.25,
      max: 4,
      step: 0.05,
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final endpoint = config.str('endpoint');
    // The listing lives next to the speech endpoint.
    final voicesUrl = endpoint.endsWith('/speech')
        ? '${endpoint.substring(0, endpoint.length - 7)}/voices/${config.str('model')}'
        : '${config.str('endpoint')}/voices/${config.str('model')}';
    final json = await http.getJson(voicesUrl);
    final list = json is Map ? json['voices'] : null;
    if (list is! List) return const [];
    return [
      for (final v in list)
        if (v is Map && v['value'] != null)
          TtsVoice(
            name: (v['label'] ?? v['value']).toString(),
            voiceId: v['value'].toString(),
            lang: 'en-US',
          ),
    ];
  }

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) => http.postForAudio(
    config.str('endpoint'),
    body: {
      'model': config.str('model'),
      'voice': voiceId,
      'input': text,
      'response_format': 'wav',
      'speed': config.number('speed'),
      'stream': false,
    },
    mime: 'audio/wav',
    cancelToken: cancelToken,
  );
}
