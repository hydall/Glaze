import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_audio_analysis.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Gemini native speech through the Google AI Studio generate-content
/// endpoint. The voice list is fixed.
class GoogleNativeTtsProvider extends TtsProvider {
  final TtsHttp http;
  const GoogleNativeTtsProvider(this.http);

  static const voices = [
    'Zephyr', 'Puck', 'Charon', 'Kore', 'Fenrir', 'Leda', 'Orus', 'Aoede',
    'Callirhoe', 'Autonoe', 'Enceladus', 'Iapetus', 'Umbriel', 'Algieba',
    'Despina', 'Erinome', 'Algenib', 'Rasalgethi', 'Laomedeia', 'Achernar',
    'Alnilam', 'Schedar', 'Gacrux', 'Pulcherrima', 'Achird', 'Zubenelgenubi',
    'Vindemiatrix', 'Sadachbia', 'Sadaltager', 'Sulafat',
  ];

  @override
  String get id => 'google_native';

  @override
  String get displayName => 'Google Gemini TTS';

  @override
  String get description => 'Gemini speech synthesis. Uses a Google AI Studio key.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.select(
      'model',
      'Model',
      defaultValue: 'gemini-2.5-flash-preview-tts',
      options: [
        TtsFieldOption('gemini-2.5-flash-preview-tts'),
        TtsFieldOption('gemini-2.5-pro-preview-tts'),
        TtsFieldOption('gemini-3.1-flash-tts-preview'),
      ],
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async => [
    for (final v in voices) TtsVoice(name: v, voiceId: v, lang: 'en-US'),
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
  }) async {
    final model = config.str('model');
    final json = await http.postJson(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
      headers: {'x-goog-api-key': config.require('apiKey')},
      body: {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voiceId},
            },
          },
        },
      },
      cancelToken: cancelToken,
    );
    final part = _firstAudioPart(json);
    if (part == null) throw const TtsException('No audio in the response');
    final data = part['data'];
    if (data is! String) throw const TtsException('No audio data');
    final bytes = Uint8List.fromList(base64Decode(data));
    final mime = (part['mimeType'] as String? ?? '').toLowerCase();
    // The service answers raw PCM in an L16 container; wrap it so duration
    // and waveform come out exact.
    if (mime.contains('l16') || mime.contains('pcm')) {
      final rate =
          int.tryParse(RegExp(r'rate=(\d+)').firstMatch(mime)?.group(1) ?? '') ??
          24000;
      return TtsAudio(
        TtsAudioAnalysis.pcm16ToWav(bytes, sampleRate: rate),
        'audio/wav',
      );
    }
    return TtsAudio(bytes, mime.isEmpty ? 'audio/wav' : mime);
  }

  static Map<String, dynamic>? _firstAudioPart(Object? json) {
    if (json is! Map) return null;
    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final content = candidates.first is Map
        ? (candidates.first as Map)['content']
        : null;
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) return null;
    for (final part in parts) {
      if (part is! Map) continue;
      final inline = part['inlineData'];
      if (inline is Map && inline['data'] is String) {
        return Map<String, dynamic>.from(inline);
      }
    }
    return null;
  }
}
