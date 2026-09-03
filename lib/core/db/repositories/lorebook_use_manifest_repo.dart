import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../llm/prompt/exact_lorebook_manifest.dart';

/// The authoritative message variation anchor. It is independent of prompt or
/// manifest hashes: one variation has exactly one immutable canonical manifest.
class LorebookUseGenerationIdentity {
  const LorebookUseGenerationIdentity({
    required this.sessionId,
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
  });

  final String sessionId;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
}



class LorebookUseManifestInput {
  const LorebookUseManifestInput({
    required this.manifestJson,
    required this.manifestHash,
    required this.manifestSchemaVersion,
    required this.finalPromptHash,
    required this.presetSnapshotHash,
  });

  final String manifestJson;
  final String manifestHash;
  final int manifestSchemaVersion;
  final String finalPromptHash;
  final String presetSnapshotHash;
}

class LorebookUseManifestEntryInput {
  const LorebookUseManifestEntryInput({
    required this.lorebookId,
    required this.entryId,
    required this.entryOrder,
    this.evidenceJson = '{}',
  });

  final String lorebookId;
  final String entryId;
  final int entryOrder;
  final String evidenceJson;
}

/// Raised when a replay targets an existing anchor with non-identical bytes.
final class LorebookUseManifestIntegrityConflict implements Exception {
  const LorebookUseManifestIntegrityConflict(this.message);
  final String message;

  @override
  String toString() => 'LorebookUseManifestIntegrityConflict: $message';
}

/// Immutable lorebook-use persistence. Writes deliberately compose into the
/// caller's one [AppDatabase.transaction]; this repository never starts one.
class LorebookUseManifestRepo {
  const LorebookUseManifestRepo(this._db);
  final AppDatabase _db;

  /// Inserts an anchor once. Replays are accepted only when canonical payload,
  /// hashes, schema version, timestamp, and every derived entry are identical.
  Future<void> insertGenerationManifest({
    required LorebookUseGenerationIdentity identity,
    required LorebookUseManifestInput manifest,
    required int createdAt,
    required List<LorebookUseManifestEntryInput> entries,
  }) async {
    final canonical = _verifyCanonicalManifest(manifest, entries);
    final existing = await manifestFor(identity);
    if (existing != null) {
      if (existing.manifestJson != canonical.manifestJson ||
          existing.manifestHash != canonical.manifestHash ||
          existing.manifestSchemaVersion != canonical.manifestSchemaVersion ||
          existing.finalPromptHash != canonical.finalPromptHash ||
          existing.presetSnapshotHash != canonical.presetSnapshotHash ||
          existing.createdAt != createdAt) {
        throw const LorebookUseManifestIntegrityConflict(
          'manifest replay differs from the immutable variation anchor',
        );
      }
      final stored = await getEvidence(identity);
      if (!_sameEntries(stored, canonical.entries)) {
        throw const LorebookUseManifestIntegrityConflict(
          'derived entry replay differs from the immutable manifest',
        );
      }
      return;
    }
    await _db
        .into(_db.lorebookUseManifests)
        .insert(
          LorebookUseManifestsCompanion.insert(
            sessionId: identity.sessionId,
            messageId: identity.messageId,
            swipeId: identity.swipeId,
            agentSwipeId: identity.agentSwipeId,
            manifestJson: Value(canonical.manifestJson),
            manifestHash: Value(canonical.manifestHash),
            manifestSchemaVersion: Value(canonical.manifestSchemaVersion),
            finalPromptHash: Value(canonical.finalPromptHash),
            presetSnapshotHash: Value(canonical.presetSnapshotHash),
            createdAt: createdAt,
          ),
        );
    for (final entry in canonical.entries) {
      await _db
          .into(_db.lorebookUseManifestEntries)
          .insert(
            LorebookUseManifestEntriesCompanion.insert(
              sessionId: identity.sessionId,
              messageId: identity.messageId,
              swipeId: identity.swipeId,
              agentSwipeId: identity.agentSwipeId,
              lorebookId: entry.lorebookId,
              entryId: entry.entryId,
              entryOrder: entry.entryOrder,
              evidenceJson: Value(entry.evidenceJson),
            ),
          );
    }
  }

