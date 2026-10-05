import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

class ElevenLabsTtsProvider extends TtsProvider {
  final TtsHttp http;
  const ElevenLabsTtsProvider(this.http);

  static const _base = 'https://api.elevenlabs.io/v1';

  @override
  String get id => 'elevenlabs';

  @override
  String get displayName => 'ElevenLabs';

  @override
  String get description => 'ElevenLabs voices, including your own clones.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.select(
      'model',
      'Model',
      defaultValue: 'eleven_multilingual_v2',
      options: [
        TtsFieldOption('eleven_multilingual_v2'),
        TtsFieldOption('eleven_v3'),
        TtsFieldOption('eleven_turbo_v2_5'),
        TtsFieldOption('eleven_flash_v2_5'),
        TtsFieldOption('eleven_monolingual_v1'),
      ],
    ),
    TtsField.number(
      'stability',
      'Stability',
      defaultValue: 0.75,
      min: 0,
      max: 1,
      step: 0.05,
    ),
    TtsField.number(
      'similarity',
      'Similarity boost',
      defaultValue: 0.75,
      min: 0,
      max: 1,
      step: 0.05,
    ),
    TtsField.number(
      'style',
      'Style exaggeration',
      defaultValue: 0,
      min: 0,
      max: 1,
      step: 0.05,
    ),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.7,
      max: 1.2,
      step: 0.01,
    ),
    TtsField.toggle('speakerBoost', 'Speaker boost', defaultValue: true),
    TtsField.select(
      'format',
      'Output format',
      defaultValue: 'mp3_44100_128',
      options: [
        TtsFieldOption('mp3_44100_128', 'MP3 44.1 kHz'),
        TtsFieldOption('pcm_16000', 'PCM 16 kHz'),
        TtsFieldOption('pcm_24000', 'PCM 24 kHz'),
        TtsFieldOption('pcm_44100', 'PCM 44.1 kHz'),
      ],
      hint: 'PCM above 16 kHz depends on the plan',
    ),
  ];

  Map<String, String> _headers(TtsProviderConfig config) => {
    'xi-api-key': config.require('apiKey'),
  };

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final json = await http.getJson('$_base/voices', headers: _headers(config));
    final list = json is Map ? json['voices'] : null;
    if (list is! List) return const [];
    return [
      for (final v in list)
        if (v is Map && v['voice_id'] is String)
          TtsVoice(
            name: (v['name'] as String?) ?? v['voice_id'] as String,
            voiceId: v['voice_id'] as String,
            previewUrl: v['preview_url'] as String?,
            lang: (v['labels'] is Map)
                ? (v['labels'] as Map)['language'] as String?
                : null,
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
  }) {
    final format = config.str('format');
    final pcmRate = format.startsWith('pcm_') ? format.substring(4) : null;
    return http.postForAudio(
      '$_base/text-to-speech/$voiceId',
      query: {'output_format': format},
      headers: _headers(config),
      body: {
        'text': text,
        'model_id': config.str('model'),
        'voice_settings': {
          'stability': config.number('stability'),
          'similarity_boost': config.number('similarity'),
          'style': config.number('style'),
          'use_speaker_boost': config.flag('speakerBoost'),
          'speed': config.number('speed'),
        },
      },
      mime: pcmRate == null ? null : 'audio/pcm;rate=$pcmRate',
      cancelToken: cancelToken,
    );
  }
}
