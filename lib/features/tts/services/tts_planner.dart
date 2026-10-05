import '../models/tts_settings.dart';
import '../models/tts_types.dart';
import '../providers/tts_provider.dart';
import 'tts_audio_cache.dart';
import 'tts_text_preparer.dart';
import 'tts_voice_resolver.dart';

/// A message as the TTS engine sees it.
class TtsMessageInput {
  final String messageId;

  /// Text with macros already expanded.
  final String text;

  /// Voice-map key of whoever wrote the message ([ttsCharKey] /
  /// [ttsUserKey]).
  final String speakerKey;

  const TtsMessageInput({
    required this.messageId,
    required this.text,
    required this.speakerKey,
  });
}

/// One clip to synthesise.
class TtsClipPlan {
  final String text;
  final String voiceId;
  final String speakerKey;

  /// Cache key; see [ttsClipKey].
  final String key;

  const TtsClipPlan({
    required this.text,
    required this.voiceId,
    required this.speakerKey,
    required this.key,
  });
}

class TtsMessagePlan {
  final String messageId;
  final TtsProvider provider;
  final TtsProviderConfig config;
  final List<TtsClipPlan> clips;

  const TtsMessagePlan({
    required this.messageId,
    required this.provider,
    required this.config,
    required this.clips,
  });

  /// Identity of the planned audio — changes whenever any clip would.
  String get signature => clips.map((c) => c.key).join(',');
}

/// Builds the clip list for a message: clean the text, cut it into
/// segments, pick a voice for each and derive the cache keys.
class TtsPlanner {
  final TtsVoiceResolver resolver;
  TtsPlanner(this.resolver);

  /// Null when nothing would be spoken (empty text, every voice disabled).
  Future<TtsMessagePlan?> plan(
    TtsMessageInput input,
    TtsSettings settings,
    TtsProvider provider, {
    bool forceParagraphs = false,
  }) async {
    final config = provider.configFrom(settings.settingsFor(provider.id));
    final segments = TtsTextPreparer.prepare(
      input.text,
      TtsTextOptions.fromSettings(
        settings,
        separator: provider.separator,
        forceParagraphs: forceParagraphs,
      ),
      processText: provider.processText,
    );
    if (segments.isEmpty) return null;
    final voiceMap = settings.voiceMapFor(provider.id);
    final fingerprint = config.audioFingerprint();
    final clips = <TtsClipPlan>[];
    for (final segment in segments) {
      final choice = await resolver.resolve(
        provider: provider,
        config: config,
        voiceMap: voiceMap,
        speakerKey: input.speakerKey,
        type: segment.type,
        multiVoice: settings.multiVoice,
      );
      if (choice is! TtsVoiceResolved) continue;
      final voiceId = choice.voice.voiceId;
      final speakerKey = settings.multiVoice
          ? ttsSegmentKey(input.speakerKey, segment.type)
          : input.speakerKey;
      final extra = provider.perSpeakerValue(config, speakerKey);
      clips.add(
        TtsClipPlan(
          text: segment.text,
          voiceId: voiceId,
          speakerKey: speakerKey,
          key: ttsClipKey(
            providerId: provider.id,
            voiceId: voiceId,
            settingsFingerprint: extra.isEmpty
                ? fingerprint
                : '$fingerprint&speaker=$extra',
            text: segment.text,
          ),
        ),
      );
    }
    if (clips.isEmpty) return null;
    return TtsMessagePlan(
      messageId: input.messageId,
      provider: provider,
      config: config,
      clips: clips,
    );
  }
}
