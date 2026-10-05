import 'package:dio/dio.dart';

import '../models/tts_types.dart';

/// Contract every speech service implements — a Dart take on SillyTavern's
/// TTS provider interface. The engine never knows which service it talks to:
/// it reads the voice list, resolves a voice and asks for audio.
///
/// Providers are stateless; every call receives the stored configuration, so
/// one instance serves the settings screen and the chat at the same time.
abstract class TtsProvider {
  const TtsProvider();

  /// Stable id, used as the storage key for settings and voice maps.
  String get id;

  String get displayName;

  /// Short description shown above the provider's settings.
  String get description => '';

  /// True for services that run on the user's own machine.
  bool get isLocal => false;

  List<TtsField> get fields;

  /// An extra setting kept per speaker (OpenAI's voice instructions). Its
  /// values are stored under `<key>:<speakerKey>` in the provider settings
  /// and are part of the clip's cache key.
  TtsField? get perSpeakerField => null;

  /// Inserted between quoted passages when "quotes only" joins them, so the
  /// voice pauses between lines.
  String get separator => ' ... ';

  /// False when the provider speaks straight to the speakers and produces no
  /// audio file (OS voices on desktop). Such clips have no duration, waveform
  /// or cache.
  bool get producesAudio => true;

  /// Available voices.
  Future<List<TtsVoice>> fetchVoices(TtsProviderConfig config);

  /// Synthesises [text] with [voiceId].
  ///
  /// [speakerKey] is the voice-map key the clip was resolved from, for
  /// providers that keep per-speaker extras (OpenAI's voice instructions).
  Future<TtsAudio> generate(
    String text,
    String voiceId,
    TtsProviderConfig config, {
    String? speakerKey,
    CancelToken? cancelToken,
  });

  /// Throws [TtsNotConfigured] when the provider cannot be used as
  /// configured. The default only checks that the voice list loads.
  Future<void> checkReady(TtsProviderConfig config) async {
    await fetchVoices(config);
  }

  /// Provider-specific text clean-up, applied after the shared one.
  String processText(String text) => text;

  /// Speaks [text] directly. Only used by providers with
  /// [producesAudio] == false.
  Future<void> speak(
    String text,
    String voiceId,
    TtsProviderConfig config,
  ) async {
    throw UnsupportedError('$displayName does not speak directly');
  }

  /// Stops direct speech started by [speak].
  Future<void> stopSpeaking() async {}

  /// Resolves a voice-map value (a voice name or a raw id) to a voice.
  Future<TtsVoice?> resolveVoice(
    String nameOrId,
    TtsProviderConfig config,
  ) async {
    final voices = await fetchVoices(config);
    for (final v in voices) {
      if (v.name == nameOrId) return v;
    }
    for (final v in voices) {
      if (v.voiceId == nameOrId) return v;
    }
    return null;
  }

  /// The [perSpeakerField] value for [speakerKey], or ''.
  String perSpeakerValue(TtsProviderConfig config, String? speakerKey) {
    final field = perSpeakerField;
    if (field == null || speakerKey == null) return '';
    final v = config.values['${field.key}:$speakerKey'];
    return v is String ? v.trim() : '';
  }

  TtsProviderConfig configFrom(Map<String, dynamic> values) =>
      TtsProviderConfig(values, fields);
}

/// Turns a voice listing that is a plain list of names (or an object whose
/// keys are names) into voices. Local servers answer in this shape.
List<TtsVoice> voicesFromNames(Object? json) {
  if (json is List) {
    return [
      for (final v in json)
        if (v is String) TtsVoice(name: v, voiceId: v),
    ];
  }
  if (json is Map) {
    return [
      for (final k in json.keys) TtsVoice(name: k.toString(), voiceId: k.toString()),
    ];
  }
  return const [];
}

/// Parses a "Name:id, Name2:id2" or "id1, id2" list typed into a settings
/// field into voices. Used by every provider whose voices are user-entered.
List<TtsVoice> parseVoiceList(String raw, {String? lang}) {
  final voices = <TtsVoice>[];
  final seen = <String>{};
  for (final part in raw.split(RegExp(r'[,\n]'))) {
    final item = part.trim();
    if (item.isEmpty) continue;
    final colon = item.indexOf(':');
    // "http://..." style ids keep their colon.
    final hasName = colon > 0 && !item.substring(colon).startsWith('://');
    final name = hasName ? item.substring(0, colon).trim() : item;
    final id = hasName ? item.substring(colon + 1).trim() : item;
    if (name.isEmpty || id.isEmpty || !seen.add(name)) continue;
    voices.add(TtsVoice(name: name, voiceId: id, lang: lang));
  }
  return voices;
}
