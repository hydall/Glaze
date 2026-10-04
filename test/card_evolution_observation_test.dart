import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';

void main() {
  test('fromJson/toJson round-trip with all fields', () {
    final observation = CardEvolutionObservation(
      id: 'obs-1',
      sessionId: 'session',
      characterId: 'character',
      runOrdinal: 3,
      semanticScopeKey: 'character.preference.X',
      observedChange: 'Alice is becoming more trusting',
      canonicalClaim: 'Alice has become more trusting over time',
      evidenceClusters: const [
        ['msg:1', 'msg:2'],
        ['msg:3'],
      ],
      retrievalKeys: const ['npc:Алиса'],
      targetKind: 'main_character_card',
      cardFieldPath: 'personality',
      lorebookEntryId: 'book:entry',
      confidence: 0.85,
      status: 'promoted',
      firstSeenRun: 1,
      repeatCount: 3,
      lastConfirmedRun: 3,
      createdAt: 100,
      updatedAt: 200,
    );
    final json = observation.toJson();
    final restored = CardEvolutionObservation.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(restored, observation);
  });

  test('fromJson/toJson round-trip with nullable fields null', () {
    final observation = CardEvolutionObservation(
      id: 'obs-2',
      sessionId: 'session',
      characterId: 'character',
      runOrdinal: 1,
      semanticScopeKey: 'character.attitude.Y',
      observedChange: 'Bob is more reserved',
      evidenceClusters: const [],
      confidence: 0.5,
      status: 'active',
      firstSeenRun: 1,
      createdAt: 10,
      updatedAt: 10,
    );
    final json = observation.toJson();
    final restored = CardEvolutionObservation.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );
    expect(restored, observation);
    expect(restored.canonicalClaim, isNull);
    expect(restored.cardFieldPath, isNull);
    expect(restored.lorebookEntryId, isNull);
    expect(restored.lastConfirmedRun, isNull);
    expect(restored.repeatCount, 1);
    expect(restored.evidenceMessageIds, isEmpty);
  });
}
