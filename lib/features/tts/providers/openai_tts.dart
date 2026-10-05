import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// OpenAI `/v1/audio/speech`. `gpt-4o-mini-tts` also takes free-form voice
/// instructions, set per speaker in the voice map screen.
class OpenAiTtsProvider extends TtsProvider {
  final TtsHttp http;
  const OpenAiTtsProvider(this.http);

  static const voices = [
    'Alloy', 'Ash', 'Ballad', 'Coral', 'Echo', 'Fable', 'Nova', 'Onyx',
    'Sage', 'Shimmer', 'Verse', 'Marin', 'Cedar',
  ];

  @override
  String get id => 'openai';

  @override
  String get displayName => 'OpenAI';

  @override
  String get description => 'OpenAI speech models. Uses its own API key.';

  @override
  String get separator => ' . ';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.select(
      'model',
      'Model',
      defaultValue: 'gpt-4o-mini-tts',
      options: [
        TtsFieldOption('gpt-4o-mini-tts'),
        TtsFieldOption('tts-1'),
        TtsFieldOption('tts-1-hd'),
      ],
    ),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.25,
      max: 4,
      step: 0.05,
    ),
    TtsField.multiline(
      'instructions',
      'Voice instructions',
      hint: 'gpt-4o-mini-tts only, e.g. "Speak softly and slowly"',
    ),
  ];

  @override
  TtsField? get perSpeakerField => const TtsField.multiline(
    'instructions',
    'Voice instructions',
    hint: 'gpt-4o-mini-tts only',
  );

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async => [
    for (final v in voices)
      TtsVoice(
        name: v,
        voiceId: v.toLowerCase(),
        lang: 'en-US',
        previewUrl:
            'https://cdn.openai.com/API/docs/audio/${v.toLowerCase()}.wav',
      ),
  ];

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
    final speakerInstructions = perSpeakerValue(config, speakerKey);
    final instructions = speakerInstructions.isNotEmpty
        ? speakerInstructions
        : config.str('instructions');
    return http.postForAudio(
      'https://api.openai.com/v1/audio/speech',
      headers: {'Authorization': 'Bearer ${config.require('apiKey')}'},
      body: {
        'model': model,
        'input': text,
        'voice': voiceId,
        'speed': config.number('speed'),
        // WAV keeps duration and waveform exact without a decoder.
        'response_format': 'wav',
        if (model == 'gpt-4o-mini-tts' && instructions.isNotEmpty)
          'instructions': instructions,
      },
      cancelToken: cancelToken,
    );
  }
}
