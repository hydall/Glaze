import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Silero TTS server (SillyTavern-extras or the standalone silero-api-server).
class SileroTtsProvider extends TtsProvider {
  final TtsHttp http;
  const SileroTtsProvider(this.http);

  @override
  String get id => 'silero';

  @override
  String get displayName => 'Silero';

  @override
  String get description => 'A local Silero TTS server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url(
      'endpoint',
      'Server',
      defaultValue: 'http://localhost:8001',
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
    '${config.str('endpoint')}/generate',
    body: {'text': text, 'speaker': voiceId, 'session': 'glaze'},
    mime: 'audio/wav',
    cancelToken: cancelToken,
  );
}
