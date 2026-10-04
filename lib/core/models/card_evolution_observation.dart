import 'package:freezed_annotation/freezed_annotation.dart';

part 'card_evolution_observation.freezed.dart';
part 'card_evolution_observation.g.dart';

/// One observation-journal entry for the Card Rewriter. An observation is a
/// candidate durable character change recorded by the observation pass; it is
/// not itself a card edit. Confirmations bump `repeatCount`; promotion flips
/// `status` to `promoted` so the next card writer call receives it as a
/// validated target. After a successful apply the status becomes `consumed`.
@freezed
abstract class CardEvolutionObservation with _$CardEvolutionObservation {
  const CardEvolutionObservation._();

  const factory CardEvolutionObservation({
    required String id,
    required String sessionId,
    required String characterId,
    required int runOrdinal,
    required String semanticScopeKey,
    required String observedChange,
    String? canonicalClaim,
    required List<List<String>> evidenceClusters,
    @Default([]) List<String> retrievalKeys,
    String? targetKind,
    String? cardFieldPath,
    String? lorebookEntryId,
    required double confidence,
    required String status,
    required int firstSeenRun,
    @Default(1) int repeatCount,
    int? lastConfirmedRun,
    required int createdAt,
    required int updatedAt,
  }) = _CardEvolutionObservation;

  factory CardEvolutionObservation.fromJson(Map<String, dynamic> json) =>
      _$CardEvolutionObservationFromJson(json);

  /// Compatibility/audit view. Independent clusters remain the source of truth.
  List<String> get evidenceMessageIds => [
    for (final cluster in evidenceClusters) ...cluster,
  ];
}
