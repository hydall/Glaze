import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/reconciliation_state_codec.dart';

void main() {
  test('decodes complete exact state into rows and domain models', () {
    const tracker = TrackerRow(
      sessionId: 's',
      name: 'world:time',
      value: 'night',
      scope: 'ledger',
      provenance: 'reconcile:m1',
      basisRevision: 2,
      basisRevisionHash: 'revision',
      updatedAt: 3,
    );
    const fact = CharacterKnowledgeFactRow(
      id: 'fact',
      chatSessionId: 's',
      knowerKey: 'entity:a',
      knowerName: 'A',
      subjectKey: 'entity:b',
      subjectName: 'B',
      factClass: 'knowledge',
      scopeKey: 'scope',
      predicate: 'knows',
      object: 'the truth',
      epistemicState: 'confirmed',
      confidence: 0.8,
      importance: 0.7,
      entitiesJson: '["A","B"]',
      topicsJson: '["truth"]',
      sourceMessageId: 'm1',
      sourceSwipeId: 0,
      sourceAgentSwipeId: 0,
      sourceKind: 'studio_ledger',
      lifecycle: 'active',
      basisRevision: 2,
      basisRevisionHash: 'revision',
      createdAt: 1,
      updatedAt: 3,
    );

    final decoded = ReconciliationStateCodec.decode(
      sessionId: 's',
      ledgerJson: jsonEncode([tracker.toJson()]),
      knowledgeJson: jsonEncode([fact.toJson()]),
    );

    expect(decoded.trackerRows.single, tracker);
    expect(decoded.trackers.single.value, 'night');
    expect(decoded.knowledgeRows.single, fact);
    expect(decoded.knowledgeFacts.single.entities, ['A', 'B']);
  });

  test('rejects duplicate identities and invalid nested JSON', () {
    const tracker = TrackerRow(
      sessionId: 's',
      name: 'duplicate',
      value: '',
      scope: 'ledger',
      provenance: '',
      basisRevision: 0,
      basisRevisionHash: '',
      updatedAt: 0,
    );
    expect(
      () => ReconciliationStateCodec.decode(
        sessionId: 's',
        ledgerJson: jsonEncode([tracker.toJson(), tracker.toJson()]),
        knowledgeJson: '[]',
      ),
      throwsArgumentError,
    );
  });
}