  /// Strictly reconstructs canonical persistence values and projections. This
  /// prevents raw JSON/hash pairs from bypassing durable-manifest validation.
  _CanonicalManifest _verifyCanonicalManifest(
    LorebookUseManifestInput supplied,
    List<LorebookUseManifestEntryInput> suppliedEntries,
  ) {
    try {
      final decoded = jsonDecode(supplied.manifestJson);
      if (decoded is! Map) throw const FormatException('manifest object');
      final durable = ExactLorebookManifest.decodeDurable({
        ...Map<String, dynamic>.from(decoded),
        'canonicalHash': supplied.manifestHash,
      });
      final entries = [
        for (var index = 0; index < durable.entries.length; index++)
          LorebookUseManifestEntryInput(
            lorebookId: durable.entries[index].lorebookId,
            entryId: durable.entries[index].entryId,
            entryOrder: index,
            evidenceJson: jsonEncode(durable.entries[index].toJson()),
          ),
      ];
      if (supplied.manifestJson != durable.canonicalJson ||
          supplied.manifestHash != durable.canonicalHash ||
          supplied.manifestSchemaVersion != 1 ||
          supplied.finalPromptHash != durable.providerMessagesHash ||
          supplied.presetSnapshotHash !=
              durable.promptProvenance.presetSnapshotHash ||
          !_sameEntryInputs(entries, suppliedEntries)) {
        throw const FormatException('manifest projections do not match');
      }
      return _CanonicalManifest(
        manifestJson: durable.canonicalJson,
        manifestHash: durable.canonicalHash,
        manifestSchemaVersion: 1,
        finalPromptHash: durable.providerMessagesHash,
        presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
        entries: entries,
      );
    } catch (error) {
      throw LorebookUseManifestIntegrityConflict(
        'invalid canonical manifest: $error',
      );
    }
  }

  /// Records that the next user message accepted this exact assistant
  /// variation. [acceptanceId] is deterministic and supplied by the caller;
  /// a replay is accepted only if every persisted byte/value is identical.
  Future<void> insertVariationAcceptance({
    required String acceptanceId,
    required LorebookUseGenerationIdentity identity,
    required String acceptedByUserMessageId,
    required int acceptedAt,
    String evidenceJson = '{}',
  }) => _insertAcceptance(
    acceptanceId: acceptanceId,
    identity: identity,
    acceptanceKind: 'variation',
    acceptedByUserMessageId: acceptedByUserMessageId,
    acceptedAt: acceptedAt,
    evidenceJson: evidenceJson,
  );

  Future<void> _insertAcceptance({
    required String acceptanceId,
    required LorebookUseGenerationIdentity identity,
    required String acceptanceKind,
    required int acceptedAt,
    required String evidenceJson,
    String? acceptedByUserMessageId,
    String? selectedLorebookId,
    String? selectedEntryId,
    int? selectedEntryOrder,
  }) async {
    if (await manifestFor(identity) == null) {
      throw const LorebookUseManifestIntegrityConflict(
        'acceptance requires an existing manifest',
      );
    }
    try {
      await _db
          .into(_db.lorebookUseAcceptanceRecords)
          .insert(
            LorebookUseAcceptanceRecordsCompanion.insert(
              acceptanceId: acceptanceId,
              sessionId: identity.sessionId,
              messageId: identity.messageId,
              swipeId: identity.swipeId,
              agentSwipeId: identity.agentSwipeId,
              acceptanceKind: acceptanceKind,
              acceptedByUserMessageId: Value(acceptedByUserMessageId),
              selectedLorebookId: Value(selectedLorebookId),
              selectedEntryId: Value(selectedEntryId),
              selectedEntryOrder: Value(selectedEntryOrder),
              evidenceJson: Value(evidenceJson),
              acceptedAt: acceptedAt,
            ),
          );
    } catch (_) {
      final existing =
          await (_db.select(_db.lorebookUseAcceptanceRecords)
                ..where((row) => row.acceptanceId.equals(acceptanceId)))
              .getSingleOrNull();
      if (existing != null &&
          existing.sessionId == identity.sessionId &&
          existing.messageId == identity.messageId &&
          existing.swipeId == identity.swipeId &&
          existing.agentSwipeId == identity.agentSwipeId &&
          existing.acceptanceKind == acceptanceKind &&
          existing.acceptedByUserMessageId == acceptedByUserMessageId &&
          existing.selectedLorebookId == selectedLorebookId &&
          existing.selectedEntryId == selectedEntryId &&
          existing.selectedEntryOrder == selectedEntryOrder &&
          existing.evidenceJson == evidenceJson &&
          existing.acceptedAt == acceptedAt) {
        return;
      }
      throw const LorebookUseManifestIntegrityConflict(
        'acceptance replay conflicts with immutable acceptance history',
      );
    }
  }

