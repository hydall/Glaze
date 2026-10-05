import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// MiniMax speech. The API answers with hex-encoded audio inside a JSON
/// envelope, which is decoded here.
///
/// The service publishes no voice catalogue, so the default voice and any
/// custom ids typed in are the whole list.
class MiniMaxTtsProvider extends TtsProvider {
  final TtsHttp http;
  const MiniMaxTtsProvider(this.http);

  static final _defaultVoice = TtsVoice(
    name: 'Unrestrained Young Man',
    voiceId: 'Chinese (Mandarin)_Unrestrained_Young_Man',
    lang: 'zh-CN',
  );

  @override
  String get id => 'minimax';

  @override
  String get displayName => 'MiniMax';

  @override
  String get description => 'MiniMax speech models.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.select(
      'apiHost',
      'API host',
      defaultValue: 'https://api.minimax.io',
      options: [
        TtsFieldOption('https://api.minimax.io', 'Official'),
        TtsFieldOption('https://api.minimaxi.chat', 'Global (minimaxi.chat)'),
        TtsFieldOption('https://api.minimax.chat', 'Mainland China'),
      ],
    ),
    TtsField.select(
      'model',
      'Model',
      defaultValue: 'speech-02-hd',
      options: [
        TtsFieldOption('speech-02-hd', 'Speech-02-HD (quality)'),
        TtsFieldOption('speech-02-turbo', 'Speech-02-Turbo (fast)'),
        TtsFieldOption('speech-01', 'Speech-01 (legacy)'),
        TtsFieldOption('speech-01-240228', 'Speech-01-240228 (legacy)'),
      ],
    ),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.5,
      max: 2,
      step: 0.1,
    ),
    TtsField.number(
      'volume',
      'Volume',
      defaultValue: 1,
      min: 0,
      max: 10,
      step: 0.1,
    ),
    TtsField.number(
      'pitch',
      'Pitch',
      defaultValue: 0,
      min: -12,
      max: 12,
      step: 1,
    ),
    TtsField.select(
      'format',
      'Format',
      defaultValue: 'mp3',
      options: [
        TtsFieldOption('mp3'),
        TtsFieldOption('wav'),
        TtsFieldOption('flac'),
      ],
    ),
    TtsField.text(
      'voices',
      'Extra voices',
      hint: 'Name:voiceId pairs, comma-separated',
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async => [
    _defaultVoice,
    ...parseVoiceList(config.str('voices')),
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
    final format = config.str('format');
    final json = await http.postJson(
      '${config.str('apiHost')}/v1/t2a_v2',
      headers: {
        'Authorization': 'Bearer ${config.require('apiKey')}',
        'MM-API-Source': 'Glaze-TTS',
      },
      body: {
        'model': config.str('model'),
        'text': text,
        'stream': false,
        'voice_setting': {
          'voice_id': voiceId,
          'speed': config.number('speed'),
          'vol': config.number('volume'),
          'pitch': config.number('pitch'),
        },
        'audio_setting': {
          'sample_rate': 32000,
          'bitrate': 128000,
          'format': format,
          'channel': 1,
        },
      },
      cancelToken: cancelToken,
    );
    if (json is! Map) throw const TtsException('Unexpected MiniMax response');
    final base = json['base_resp'];
    if (base is Map && base['status_code'] != 0) {
      throw TtsException('MiniMax: ${base['status_msg'] ?? 'request failed'}');
    }
    final data = json['data'];
    final hex = data is Map ? data['audio'] : null;
    if (hex is! String || hex.isEmpty) {
      throw const TtsException('MiniMax returned no audio');
    }
    return TtsAudio(_fromHex(hex), _mime(format));
  }

  static String _mime(String format) => switch (format) {
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    _ => 'audio/mpeg',
  };

  static Uint8List _fromHex(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    final padded = clean.length.isOdd ? '0$clean' : clean;
    final out = Uint8List(padded.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
