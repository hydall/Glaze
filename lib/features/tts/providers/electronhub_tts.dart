import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Electron Hub's unified OpenAI-style speech endpoint.
class ElectronHubTtsProvider extends TtsProvider {
  final TtsHttp http;
  const ElectronHubTtsProvider(this.http);

  static const _fallbackVoices = [
    'alloy', 'ash', 'ballad', 'coral', 'echo', 'fable', 'onyx', 'nova',
    'sage', 'shimmer', 'verse',
  ];

  @override
  String get id => 'electronhub';

  @override
  String get displayName => 'Electron Hub';

  @override
  String get description => 'Electron Hub speech models.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.text('model', 'Model', defaultValue: 'tts-1'),
    TtsField.text(
      'voices',
      'Voices',
      hint: 'Optional override; defaults to the common OpenAI voices',
    ),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.25,
      max: 4,
      step: 0.05,
    ),
    TtsField.number(
      'temperature',
      'Temperature',
      defaultValue: 1,
      min: 0,
      max: 2,
      step: 0.1,
    ),
    TtsField.multiline(
      'instructions',
      'Voice instructions',
      hint: 'gpt-4o-mini-tts only',
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final override = parseVoiceList(config.str('voices'));
    if (override.isNotEmpty) return override;
    return [
      for (final v in _fallbackVoices) TtsVoice(name: v, voiceId: v),
    ];
  }

  @override
  Future<void> checkReady(TtsProviderConfig config) async {
    config.require('apiKey');
  }

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) {
    final model = config.str('model');
    final instructions = config.str('instructions');
    return http.postForAudio(
      'https://api.electronhub.ai/v1/audio/speech',
      headers: {'Authorization': 'Bearer ${config.require('apiKey')}'},
      body: {
        'input': text,
        'voice': voiceId,
        'speed': config.number('speed'),
        'temperature': config.number('temperature'),
        'model': model,
        'response_format': 'mp3',
        if (model == 'gpt-4o-mini-tts' && instructions.isNotEmpty)
          'instructions': instructions,
      },
      mime: 'audio/mpeg',
      cancelToken: cancelToken,
    );
  }
}
