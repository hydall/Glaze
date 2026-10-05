import 'package:dio/dio.dart';

import '../models/tts_types.dart';
import '../services/tts_http.dart';
import 'tts_provider.dart';

/// Google Translate's unofficial speech endpoint. No key, no setup, one
/// voice per language — the pragmatic fallback.
///
/// A request is capped at roughly 200 characters, so longer text is broken
/// up and the returned clips are joined into one WAV-less MP3 list is not
/// possible here; each segment is requested as its own clip by the engine's
/// paragraph handling instead.
class GoogleTranslateTtsProvider extends TtsProvider {
  final TtsHttp http;
  const GoogleTranslateTtsProvider(this.http);

  /// Language codes Google Translate accepts, with display names.
  static const languages = <String, String>{
    'af': 'Afrikaans', 'ar': 'Arabic', 'bg': 'Bulgarian', 'bn': 'Bengali',
    'ca': 'Catalan', 'cs': 'Czech', 'cy': 'Welsh', 'da': 'Danish',
    'de': 'German', 'el': 'Greek', 'en': 'English', 'eo': 'Esperanto',
    'es': 'Spanish', 'et': 'Estonian', 'fa': 'Persian', 'fi': 'Finnish',
    'fr': 'French', 'gu': 'Gujarati', 'he': 'Hebrew', 'hi': 'Hindi',
    'hr': 'Croatian', 'hu': 'Hungarian', 'id': 'Indonesian', 'is': 'Icelandic',
    'it': 'Italian', 'ja': 'Japanese', 'kn': 'Kannada', 'ko': 'Korean',
    'la': 'Latin', 'lv': 'Latvian', 'lt': 'Lithuanian', 'ml': 'Malayalam',
    'mr': 'Marathi', 'ms': 'Malay', 'nl': 'Dutch', 'no': 'Norwegian',
    'pl': 'Polish', 'pt': 'Portuguese', 'ro': 'Romanian', 'ru': 'Russian',
    'sk': 'Slovak', 'sl': 'Slovenian', 'sr': 'Serbian', 'sv': 'Swedish',
    'sw': 'Swahili', 'ta': 'Tamil', 'te': 'Telugu', 'th': 'Thai',
    'tl': 'Filipino', 'tr': 'Turkish', 'uk': 'Ukrainian', 'ur': 'Urdu',
    'vi': 'Vietnamese', 'zh-CN': 'Chinese (Simplified)',
    'zh-TW': 'Chinese (Traditional)',
  };

  /// Google returns a hard limit; keep comfortably under it.
  static const maxChunkLength = 190;

  @override
  String get id => 'google_translate';

  @override
  String get displayName => 'Google Translate';

  @override
  String get description => 'The free translation voice. No key required.';

  static final _languageOptions = [
    for (final e in languages.entries) TtsFieldOption(e.key, e.value),
  ];

  @override
  List<TtsField> get fields => [
    TtsField.select(
      'language',
      'Language',
      defaultValue: 'en',
      options: _languageOptions,
    ),
  ];

  @override
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config) async => [
    for (final e in languages.entries)
      TtsVoice(name: e.value, voiceId: e.key, lang: e.key),
  ];

  @override
  String processText(String text) => _chunkText(text, maxChunkLength);

  @override
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  }) {
    return http.getForAudio(
      'https://translate.google.com/translate_tts',
      query: {
        'ie': 'UTF-8',
        'q': text,
        'tl': voiceId.isEmpty ? config.str('language') : voiceId,
        'client': 'tw-ob',
      },
      headers: {
        // Required by Google for the request to be accepted.
        'Referer': 'https://translate.google.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
      mime: 'audio/mpeg',
      cancelToken: cancelToken,
    );
  }

  /// Splits [text] on sentence boundaries within [limit] characters.
  static String _chunkText(String text, int limit) {
    if (text.length <= limit) return text;
    final sentences = text.split(RegExp(r'(?<=[.!?…])\s+'));
    final out = <String>[];
    var current = '';
    for (final sentence in sentences) {
      if (current.isNotEmpty && current.length + sentence.length + 1 > limit) {
        out.add(current);
        current = '';
      }
      current = current.isEmpty ? sentence : '$current $sentence';
    }
    if (current.isNotEmpty) out.add(current);
    return out.join(' ');
  }
}
