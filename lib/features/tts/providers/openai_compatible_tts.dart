import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Any server speaking OpenAI's `/v1/audio/speech` shape (Kokoro-FastAPI,
/// openedai-speech, LocalAI, hosted proxies…).
class OpenAiCompatibleTtsProvider extends TtsProvider {
  final TtsHttp http;
  const OpenAiCompatibleTtsProvider(this.http);

  @override
  String get id => 'openai_compatible';

  @override
  String get displayName => 'OpenAI Compatible';

  @override
  String get description =>
      'Any server with an OpenAI-style /v1/audio/speech endpoint.';

  @override
  String get separator => ' . ';

  @override
  List<TtsField> get fields => const [
    TtsField.url(
      'endpoint',
      'Endpoint',
      defaultValue: 'http://127.0.0.1:8000/v1/audio/speech',
    ),
    TtsField.secret('apiKey', 'API key', hint: 'Optional'),
    TtsField.text('model', 'Model', defaultValue: 'tts-1'),
    TtsField.text(
      'voices',
      'Voices',
      defaultValue: 'alloy, echo, fable, onyx, nova, shimmer',
      hint: 'Comma-separated ids, or Name:id pairs',
    ),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.25,
      max: 4,
      step: 0.05,
    ),
    TtsField.select(
      'format',
      'Response format',
      defaultValue: 'mp3',
      options: [
        TtsFieldOption('mp3'),
        TtsFieldOption('wav'),
        TtsFieldOption('opus'),
        TtsFieldOption('flac'),
      ],
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async =>
      parseVoiceList(config.str('voices'));

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) {
    final key = config.str('apiKey');
    return http.postForAudio(
      config.require('endpoint'),
      headers: {if (key.isNotEmpty) 'Authorization': 'Bearer $key'},
      body: {
        'model': config.str('model'),
        'input': text,
        'voice': voiceId,
        'speed': config.number('speed'),
        'response_format': config.str('format'),
      },
      cancelToken: cancelToken,
    );
  }
}
