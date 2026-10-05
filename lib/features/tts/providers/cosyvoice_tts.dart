import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// CosyVoice's local HTTP server.
class CosyVoiceTtsProvider extends TtsProvider {
  final TtsHttp http;
  const CosyVoiceTtsProvider(this.http);

  @override
  String get id => 'cosyvoice';

  @override
  String get displayName => 'CosyVoice (unofficial)';

  @override
  String get description => 'A local CosyVoice server.';

  @override
  bool get isLocal => true;

  @override
  List<TtsField> get fields => const [
    TtsField.url('endpoint', 'Server', defaultValue: 'http://localhost:9880'),
    TtsField.text('textLang', 'Text language', defaultValue: 'zh'),
    TtsField.text('promptLang', 'Prompt language', defaultValue: 'zh'),
    TtsField.text('mediaType', 'Output format', defaultValue: 'wav'),
    TtsField.toggle('streaming', 'Streaming', defaultValue: false),
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
    '${config.str('endpoint')}/',
    body: {
      'text': text,
      'spk_id': voiceId,
      'text_lang': config.str('textLang'),
      'prompt_lang': config.str('promptLang'),
      'media_type': config.str('mediaType'),
      'streaming_mode': config.flag('streaming').toString(),
    },
    mime: 'audio/${config.str('mediaType')}',
    cancelToken: cancelToken,
  );
}
