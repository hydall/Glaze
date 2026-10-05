import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// NovelAI's voice endpoint. The built-in voices are fixed and any other
/// name becomes a new random voice server-side, which is why custom names
/// are offered through the same settings field.
class NovelAiTtsProvider extends TtsProvider {
  final TtsHttp http;
  const NovelAiTtsProvider(this.http);

  static const voices = [
    'Ligeia', 'Aini', 'Orea', 'Claea', 'Lim', 'Aurae', 'Naia', 'Aulon',
    'Elei', 'Ogma', 'Raid', 'Pega', 'Lam',
  ];

  @override
  String get id => 'novelai';

  @override
  String get displayName => 'NovelAI';

  @override
  String get description => 'NovelAI voices. One request per 1000 characters.';

  @override
  String get separator => ' . ';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'Access token'),
    TtsField.text('customVoices', 'Custom voices', hint: 'Comma-separated names'),
  ];

  @override
  String processText(String text) =>
      // NovelAI reads tilde and asterisk as words.
      text.replaceAll('~', '.').replaceAll('*', '');

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async => [
    for (final v in voices) TtsVoice(name: v, voiceId: v, lang: 'en-US'),
    for (final v in parseVoiceList(config.str('customVoices')))
      TtsVoice(name: v.name, voiceId: v.voiceId, lang: 'en-US'),
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
    // The voice id rides in the `seed` field, as the API has no voice
    // parameter.
    return http.getForAudio(
      'https://api.novelai.net/ai/generate-voice',
      query: {
        'text': text,
        'voice': '-1',
        'seed': voiceId,
        'opus': 'false',
        'version': 'v2',
      },
      headers: {
        'Authorization': 'Bearer ${config.require('apiKey')}',
        'Accept': 'audio/mpeg',
      },
      mime: 'audio/mpeg',
      cancelToken: cancelToken,
    );
  }
}
