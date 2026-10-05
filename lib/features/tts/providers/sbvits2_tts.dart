import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Style-Bert-VITS2 server. The voice list comes from `/models/info`, where
/// each model carries speaker and style tables.
class Sbvits2TtsProvider extends TtsProvider {
  final TtsHttp http;
  const Sbvits2TtsProvider(this.http);

  @override
  String get id => 'sbvits2';

  @override
  String get displayName => 'Style-Bert-VITS2';

  @override
  String get description => 'A local Style-Bert-VITS2 server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://localhost:5000'),
    TtsField.text('language', 'Language', defaultValue: 'JP'),
    TtsField.number(
      'length',
      'Length',
      defaultValue: 1,
      min: 0.1,
      max: 2,
      step: 0.05,
    ),
    TtsField.toggle('autoSplit', 'Auto split', defaultValue: true),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final json = await http.getJson('${config.str('endpoint')}/models/info');
    if (json is! Map) return const [];
    final voices = <TtsVoice>[];
    for (final entry in json.entries) {
      final model = entry.value;
      if (model is! Map) continue;
      final speakers = model['spk2id'];
      final styles = model['style2id'];
      if (speakers is! Map || styles is! Map) continue;
      for (final speaker in speakers.entries) {
        for (final style in styles.entries) {
          voices.add(
            TtsVoice(
              name: '${speaker.key} (${style.key})',
              voiceId: '${entry.key}-${speaker.value}-${style.key}',
            ),
          );
        }
      }
    }
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
    final parts = voiceId.split('-');
    if (parts.length < 3) {
      throw const TtsNotConfigured('Malformed Style-Bert-VITS2 voice id');
    }
    final model = parts.first;
    final speaker = parts[1];
    final style = parts.sublist(2).join('-');
    return http.getForAudio(
      '${config.str('endpoint')}/voice',
      query: {
        'text': text.replaceAll('<br>', '\n'),
        'model_id': model,
        'speaker_id': speaker,
        'style': style,
        'language': config.str('language'),
        'length': config.number('length'),
        'auto_split': config.flag('autoSplit').toString(),
      },
      mime: 'audio/wav',
      cancelToken: cancelToken,
    );
  }
}
