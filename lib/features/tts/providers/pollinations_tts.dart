import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Pollinations' OpenAI-audio models. The audio arrives base64-encoded in a
/// chat-completion response.
class PollinationsTtsProvider extends TtsProvider {
  final TtsHttp http;
  const PollinationsTtsProvider(this.http);

  static const _fallbackVoices = [
    'alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer',
  ];

  @override
  String get id => 'pollinations';

  @override
  String get displayName => 'Pollinations';

  @override
  String get description => 'Pollinations OpenAI-audio models.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.text('model', 'Model', defaultValue: 'openai-audio'),
    TtsField.text(
      'voices',
      'Voices',
      defaultValue: 'alloy, echo, fable, onyx, nova, shimmer',
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final key = config.str('apiKey');
    if (key.isNotEmpty) {
      try {
        final json = await http.getJson(
          'https://gen.pollinations.ai/text/models',
        );
        if (json is List) {
          for (final m in json) {
            if (m is Map &&
                (m['name'] == config.str('model') ||
                    (m['aliases'] is List &&
                        (m['aliases'] as List).contains(config.str('model')))) &&
                m['voices'] is List) {
              return [
                for (final v in m['voices'] as List)
                  TtsVoice(name: v.toString(), voiceId: v.toString()),
              ];
            }
          }
        }
      } catch (_) {
        // Fall through to the manual list.
      }
    }
    final manual = parseVoiceList(config.str('voices'));
    return manual.isEmpty
        ? [for (final v in _fallbackVoices) TtsVoice(name: v, voiceId: v)]
        : manual;
  }

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
    final json = await http.postJson(
      'https://gen.pollinations.ai/v1/chat/completions',
      headers: {'Authorization': 'Bearer ${config.require('apiKey')}'},
      body: {
        'model': config.str('model'),
        'stream': false,
        'modalities': ['text', 'audio'],
        'audio': {'format': 'mp3', 'voice': voiceId},
        'messages': [
          {
            'role': 'user',
            'content': text,
          },
        ],
      },
      cancelToken: cancelToken,
    );
    final data = _audioData(json);
    if (data == null) throw const TtsException('Pollinations returned no audio');
    return TtsAudio(Uint8List.fromList(base64Decode(data)), 'audio/mpeg');
  }

  static String? _audioData(Object? json) {
    if (json is! Map) return null;
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final message = first['message'];
    final audio = message is Map ? message['audio'] : null;
    final data = audio is Map ? audio['data'] : null;
    return data is String ? data : null;
  }
}
