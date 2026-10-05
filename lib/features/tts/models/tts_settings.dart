import 'package:freezed_annotation/freezed_annotation.dart';

part 'tts_settings.freezed.dart';

/// Voice-map value meaning "use whatever the default entry points at".
const String ttsDefaultVoiceMarker = '[Default Voice]';

/// Voice-map value meaning "never speak this speaker".
const String ttsDisabledVoiceMarker = 'disabled';

/// Voice-map key of the fallback voice.
const String ttsDefaultVoiceKey = '[Default Voice]';

/// User-facing TTS settings, persisted as one JSON blob (see
/// [TtsSettingsCodec]).
///
/// Provider-specific values live in [providerSettings] keyed by provider id,
/// and the speaker → voice assignments in [voiceMaps], also per provider —
/// the same split SillyTavern uses, so switching providers keeps each one's
/// configuration intact.
@freezed
abstract class TtsSettings with _$TtsSettings {
  const factory TtsSettings({
    @Default(false) bool enabled,
    @Default('openai') String providerId,

    /// Speak new replies on their own once they are final.
    @Default(true) bool autoGeneration,

    /// Speak a reply paragraph by paragraph while it is still streaming.
    @Default(false) bool narrateWhileStreaming,

    /// Split a message into one clip per paragraph.
    @Default(false) bool narrateByParagraphs,
    @Default(false) bool narrateUser,

    /// Keep only the text inside quotes.
    @Default(false) bool narrateQuotedOnly,

    /// Drop `*...*` passages entirely instead of only their asterisks.
    @Default(false) bool ignoreAsterisks,

    /// Leave asterisks in the text sent to the provider.
    @Default(false) bool passAsterisks,
    @Default(true) bool skipCodeblocks,
    @Default(true) bool skipTags,

    /// Separate voices for quotes, `*actions*` and the rest of the text.
    @Default(false) bool multiVoice,
    @Default(false) bool applyRegex,
    @Default('') String regexPattern,
    @Default(1.0) double playbackRate,

    /// Keep generated audio on disk and reuse it while the message text and
    /// voice stay the same.
    @Default(true) bool cacheEnabled,

    /// providerId → field key → value.
    @Default({}) Map<String, Map<String, dynamic>> providerSettings,

    /// providerId → speaker key → voice name (or a marker).
    @Default({}) Map<String, Map<String, String>> voiceMaps,
  }) = _TtsSettings;
}

extension TtsSettingsAccess on TtsSettings {
  Map<String, dynamic> settingsFor(String providerId) =>
      providerSettings[providerId] ?? const {};

  Map<String, String> voiceMapFor(String providerId) =>
      voiceMaps[providerId] ?? const {};

  TtsSettings withProviderValue(String providerId, String key, Object? value) {
    final current = Map<String, dynamic>.of(settingsFor(providerId));
    if (value == null) {
      current.remove(key);
    } else {
      current[key] = value;
    }
    return copyWith(
      providerSettings: {...providerSettings, providerId: current},
    );
  }

  TtsSettings withVoice(String providerId, String speakerKey, String? voice) {
    final current = Map<String, String>.of(voiceMapFor(providerId));
    if (voice == null || voice.isEmpty) {
      current.remove(speakerKey);
    } else {
      current[speakerKey] = voice;
    }
    return copyWith(voiceMaps: {...voiceMaps, providerId: current});
  }
}

/// JSON (de)serialization for [TtsSettings]. Unknown or malformed values fall
/// back to the defaults rather than failing the whole blob.
class TtsSettingsCodec {
  const TtsSettingsCodec._();

  static Map<String, dynamic> toJson(TtsSettings s) => {
    'enabled': s.enabled,
    'providerId': s.providerId,
    'autoGeneration': s.autoGeneration,
    'narrateWhileStreaming': s.narrateWhileStreaming,
    'narrateByParagraphs': s.narrateByParagraphs,
    'narrateUser': s.narrateUser,
    'narrateQuotedOnly': s.narrateQuotedOnly,
    'ignoreAsterisks': s.ignoreAsterisks,
    'passAsterisks': s.passAsterisks,
    'skipCodeblocks': s.skipCodeblocks,
    'skipTags': s.skipTags,
    'multiVoice': s.multiVoice,
    'applyRegex': s.applyRegex,
    'regexPattern': s.regexPattern,
    'playbackRate': s.playbackRate,
    'cacheEnabled': s.cacheEnabled,
    'providerSettings': s.providerSettings,
    'voiceMaps': s.voiceMaps,
  };

  static TtsSettings fromJson(Map<String, dynamic> m) {
    const d = TtsSettings();
    return TtsSettings(
      enabled: _bool(m['enabled'], d.enabled),
      providerId: m['providerId'] is String
          ? m['providerId'] as String
          : d.providerId,
      autoGeneration: _bool(m['autoGeneration'], d.autoGeneration),
      narrateWhileStreaming: _bool(
        m['narrateWhileStreaming'],
        d.narrateWhileStreaming,
      ),
      narrateByParagraphs: _bool(
        m['narrateByParagraphs'],
        d.narrateByParagraphs,
      ),
      narrateUser: _bool(m['narrateUser'], d.narrateUser),
      narrateQuotedOnly: _bool(m['narrateQuotedOnly'], d.narrateQuotedOnly),
      ignoreAsterisks: _bool(m['ignoreAsterisks'], d.ignoreAsterisks),
      passAsterisks: _bool(m['passAsterisks'], d.passAsterisks),
      skipCodeblocks: _bool(m['skipCodeblocks'], d.skipCodeblocks),
      skipTags: _bool(m['skipTags'], d.skipTags),
      multiVoice: _bool(m['multiVoice'], d.multiVoice),
      applyRegex: _bool(m['applyRegex'], d.applyRegex),
      regexPattern: m['regexPattern'] is String
          ? m['regexPattern'] as String
          : d.regexPattern,
      playbackRate: m['playbackRate'] is num
          ? (m['playbackRate'] as num).toDouble().clamp(0.5, 2.0)
          : d.playbackRate,
      cacheEnabled: _bool(m['cacheEnabled'], d.cacheEnabled),
      providerSettings: _providerSettings(m['providerSettings']),
      voiceMaps: _voiceMaps(m['voiceMaps']),
    );
  }

  static bool _bool(Object? v, bool fallback) {
    if (v is bool) return v;
    if (v == 'true') return true;
    if (v == 'false') return false;
    return fallback;
  }

  static Map<String, Map<String, dynamic>> _providerSettings(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, Map<String, dynamic>>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (entry.key is! String || value is! Map) continue;
      out[entry.key as String] = Map<String, dynamic>.from(value);
    }
    return out;
  }

  static Map<String, Map<String, String>> _voiceMaps(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, Map<String, String>>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (entry.key is! String || value is! Map) continue;
      out[entry.key as String] = {
        for (final v in value.entries)
          if (v.key is String && v.value is String)
            v.key as String: v.value as String,
      };
    }
    return out;
  }
}
