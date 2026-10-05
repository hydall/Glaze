import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Fish Audio, driven by a hosted voice model's id — the id in a
/// `fish.audio/m/<id>` link. Nothing to train or download, which makes it
/// the shortest path to a character voice.
///
/// WAV is requested: its header carries the sample rate, so duration and
/// waveform always match the audio.
///
/// A cloned voice speaks with the accent of its source recording, so a
/// language → voice list can override the voice per message language
/// (detected from the script of the text).
class FishAudioTtsProvider extends TtsProvider {
  final TtsHttp http;
  const FishAudioTtsProvider(this.http);

  static const _base = 'https://api.fish.audio';

  @override
  String get id => 'fish';

  @override
  String get displayName => 'Fish Audio';

  @override
  String get description =>
      'Hosted voice models from fish.audio, addressed by their model id.';

  @override
  List<TtsField> get fields => const [
    TtsField.secret('apiKey', 'API key'),
    TtsField.text(
      'model',
      'Model',
      defaultValue: 's2.1-pro',
      hint: 's2.1-pro, s1, speech-1.6…',
    ),
    TtsField.multiline(
      'voices',
      'Voices',
      hint: 'Name:model id pairs, comma-separated. Your own models load too.',
    ),
    TtsField.multiline(
      'languageVoices',
      'Voice per language',
      hint: 'e.g. ru:<model id>, en:<model id>',
    ),
    TtsField.select(
      'latency',
      'Latency',
      defaultValue: 'normal',
      options: [TtsFieldOption('normal'), TtsFieldOption('balanced')],
    ),
    TtsField.select(
      'sampleRate',
      'Sample rate',
      defaultValue: '44100',
      options: [
        TtsFieldOption('16000'),
        TtsFieldOption('24000'),
        TtsFieldOption('44100'),
        TtsFieldOption('48000'),
      ],
    ),
    TtsField.number(
      'speed',
      'Speed',
      defaultValue: 1,
      min: 0.5,
      max: 2,
      step: 0.05,
    ),
  ];

  Map<String, String> _auth(TtsProviderConfig config) => {
    'Authorization': 'Bearer ${config.require('apiKey')}',
  };

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async {
    final manual = parseVoiceList(config.str('voices'));
    final own = <TtsVoice>[];
    if (config.str('apiKey').isNotEmpty) {
      try {
        final json = await http.getJson(
          '$_base/model',
          headers: _auth(config),
          query: {'self': 'true', 'page_size': 100},
        );
        final items = json is Map ? json['items'] : null;
        if (items is List) {
          for (final m in items) {
            if (m is! Map || m['_id'] is! String) continue;
            final langs = m['languages'];
            own.add(
              TtsVoice(
                name: (m['title'] as String?)?.trim().isNotEmpty == true
                    ? m['title'] as String
                    : m['_id'] as String,
                voiceId: m['_id'] as String,
                lang: langs is List && langs.isNotEmpty
                    ? langs.join(', ')
                    : null,
              ),
            );
          }
        }
      } catch (_) {
        // Manual voices still work when the listing call fails.
        if (manual.isEmpty) rethrow;
      }
    }
    final names = manual.map((v) => v.name).toSet();
    return [...manual, ...own.where((v) => !names.contains(v.name))];
  }

  @override
  Future<void> checkReady(TtsProviderConfig config) async {
    config.require('apiKey');
    if ((await fetchVoices(config)).isEmpty) {
      throw const TtsNotConfigured(
        'Add a voice: the model id from its fish.audio link',
      );
    }
  }

  /// The language → voice override for [text], if one is configured.
  static String voiceFor(String text, String voiceId, String languageVoices) {
    final map = {
      for (final v in parseVoiceList(languageVoices)) v.name.toLowerCase(): v.voiceId,
    };
    if (map.isEmpty) return voiceId;
    return map[detectLanguage(text)] ?? voiceId;
  }

  /// Rough language of [text] from the script most of its letters use.
  static String detectLanguage(String text) {
    var cyrillic = 0, latin = 0, kana = 0, han = 0, hangul = 0;
    for (final r in text.runes) {
      if (r >= 0x0400 && r <= 0x04FF) {
        cyrillic++;
      } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) ||
          (r >= 0xC0 && r <= 0x24F)) {
        latin++;
      } else if (r >= 0x3040 && r <= 0x30FF) {
        kana++;
      } else if (r >= 0x4E00 && r <= 0x9FFF) {
        han++;
      } else if (r >= 0xAC00 && r <= 0xD7AF) {
        hangul++;
      }
    }
    final best = [
      ('ru', cyrillic),
      ('en', latin),
      ('ja', kana),
      ('zh', han),
      ('ko', hangul),
    ].reduce((a, b) => b.$2 > a.$2 ? b : a);
    // Kanji next to kana is Japanese, not Chinese.
    if (best.$1 == 'zh' && kana > 0) return 'ja';
    return best.$2 == 0 ? 'en' : best.$1;
  }

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) {
    return http.postForAudio(
      '$_base/v1/tts',
      headers: {..._auth(config), 'model': config.str('model')},
      body: {
        'text': text,
        'reference_id': voiceFor(text, voiceId, config.str('languageVoices')),
        'format': 'wav',
        'sample_rate': int.tryParse(config.str('sampleRate')) ?? 44100,
        'latency': config.str('latency'),
        if (config.number('speed') != 1)
          'prosody': {'speed': config.number('speed'), 'volume': 0},
      },
      mime: 'audio/wav',
      cancelToken: cancelToken,
    );
  }
}
