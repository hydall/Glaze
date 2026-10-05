import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// A local Chatterbox server. Predefined voices and cloned reference files
/// are two separate lists; a reference voice is requested by its `ref_`
/// prefixed name.
class ChatterboxTtsProvider extends TtsProvider {
  final TtsHttp http;
  const ChatterboxTtsProvider(this.http);

  static const _referencePrefix = 'ref_';

  @override
  String get id => 'chatterbox';

  @override
  String get displayName => 'Chatterbox';

  @override
  String get description => 'A local Chatterbox Multilingual server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://localhost:8000'),
    TtsField.select(
      'language',
      'Language',
      defaultValue: 'en',
      options: [
        TtsFieldOption('en'),
        TtsFieldOption('ru'),
        TtsFieldOption('pl'),
      ],
    ),
    TtsField.number(
      'temperature',
      'Temperature',
      defaultValue: 0.8,
      min: 0.05,
      max: 5,
      step: 0.05,
    ),
    TtsField.number(
      'exaggeration',
      'Exaggeration',
      defaultValue: 0.5,
      min: 0,
      max: 2,
      step: 0.05,
    ),
    TtsField.number(
      'cfgWeight',
      'CFG weight',
      defaultValue: 0.5,
      min: 0,
      max: 1,
      step: 0.05,
    ),
    TtsField.select(
      'outputFormat',
      'Output format',
      defaultValue: 'wav',
      options: [
        TtsFieldOption('wav'),
        TtsFieldOption('opus'),
        TtsFieldOption('mp3'),
      ],
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final base = config.str('endpoint');
    final voices = <TtsVoice>[];
    try {
      final json = await http.getJson('$base/get_predefined_voices');
      if (json is List) {
        for (final v in json) {
          if (v is! Map) continue;
          final id = (v['voice_id'] ?? v['filename'])?.toString();
          if (id == null || id.isEmpty) continue;
          voices.add(
            TtsVoice(
              name: (v['display_name'] ?? id).toString(),
              voiceId: id,
              lang: v['language']?.toString(),
            ),
          );
        }
      }
    } catch (_) {
      // Reference voices may still be available.
    }
    try {
      final json = await http.getJson('$base/get_reference_files');
      if (json is List) {
        for (final v in json) {
          if (v is! String) continue;
          voices.add(
            TtsVoice(name: '[Clone] $v', voiceId: '$_referencePrefix$v'),
          );
        }
      }
    } catch (_) {}
    return voices;
  }

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) {
    final isReference = voiceId.startsWith(_referencePrefix);
    final actual = isReference ? voiceId.substring(_referencePrefix.length) : voiceId;
    return http.postForAudio(
      '${config.str('endpoint')}/tts',
      body: {
        'text': text,
        'voice_mode': isReference ? 'clone' : 'predefined',
        if (isReference)
          'reference_audio_filename': actual
        else
          'predefined_voice_id': actual,
        'temperature': config.number('temperature'),
        'exaggeration': config.number('exaggeration'),
        'cfg_weight': config.number('cfgWeight'),
        'language': config.str('language'),
        'output_format': config.str('outputFormat'),
      },
      mime: 'audio/${config.str('outputFormat')}',
      cancelToken: cancelToken,
    );
  }
}