  /// The stored manifest for one message variation, or null when that
  /// generation predates manifests (or produced none). Read by the Prompt
  /// Inspector to show what a past turn actually injected.
  Future<LorebookUseManifestRow?> manifestFor(
    LorebookUseGenerationIdentity identity,
  ) =>
      (_db.select(_db.lorebookUseManifests)
            ..where((row) => row.sessionId.equals(identity.sessionId))
            ..where((row) => row.messageId.equals(identity.messageId))
            ..where((row) => row.swipeId.equals(identity.swipeId))
            ..where((row) => row.agentSwipeId.equals(identity.agentSwipeId)))
          .getSingleOrNull();

  /// Returns only authoritative variation acceptances. Supplemental selection
  /// records intentionally remain excluded from all eligibility reads.
  Future<List<LorebookUseAcceptanceRecordRow>> getVariationAcceptances(
    String sessionId,
  ) =>
      (_db.select(_db.lorebookUseAcceptanceRecords)
            ..where((row) => row.sessionId.equals(sessionId))
            ..where((row) => row.acceptanceKind.equals('variation'))
            ..orderBy([(row) => OrderingTerm(expression: row.acceptedAt)]))
          .get();

  Future<List<LorebookUseManifestEntryRow>> getEvidence(
    LorebookUseGenerationIdentity identity,
  ) =>
      (_db.select(_db.lorebookUseManifestEntries)
            ..where((row) => row.sessionId.equals(identity.sessionId))
            ..where((row) => row.messageId.equals(identity.messageId))
            ..where((row) => row.swipeId.equals(identity.swipeId))
            ..where((row) => row.agentSwipeId.equals(identity.agentSwipeId))
            ..orderBy([(row) => OrderingTerm(expression: row.entryOrder)]))
          .get();

  bool _sameEntries(
    List<LorebookUseManifestEntryRow> stored,
    List<LorebookUseManifestEntryInput> replay,
  ) =>
      stored.length == replay.length &&
      List.generate(stored.length, (i) => i).every(
        (i) =>
            stored[i].lorebookId == replay[i].lorebookId &&
            stored[i].entryId == replay[i].entryId &&
            stored[i].entryOrder == replay[i].entryOrder &&
            stored[i].evidenceJson == replay[i].evidenceJson,
      );

  static bool _sameEntryInputs(
    List<LorebookUseManifestEntryInput> expected,
    List<LorebookUseManifestEntryInput> supplied,
  ) =>
      expected.length == supplied.length &&
      List.generate(expected.length, (i) => i).every(
        (i) =>
            expected[i].lorebookId == supplied[i].lorebookId &&
            expected[i].entryId == supplied[i].entryId &&
            expected[i].entryOrder == supplied[i].entryOrder &&
            expected[i].evidenceJson == supplied[i].evidenceJson,
      );

  Future<void> deleteBySessionId(String sessionId) async {
    await (_db.delete(
      _db.lorebookUseAcceptanceRecords,
    )..where((r) => r.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.lorebookUseManifestEntries,
    )..where((r) => r.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.lorebookUseManifests,
    )..where((r) => r.sessionId.equals(sessionId))).go();
  }

  Future<void> deleteByVariation({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) async {
    final identity = LorebookUseGenerationIdentity(
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    await (_db.delete(_db.lorebookUseAcceptanceRecords)..where(
          (r) =>
              r.sessionId.equals(identity.sessionId) &
              r.messageId.equals(identity.messageId) &
              r.swipeId.equals(identity.swipeId) &
              r.agentSwipeId.equals(identity.agentSwipeId),
        ))
        .go();
    await (_db.delete(_db.lorebookUseManifestEntries)..where(
          (r) =>
              r.sessionId.equals(identity.sessionId) &
              r.messageId.equals(identity.messageId) &
              r.swipeId.equals(identity.swipeId) &
              r.agentSwipeId.equals(identity.agentSwipeId),
        ))
        .go();
    await (_db.delete(_db.lorebookUseManifests)..where(
          (r) =>
              r.sessionId.equals(identity.sessionId) &
              r.messageId.equals(identity.messageId) &
              r.swipeId.equals(identity.swipeId) &
              r.agentSwipeId.equals(identity.agentSwipeId),
        ))
        .go();
  }
}

final class _CanonicalManifest {
  const _CanonicalManifest({
    required this.manifestJson,
    required this.manifestHash,
    required this.manifestSchemaVersion,
    required this.finalPromptHash,
    required this.presetSnapshotHash,
    required this.entries,
  });

  final String manifestJson;
  final String manifestHash;
  final int manifestSchemaVersion;
  final String finalPromptHash;
  final String presetSnapshotHash;
  final List<LorebookUseManifestEntryInput> entries;
}
