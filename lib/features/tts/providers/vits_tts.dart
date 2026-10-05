import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// The VITS server (`voice/speakers` + `voice/{model}`).
class VitsTtsProvider extends TtsProvider {
  final TtsHttp http;
  const VitsTtsProvider(this.http);

  static const modelTypes = ['VITS', 'W2V2-VITS', 'BERT-VITS2'];

  @override
  String get id => 'vits';

  @override
  String get displayName => 'VITS';

  @override
  String get description => 'A local VITS server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://localhost:23456'),
    TtsField.text('lang', 'Language', defaultValue: 'auto'),
    TtsField.select(
      'format',
      'Output format',
      defaultValue: 'wav',
      options: [
        TtsFieldOption('wav'),
        TtsFieldOption('ogg'),
        TtsFieldOption('aac'),
        TtsFieldOption('mp3'),
      ],
    ),
    TtsField.number(
      'length',
      'Speed',
      defaultValue: 1,
      min: 0.1,
      max: 5,
      step: 0.1,
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final json = await http.getJson(
      '${config.str('endpoint')}/voice/speakers',
    );
    if (json is! Map) return const [];
    final voices = <TtsVoice>[];
    for (final type in modelTypes) {
      final list = json[type];
      if (list is! List) continue;
      for (final v in list) {
        if (v is! Map) continue;
        final name = v['name']?.toString() ?? '';
        final id = v['id'];
        if (name.isEmpty || id == null) continue;
        voices.add(
          TtsVoice(
            name: '[$type] $name (${v['lang'] ?? ''})',
            voiceId: '$type&$id',
            lang: v['lang']?.toString(),
          ),
        );
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
    final parts = voiceId.split('&');
    if (parts.length != 2) {
      throw const TtsNotConfigured('Malformed VITS voice id');
    }
    final type = parts[0];
    return http.postForAudio(
      '${config.str('endpoint')}/voice/${type.toLowerCase()}',
      contentType: 'application/x-www-form-urlencoded',
      body: {
        'text': text,
        'id': parts[1],
        'format': config.str('format'),
        'lang': config.str('lang'),
        'length': config.number('length'),
        'noise': 0.667,
        'noisew': 0.8,
        'segment_size': 1024,
        'sdp_ratio': 0.2,
        if (type == 'W2V2-VITS') 'emotion': 1,
        if (type == 'BERT-VITS2') 'emotion': 0,
      },
      mime: 'audio/${config.str('format')}',
      cancelToken: cancelToken,
    );
  }
}
