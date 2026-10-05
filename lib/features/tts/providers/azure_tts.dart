import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Azure Cognitive Services speech, region-scoped.
class AzureTtsProvider extends TtsProvider {
  final TtsHttp http;
  const AzureTtsProvider(this.http);

  @override
  String get id => 'azure';

  @override
  String get displayName => 'Azure';

  @override
  String get description => 'Microsoft Azure speech voices. Needs a key and region.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.text('region', 'Region', hint: 'e.g. westus'),
    TtsField.select(
      'format',
      'Output format',
      defaultValue: 'audio-24khz-48kbitrate-mono-mp3',
      options: [
        TtsFieldOption('audio-24khz-48kbitrate-mono-mp3', 'MP3 24 kHz'),
        TtsFieldOption('audio-48khz-96kbitrate-mono-mp3', 'MP3 48 kHz'),
        TtsFieldOption('riff-24khz-16bit-mono-pcm', 'WAV 24 kHz'),
      ],
    ),
  ];

  String _base(TtsProviderConfig config) =>
      'https://${config.require('region')}.tts.speech.microsoft.com/cognitiveservices';

  Map<String, String> _headers(TtsProviderConfig config) => {
    'Ocp-Apim-Subscription-Key': config.require('apiKey'),
  };

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final json = await http.getJson(
      '${_base(config)}/voices/list',
      headers: _headers(config),
    );
    if (json is! List) return const [];
    final voices = [
      for (final v in json)
        if (v is Map && v['ShortName'] is String)
          TtsVoice(
            name: v['ShortName'] as String,
            voiceId: v['ShortName'] as String,
            lang: v['Locale'] as String?,
          ),
    ];
    voices.sort((a, b) {
      final byLang = (a.lang ?? '').compareTo(b.lang ?? '');
      return byLang != 0 ? byLang : a.name.compareTo(b.name);
    });
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
    final lang = voiceId.split('-').take(2).join('-');
    final escaped = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final ssml =
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='$lang'><voice xml:lang='$lang' name='$voiceId'>"
        '$escaped</voice></speak>';
    return http.postForAudio(
      '${_base(config)}/v1',
      headers: {
        ..._headers(config),
        'Content-Type': 'application/ssml+xml',
        'X-Microsoft-OutputFormat': config.str('format'),
      },
      body: ssml,
      contentType: 'application/ssml+xml',
      cancelToken: cancelToken,
    );
  }
}
