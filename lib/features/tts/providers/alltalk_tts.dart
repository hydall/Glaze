import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// AllTalk TTS server. Generation returns the URL of a rendered file that
/// then has to be downloaded.
class AllTalkTtsProvider extends TtsProvider {
  final TtsHttp http;
  const AllTalkTtsProvider(this.http);

  @override
  String get id => 'alltalk';

  @override
  String get displayName => 'AllTalk';

  @override
  String get description => 'AllTalk TTS server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url(
      'endpoint',
      'Server',
      defaultValue: 'http://127.0.0.1:7851',
    ),
    TtsField.text('language', 'Language', defaultValue: 'en'),
    TtsField.toggle('narrator', 'Narrator', defaultValue: false),
    TtsField.text('narratorVoice', 'Narrator voice', defaultValue: 'female_01.wav'),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final json = await http.getJson('${config.str('endpoint')}/api/voices');
    final list = json is Map ? json['voices'] : null;
    if (list is! List) return const [];
    return [
      for (final v in list)
        if (v is String) TtsVoice(name: v, voiceId: v, lang: 'en'),
    ];
  }

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) async {
    final base = config.str('endpoint');
    final json = await http.postJson(
      '$base/api/tts-generate',
      contentType: 'application/x-www-form-urlencoded',
      body: {
        'text_input': text,
        'text_filtering': 'standard',
        'character_voice_gen': voiceId,
        'narrator_enabled': config.flag('narrator').toString(),
        'narrator_voice_gen': config.str('narratorVoice'),
        'language': config.str('language'),
        'output_file_name': 'glaze_output',
        'output_file_timestamp': 'true',
        'autoplay': 'false',
      },
      cancelToken: cancelToken,
    );
    final url = json is Map ? json['output_file_url'] : null;
    if (url is! String || url.isEmpty) {
      throw const TtsException('AllTalk returned no file URL');
    }
    final resolved = url.startsWith('http') ? url : '$base$url';
    return http.download(resolved, cancelToken: cancelToken);
  }
}
