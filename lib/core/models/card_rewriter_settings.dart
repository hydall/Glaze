import 'package:freezed_annotation/freezed_annotation.dart';

part 'card_rewriter_settings.freezed.dart';
part 'card_rewriter_settings.g.dart';

/// Global Studio settings for the review-only Card Rewriter automation lane.
///
/// A dedicated API preset is mandatory: the writer never falls back to the
/// active chat model. An empty model override uses the chosen preset's model.
/// Lorebook evolution is independently optional to avoid its second model call.
@freezed
abstract class CardRewriterSettings with _$CardRewriterSettings {
  const factory CardRewriterSettings({
    @Default(false) bool enabled,
    @Default(true) bool lorebookEvolutionEnabled,
    // Idle timeout for each non-streaming writer call.
    @Default(180000) int timeoutMs,
    @Default('') String apiConfigId,
    @Default('') String modelOverride,
    // Confirmations required before an observation is promoted to a validated
    // target injected into the next card writer call.
    @Default(3) int observationPromotionThreshold,
    // Minimum confidence for an observation to become a validated target.
    @Default(0.7) double observationMinConfidence,
    // Observation passes without confirmation before an active observation
    // expires. 4 passes ~ 48 turns ~ 96 messages.
    @Default(4) int observationExpiryRuns,
  }) = _CardRewriterSettings;

  factory CardRewriterSettings.fromJson(Map<String, dynamic> json) =>
      _$CardRewriterSettingsFromJson(json);
}
