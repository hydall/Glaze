import 'dart:convert';

import '../../models/character_knowledge_fact.dart';
import '../../models/tracker.dart';
import '../app_db.dart';

final class DecodedReconciliationState {
  const DecodedReconciliationState({
    required this.trackerRows,
    required this.knowledgeRows,
    required this.trackers,
    required this.knowledgeFacts,
  });

  final List<TrackerRow> trackerRows;
  final List<CharacterKnowledgeFactRow> knowledgeRows;
  final List<Tracker> trackers;
  final List<CharacterKnowledgeFact> knowledgeFacts;
}

abstract final class ReconciliationStateCodec {
  static DecodedReconciliationState decode({
    required String sessionId,
    required String ledgerJson,
    required String knowledgeJson,
  }) {
    final trackerRows = _decodeRows(
      ledgerJson,
      label: 'tracker',
      decode: TrackerRow.fromJson,
    );
    final knowledgeRows = _decodeRows(
      knowledgeJson,
      label: 'knowledge',
      decode: CharacterKnowledgeFactRow.fromJson,
    );
    if (trackerRows.any(
          (row) => row.sessionId != sessionId || row.scope != 'ledger',
        ) ||
        trackerRows.map((row) => row.name).toSet().length !=
            trackerRows.length) {
      throw ArgumentError('Exact Ledger rows do not belong to the session.');
    }
    if (knowledgeRows.any((row) => row.chatSessionId != sessionId) ||
        knowledgeRows.map((row) => row.id).toSet().length !=
            knowledgeRows.length) {
      throw ArgumentError('Exact knowledge rows do not belong to the session.');
    }
    return DecodedReconciliationState(
      trackerRows: List.unmodifiable(trackerRows),
      knowledgeRows: List.unmodifiable(knowledgeRows),
      trackers: List.unmodifiable(trackerRows.map(_trackerFromRow)),
      knowledgeFacts: List.unmodifiable(knowledgeRows.map(_factFromRow)),
    );
  }

  static List<T> _decodeRows<T>(
    String rowsJson, {
    required String label,
    required T Function(Map<String, dynamic>) decode,
  }) {
    final value = jsonDecode(rowsJson);
    if (value is! List) throw FormatException('Expected $label rows');
    return value
        .map((row) {
          if (row is! Map<Object?, Object?>) {
            throw FormatException('Expected $label row');
          }
          return decode(Map<String, dynamic>.from(row));
        })
        .toList(growable: false);
  }

  static Tracker _trackerFromRow(TrackerRow row) => Tracker(
    sessionId: row.sessionId,
    name: row.name,
    value: row.value,
    scope: row.scope,
    provenance: row.provenance,
    basisRevisionNumber: row.basisRevision,
    basisRevisionHash: row.basisRevisionHash,
    updatedAt: row.updatedAt,
  );

  static CharacterKnowledgeFact _factFromRow(CharacterKnowledgeFactRow row) =>
      CharacterKnowledgeFact(
        id: row.id,
        chatSessionId: row.chatSessionId,
        knowerKey: row.knowerKey,
        knowerName: row.knowerName,
        subjectKey: row.subjectKey,
        subjectName: row.subjectName,
        factClass: CharacterKnowledgeFactClass.fromWireName(row.factClass),
        scopeKey: row.scopeKey,
        predicate: row.predicate,
        object: row.object,
        epistemicState: CharacterKnowledgeEpistemicState.fromWireName(
          row.epistemicState,
        ),
        confidence: row.confidence,
        importance: row.importance,
        entities: _decodeStrings(row.entitiesJson),
        topics: _decodeStrings(row.topicsJson),
        sourceMessageId: row.sourceMessageId,
        sourceSwipeId: row.sourceSwipeId,
        sourceAgentSwipeId: row.sourceAgentSwipeId,
        sourceKind: row.sourceKind,
        supersedesId: row.supersedesId,
        lifecycle: CharacterKnowledgeFactLifecycle.fromWireName(row.lifecycle),
        basisRevisionNumber: row.basisRevision,
        basisRevisionHash: row.basisRevisionHash,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );

  static List<String> _decodeStrings(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List || decoded.any((item) => item is! String)) {
      throw const FormatException('Expected a string list');
    }
    return decoded.cast<String>();
  }
}
