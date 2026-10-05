import '../models/tts_settings.dart';
import '../models/tts_types.dart';
import '../providers/tts_provider.dart';
import 'tts_text_preparer.dart';

/// Voice-map key for a segment of [speakerKey] when several voices are on.
String ttsSegmentKey(String speakerKey, TtsSegmentType type) =>
    '$speakerKey#${type.name}';

/// Voice-map key of the chat character.
String ttsCharKey(String charId) => 'char:$charId';

/// Voice-map key of a user persona; null means the default persona.
String ttsUserKey(String? personaId) =>
    personaId == null || personaId.isEmpty ? 'user' : 'user:$personaId';

/// Outcome of looking a speaker up in the voice map.
sealed class TtsVoiceChoice {
  const TtsVoiceChoice();
}

class TtsVoiceDisabled extends TtsVoiceChoice {
  const TtsVoiceDisabled();
}

class TtsVoiceResolved extends TtsVoiceChoice {
  final TtsVoice voice;
  const TtsVoiceResolved(this.voice);
}

/// Keeps each provider's voice list in memory so drawing a chat full of
/// pills does not refetch it per message.
class TtsVoiceCatalog {
  final Map<String, Future<List<TtsVoice>>> _lists = {};

  Future<List<TtsVoice>> voicesFor(
    TtsProvider provider,
    TtsProviderConfig config,
  ) {
    final key = '${provider.id}|${config.values}';
    final existing = _lists[key];
    if (existing != null) return existing;
    final future = provider.fetchVoices(config);
    _lists[key] = future;
    // A failed fetch (no key yet, server down) must not stick.
    future.catchError((Object _) {
      _lists.remove(key);
      return const <TtsVoice>[];
    });
    return future;
  }

  void invalidate() => _lists.clear();
}

/// Turns a speaker and segment type into a voice, following SillyTavern's
/// rules: a specific entry wins, "[Default Voice]" or a missing entry falls
/// back to the default entry, "disabled" silences the speaker. When even the
/// default is unset, the provider's first voice speaks so a fresh setup
/// works without filling in the map first.
class TtsVoiceResolver {
  final TtsVoiceCatalog catalog;
  TtsVoiceResolver(this.catalog);

  Future<TtsVoiceChoice> resolve({
    required TtsProvider provider,
    required TtsProviderConfig config,
    required Map<String, String> voiceMap,
    required String speakerKey,
    required TtsSegmentType type,
    required bool multiVoice,
  }) async {
    final key = multiVoice ? ttsSegmentKey(speakerKey, type) : speakerKey;
    var value = voiceMap[key];
    // A multi-voice slot left empty inherits the speaker's single voice.
    if (multiVoice && (value == null || value.isEmpty)) {
      value = voiceMap[speakerKey];
    }
    if (value == ttsDisabledVoiceMarker) return const TtsVoiceDisabled();
    if (value == null || value.isEmpty || value == ttsDefaultVoiceMarker) {
      value = voiceMap[ttsDefaultVoiceKey];
      if (value == ttsDisabledVoiceMarker) return const TtsVoiceDisabled();
    }
    final voices = await catalog.voicesFor(provider, config);
    if (voices.isEmpty) {
      throw TtsNotConfigured('${provider.displayName}: no voices available');
    }
    if (value == null || value.isEmpty || value == ttsDefaultVoiceMarker) {
      return TtsVoiceResolved(voices.first);
    }
    for (final v in voices) {
      if (v.name == value) return TtsVoiceResolved(v);
    }
    for (final v in voices) {
      if (v.voiceId == value) return TtsVoiceResolved(v);
    }
    throw TtsNotConfigured('Voice "$value" not found in ${provider.displayName}');
  }
}
