import 'dart:typed_data';

/// One voice a provider can speak with.
class TtsVoice {
  /// Name shown to the user and stored in the voice map.
  final String name;

  /// Provider-specific id sent with the synthesis request.
  final String voiceId;
  final String? lang;

  /// Sample clip, when the provider publishes one.
  final String? previewUrl;

  const TtsVoice({
    required this.name,
    required this.voiceId,
    this.lang,
    this.previewUrl,
  });
}

/// Synthesised audio as returned by a provider.
class TtsAudio {
  final Uint8List bytes;

  /// `audio/wav`, `audio/mpeg`, `audio/ogg`, `audio/pcm;rate=24000`…
  final String mime;

  const TtsAudio(this.bytes, this.mime);

  /// File extension used for the cached copy.
  String get extension {
    final m = mime.toLowerCase();
    if (m.contains('wav') || m.contains('wave') || m.contains('pcm')) {
      return 'wav';
    }
    if (m.contains('mpeg') || m.contains('mp3')) return 'mp3';
    if (m.contains('ogg') || m.contains('opus')) return 'ogg';
    if (m.contains('webm')) return 'webm';
    if (m.contains('flac')) return 'flac';
    if (m.contains('aac') || m.contains('mp4') || m.contains('m4a')) {
      return 'm4a';
    }
    return 'bin';
  }
}

/// Raised for a configuration problem the user has to fix (missing key,
/// missing server address). Shown as-is.
class TtsNotConfigured implements Exception {
  final String message;
  const TtsNotConfigured(this.message);
  @override
  String toString() => message;
}

/// Raised when a provider call fails.
class TtsException implements Exception {
  final String message;
  const TtsException(this.message);
  @override
  String toString() => message;
}

enum TtsFieldKind { text, secret, multiline, number, select, toggle }

class TtsFieldOption {
  final String value;
  final String label;
  const TtsFieldOption(this.value, [String? label]) : label = label ?? value;
}

/// Declarative description of one provider setting. The settings screen
/// draws a row per field, so a provider never ships its own UI.
class TtsField {
  final String key;

  /// Plain label. Provider labels are proper nouns and API terms ("Model",
  /// "Stability"), so they are not localized.
  final String label;
  final TtsFieldKind kind;
  final Object? defaultValue;
  final String? hint;
  final List<TtsFieldOption> options;
  final double min;
  final double max;
  final double step;

  /// False for settings that do not change the produced audio (keys,
  /// timeouts). Only audio-affecting values go into the cache key.
  final bool affectsAudio;

  const TtsField.text(
    this.key,
    this.label, {
    String this.defaultValue = '',
    this.hint,
    this.affectsAudio = true,
  }) : kind = TtsFieldKind.text,
       options = const [],
       min = 0,
       max = 0,
       step = 0;

  const TtsField.secret(this.key, this.label, {this.hint})
    : kind = TtsFieldKind.secret,
      defaultValue = '',
      options = const [],
      min = 0,
      max = 0,
      step = 0,
      affectsAudio = false;

  /// A server address. Changing it does not change the voice, so it is kept
  /// out of the cache key.
  const TtsField.url(this.key, this.label, {String this.defaultValue = ''})
    : kind = TtsFieldKind.text,
      hint = null,
      options = const [],
      min = 0,
      max = 0,
      step = 0,
      affectsAudio = false;

  const TtsField.multiline(
    this.key,
    this.label, {
    String this.defaultValue = '',
    this.hint,
    this.affectsAudio = true,
  }) : kind = TtsFieldKind.multiline,
       options = const [],
       min = 0,
       max = 0,
       step = 0;

  const TtsField.number(
    this.key,
    this.label, {
    required double this.defaultValue,
    required this.min,
    required this.max,
    required this.step,
    this.hint,
  }) : kind = TtsFieldKind.number,
       options = const [],
       affectsAudio = true;

  const TtsField.select(
    this.key,
    this.label, {
    required String this.defaultValue,
    required this.options,
    this.hint,
  }) : kind = TtsFieldKind.select,
       min = 0,
       max = 0,
       step = 0,
       affectsAudio = true;

  const TtsField.toggle(
    this.key,
    this.label, {
    required bool this.defaultValue,
    this.hint,
  }) : kind = TtsFieldKind.toggle,
       options = const [],
       min = 0,
       max = 0,
       step = 0,
       affectsAudio = true;
}

/// A provider's stored values read through its field declarations, so every
/// lookup falls back to the declared default.
class TtsProviderConfig {
  final Map<String, dynamic> values;
  final List<TtsField> fields;

  const TtsProviderConfig(this.values, this.fields);

  Object? _raw(String key) {
    final v = values[key];
    if (v != null) return v;
    for (final f in fields) {
      if (f.key == key) return f.defaultValue;
    }
    return null;
  }

  String str(String key) {
    final v = _raw(key);
    return v == null ? '' : v.toString().trim();
  }

  double number(String key) {
    final v = _raw(key);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  bool flag(String key) {
    final v = _raw(key);
    if (v is bool) return v;
    return v == 'true';
  }

  /// Audio-affecting values in a stable order, for the cache key.
  String audioFingerprint() {
    final parts = <String>[];
    for (final f in fields) {
      if (!f.affectsAudio) continue;
      parts.add('${f.key}=${_raw(f.key)}');
    }
    return parts.join('&');
  }

  /// Required value or a [TtsNotConfigured] naming the field.
  String require(String key) {
    final v = str(key);
    if (v.isNotEmpty) return v;
    final label = fields
        .firstWhere(
          (f) => f.key == key,
          orElse: () => TtsField.text(key, key),
        )
        .label;
    throw TtsNotConfigured('$label is not set');
  }
}
