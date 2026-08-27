import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/character_folder_repo.dart';
import '../../../core/db/repositories/extension_presets_repository.dart';
import '../../../core/db/repositories/info_blocks_repository.dart';
import '../../../core/db/repositories/card_evolution_collector_run_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_run_repo.dart';
import '../../../core/db/repositories/summary_repo.dart';
import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/db/repositories/tracker_repo.dart';
import '../../../core/models/tracker.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../core/utils/cast_helpers.dart';
import '../../extensions/models/extension_preset.dart';
import '../../extensions/models/extensions_settings.dart';
import '../../extensions/models/info_block.dart';
import '../sync_repo_interfaces.dart';

// ---------------------------------------------------------------------------
// ExtensionPresetSyncStore
// ---------------------------------------------------------------------------

class ExtensionPresetSyncStore implements SyncExtensionPresetStore {
  final ExtensionPresetsRepository _repo;

  ExtensionPresetSyncStore(this._repo);

  @override
  Future<List<ExtensionPreset>> getAll() => _repo.getAll();

  @override
  Future<ExtensionPreset?> getById(String id) => _repo.getById(id);

  @override
  Future<void> put(ExtensionPreset p) async {
    final existing = await _repo.getById(p.id);
    if (existing == null) {
      await _repo.insert(p);
    } else {
      await _repo.updatePreset(p);
    }
  }

  @override
  Future<void> delete(String id) => _repo.deletePreset(id);
}

// ---------------------------------------------------------------------------
// ExtensionsSettingsSyncStore
// ---------------------------------------------------------------------------

class ExtensionsSettingsSyncStore implements SyncExtensionsSettingsStore {
  static const _storageKey = 'extensions_settings';

  @override
  Future<ExtensionsSettings> get() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr == null) return const ExtensionsSettings();
    try {
      return ExtensionsSettings.fromJson(
        jsonDecode(jsonStr) as Map<String, dynamic>,
      );
    } catch (_) {
      return const ExtensionsSettings();
    }
  }

  @override
  Future<void> put(ExtensionsSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(s.toJson()));
  }
}

// ---------------------------------------------------------------------------
// InfoBlockSyncStore
// ---------------------------------------------------------------------------

class InfoBlockSyncStore implements SyncInfoBlockStore {
  final InfoBlocksRepository _repo;

  InfoBlockSyncStore(this._repo);

  @override
  Future<List<String>> getAllSessionIds() => _repo.getAllSessionIds();

  @override
  Future<List<InfoBlock>> getBySessionId(String sessionId) =>
      _repo.getBySessionId(sessionId);

  @override
  Future<void> deleteBySessionId(String sessionId) =>
      _repo.deleteBySessionId(sessionId);

  @override
  Future<void> insert(InfoBlock block) => _repo.insert(block);
}

/// Adapter wrapping [TrackerSnapshotRepo] for cloud sync. Per-session
/// collection, same shape as [InfoBlockSyncStore].
class TrackerSnapshotSyncStore implements SyncTrackerSnapshotStore {
  final TrackerSnapshotRepo _repo;

  TrackerSnapshotSyncStore(this._repo);

  @override
  Future<List<String>> getAllSessionIds() => _repo.getAllSessionIds();

  @override
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId) async {
    final snapshots = await _repo.getBySessionId(sessionId);
    return snapshots.map((s) => s.toJson()).toList();
  }

  @override
  Future<void> deleteBySessionId(String sessionId) =>
      _repo.deleteBySessionId(sessionId);

  @override
  Future<void> insertRaw(Map<String, dynamic> snapshot) async {
    await _repo.upsert(TrackerSnapshot.fromJson(snapshot));
  }
}

/// Adapter wrapping [TrackerRepo] for cloud sync of the live Tracker Values
/// store. Snapshots are synced separately; this preserves current mutable rows
/// such as canon overrides/locks that may not be represented by an accepted
/// assistant-turn snapshot yet.
class TrackerValueSyncStore implements SyncTrackerValueStore {
  final TrackerRepo _repo;

  TrackerValueSyncStore(this._repo);

  @override
  Future<List<String>> getAllSessionIds() => _repo.getAllSessionIds();

  @override
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId) async {
    final trackers = await _repo.getBySessionId(sessionId);
    return trackers.map((t) => t.toJson()).toList();
  }

  @override
  Future<void> deleteBySessionId(String sessionId) =>
      _repo.clearForSession(sessionId);

  @override
  Future<void> insertRaw(Map<String, dynamic> tracker) async {
    await _repo.upsert(Tracker.fromJson(tracker));
  }
}

// ---------------------------------------------------------------------------
// ChatSummarySyncStore
// ---------------------------------------------------------------------------

/// Adapter wrapping [SummaryRepo] for cloud sync of chat summaries.
/// Per-session collection, same shape as [TrackerValueSyncStore].
class ChatSummarySyncStore implements SyncChatSummaryStore {
  final SummaryRepo _repo;

  ChatSummarySyncStore(this._repo);

  @override
  Future<List<String>> getAllSessionIds() => _repo.getAllSessionIds();

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) async {
    final row = await _repo.get(sessionId);
    if (row == null) return null;
    return {
      'sessionId': row.sessionId,
      'content': row.content,
      'enabled': row.enabled,
      'messageCount': row.messageCount,
      'prompt': row.prompt,
      'updatedAt': row.updatedAt,
    };
  }

  @override
  Future<void> putRaw(Map<String, dynamic> summary) async {
    final sessionId = summary['sessionId'] as String? ?? '';
    if (sessionId.isEmpty) return;
    await _repo.putSynced(
      sessionId: sessionId,
      content: summary['content'] as String? ?? '',
      messageCount: summary['messageCount'] as int? ?? 0,
      enabled: summary['enabled'] as bool? ?? true,
      prompt: summary['prompt'] as String?,
      updatedAt: summary['updatedAt'] as int? ?? 0,
    );
  }

  @override
  Future<void> deleteBySessionId(String sessionId) =>
      _repo.deleteBySessionId(sessionId);
}

// ---------------------------------------------------------------------------
// CharacterFolderSyncStore
// ---------------------------------------------------------------------------

/// Adapter wrapping [CharacterFolderRepo] for cloud sync of character folders
/// and their membership rows. Singleton — all folders + members in one JSON.
class CharacterFolderSyncStore implements SyncCharacterFolderStore {
  final CharacterFolderRepo _repo;

  CharacterFolderSyncStore(this._repo);

  @override
  Future<Map<String, dynamic>> getAll() async {
    final folders = await _repo.getFolders();
    final members = await _repo.getAllMembers();
    return {
      '__singleton': true,
      'folders': folders
          .map(
            (f) => {
              'folderId': f.id,
              'name': f.name,
              'color': f.color,
              'sortOrder': f.sortOrder,
              'createdAt': f.createdAt,
              'updatedAt': f.updatedAt,
            },
          )
          .toList(),
      'members': members
          .map(
            (m) => {
              'folderId': m.folderId,
              'charId': m.charId,
              'addedAt': m.addedAt,
            },
          )
          .toList(),
    };
  }

  @override
  Future<void> applyAll(Map<String, dynamic> data) async {
    final folders =
        (data['folders'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final members =
        (data['members'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    await _repo.deleteAllFoldersAndMembers();
    for (final f in folders) {
      await _repo.upsertFolderRaw(
        CharacterFolderRow(
          folderId: f['folderId'] as String? ?? '',
          name: f['name'] as String? ?? '',
          color: f['color'] as String?,
          sortOrder: f['sortOrder'] as int? ?? 0,
          createdAt: f['createdAt'] as int? ?? 0,
          updatedAt: f['updatedAt'] as int? ?? 0,
        ),
      );
    }
    for (final m in members) {
      await _repo.upsertMemberRaw(
        CharacterFolderMemberRow(
          folderId: m['folderId'] as String? ?? '',
          charId: m['charId'] as String? ?? '',
          addedAt: m['addedAt'] as int? ?? 0,
        ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// MemoryGraphSyncStore
// ---------------------------------------------------------------------------

/// Adapter for cloud sync of the 5 memory-graph tables. Per-session —
/// all rows for one session packed into a single JSON payload.
class MemoryGraphSyncStore implements SyncMemoryGraphStore {
  final AppDatabase _db;

  MemoryGraphSyncStore(this._db);

  @override
  Future<List<String>> getAllSessionIds() async {
    final ids = <String>{};
    final catalog = await _db
        .customSelect(
          "SELECT DISTINCT chat_session_id FROM memory_catalog_rows",
        )
        .get();
    for (final r in catalog) {
      ids.add(r.read<String>('chat_session_id'));
    }
    final entities = await _db
        .customSelect("SELECT DISTINCT chat_session_id FROM memory_entity_rows")
        .get();
    for (final r in entities) {
      ids.add(r.read<String>('chat_session_id'));
    }
    final salience = await _db
        .customSelect(
          "SELECT DISTINCT chat_session_id FROM memory_salience_rows",
        )
        .get();
    for (final r in salience) {
      ids.add(r.read<String>('chat_session_id'));
    }
    final cadence = await _db
        .customSelect(
          "SELECT DISTINCT chat_session_id FROM memory_cadence_rows",
        )
        .get();
    for (final r in cadence) {
      ids.add(r.read<String>('chat_session_id'));
    }
    final consolidation = await _db
        .customSelect(
          "SELECT DISTINCT chat_session_id FROM memory_consolidation_rows",
        )
        .get();
    for (final r in consolidation) {
      ids.add(r.read<String>('chat_session_id'));
    }
    return ids.toList();
  }

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) async {
    final catalog = await (_db.select(
      _db.memoryCatalogRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).get();
    final entities = await (_db.select(
      _db.memoryEntityRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).get();
    final salience = await (_db.select(
      _db.memorySalienceRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).get();
    final cadence = await (_db.select(
      _db.memoryCadenceRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).get();
    final consolidation = await (_db.select(
      _db.memoryConsolidationRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).get();

    if (catalog.isEmpty &&
        entities.isEmpty &&
        salience.isEmpty &&
        cadence.isEmpty &&
        consolidation.isEmpty) {
      return null;
    }

    return {
      '__memoryGraph': true,
      'sessionId': sessionId,
      'catalog': catalog.map((r) => r.toJson()).toList(),
      'entities': entities.map((r) => r.toJson()).toList(),
      'salience': salience.map((r) => r.toJson()).toList(),
      'cadence': cadence.map((r) => r.toJson()).toList(),
      'consolidation': consolidation.map((r) => r.toJson()).toList(),
    };
  }

  @override
  Future<void> applyBySessionId(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    await deleteBySessionId(sessionId);

    final catalog =
        (data['catalog'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final entities =
        (data['entities'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final salience =
        (data['salience'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final cadence =
        (data['cadence'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final consolidation =
        (data['consolidation'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    for (final row in catalog) {
      await _db
          .into(_db.memoryCatalogRows)
          .insert(
            MemoryCatalogRow.fromJson(row),
            mode: InsertMode.insertOrReplace,
          );
    }
    for (final row in entities) {
      await _db
          .into(_db.memoryEntityRows)
          .insert(
            MemoryEntityRow.fromJson(row),
            mode: InsertMode.insertOrReplace,
          );
    }
    for (final row in salience) {
      await _db
          .into(_db.memorySalienceRows)
          .insert(
            MemorySalienceRow.fromJson(row),
            mode: InsertMode.insertOrReplace,
          );
    }
    for (final row in cadence) {
      await _db
          .into(_db.memoryCadenceRows)
          .insert(
            MemoryCadenceRow.fromJson(row),
            mode: InsertMode.insertOrReplace,
          );
    }
    for (final row in consolidation) {
      await _db
          .into(_db.memoryConsolidationRows)
          .insert(
            MemoryConsolidationRow.fromJson(row),
            mode: InsertMode.insertOrReplace,
          );
    }
  }

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    await (_db.delete(
      _db.memoryCatalogRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryEntityRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memorySalienceRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryCadenceRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.memoryConsolidationRows,
    )..where((t) => t.chatSessionId.equals(sessionId))).go();
  }
}

/// Adapter for atomic character knowledge and immutable session baselines.
/// Retained/retracted rows are intentionally included: their lifecycle is
/// provenance, not disposable cache state.
class CharacterKnowledgeSyncStore implements SyncCharacterKnowledgeStore {
  final AppDatabase _db;

  CharacterKnowledgeSyncStore(this._db);

  @override
  Future<List<String>> getAllSessionIds() async {
    final ids = <String>{};
    final facts = await _db
        .customSelect(
          'SELECT DISTINCT chat_session_id FROM character_knowledge_fact_rows',
        )
        .get();
    final baselines = await _db
        .customSelect(
          'SELECT DISTINCT chat_session_id FROM character_session_baseline_rows',
        )
        .get();
    for (final row in [...facts, ...baselines]) {
      ids.add(row.read<String>('chat_session_id'));
    }
    return ids.toList();
  }

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) async {
    final facts = await (_db.select(
      _db.characterKnowledgeFactRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).get();
    final baseline = await (_db.select(
      _db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).getSingleOrNull();
    if (facts.isEmpty && baseline == null) return null;
    return {
      '__characterKnowledge': true,
      'sessionId': sessionId,
      'facts': facts.map((row) => row.toJson()).toList(),
      if (baseline != null) 'baseline': baseline.toJson(),
    };
  }

  @override
  Future<void> applyBySessionId(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    await deleteBySessionId(sessionId);
    final facts = (data['facts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final baseline = data['baseline'] as Map<String, dynamic>?;
    await _db.transaction(() async {
      for (final fact in facts) {
        await _db
            .into(_db.characterKnowledgeFactRows)
            .insert(
              CharacterKnowledgeFactRow.fromJson(fact),
              mode: InsertMode.insertOrReplace,
            );
      }
      if (baseline != null) {
        await _db
            .into(_db.characterSessionBaselineRows)
            .insert(
              CharacterSessionBaselineRow.fromJson(baseline),
              mode: InsertMode.insertOrReplace,
            );
      }
    });
  }

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    await (_db.delete(
      _db.characterKnowledgeFactRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
  }
}

/// Merge-only adapter for immutable reconciliation history and its derived
/// Card Evolution collector lane. Stale devices may contribute a prefix, but
/// can never truncate or replace a chain that reaches farther in the chat.
class ReconciliationStateSyncStore implements SyncReconciliationStateStore {
  ReconciliationStateSyncStore(this._db);

  final AppDatabase _db;

  @override
  Future<List<String>> getAllSessionIds() async {
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT session_id FROM reconciliation_successful_runs',
        )
        .get();
    return rows.map((row) => row.read<String>('session_id')).toList();
  }

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) async {
    final runs =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
            .get();
    if (runs.isEmpty) return null;
    final invalidations = await (_db.select(
      _db.ledgerReconciliationRunInvalidations,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    invalidations.sort((a, b) {
      final run = a.runId.compareTo(b.runId);
      if (run != 0) return run;
      final message = a.causeMessageId.compareTo(b.causeMessageId);
      return message != 0 ? message : a.reason.compareTo(b.reason);
    });
    final runRepo = LedgerReconciliationRunRepo(_db);
    final effects = <LedgerReconciliationEffectRow>[];
    for (final run in runs) {
      final validation = await runRepo.validateEffect(run);
      if (validation is ReconciliationEffectValid) {
        final effect = await runRepo.readEffect(run.id);
        if (effect != null) effects.add(effect);
      }
    }
    final manifests = await (_db.select(
      _db.lorebookUseManifests,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    manifests.sort((a, b) => _manifestKey(a).compareTo(_manifestKey(b)));
    final manifestEntries = await (_db.select(
      _db.lorebookUseManifestEntries,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    manifestEntries.sort(
      (a, b) => _manifestEntryKey(a).compareTo(_manifestEntryKey(b)),
    );
    final acceptances = await (_db.select(
      _db.lorebookUseAcceptanceRecords,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    acceptances.sort((a, b) => a.acceptanceId.compareTo(b.acceptanceId));
    final collectors =
        await (_db.select(_db.cardEvolutionCollectorRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.status.equals('completed'))
              ..orderBy([(row) => OrderingTerm.asc(row.collectorOrdinal)]))
            .get();
    final observations = await (_db.select(
      _db.cardEvolutionObservations,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    observations.sort(
      (a, b) => a.semanticScopeKey.compareTo(b.semanticScopeKey),
    );
    final claims =
        await (_db.select(_db.cardEvolutionClaims)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.status.equals('completed')))
            .get();
    final completedCollectorBoundaries = {
      for (final row in collectors)
        (row.collectorOrdinal, row.reconciliationChainHash),
    };
    claims.removeWhere(
      (row) => !completedCollectorBoundaries.contains((
        row.predecessorRunOrdinal,
        row.predecessorCursorHash,
      )),
    );
    claims.sort((a, b) => a.inputHash.compareTo(b.inputHash));
    return {
      '__reconciliationState': true,
      'schemaVersion': 2,
      'sessionId': sessionId,
      'runs': runs.map((row) => row.toJson()).toList(),
      'effects': effects.map((row) => row.toJson()).toList(),
      'invalidations': invalidations.map(_invalidationForSync).toList(),
      'manifests': manifests.map((row) => row.toJson()).toList(),
      'manifestEntries': manifestEntries.map((row) => row.toJson()).toList(),
      'acceptances': acceptances.map((row) => row.toJson()).toList(),
      'collectors': collectors.map(_collectorForSync).toList(),
      'observations': observations.map(_observationForSync).toList(),
      'completedClaims': claims.map(_claimForSync).toList(),
    };
  }

  @override
  Future<Map<String, dynamic>> mergeBySessionId(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    final schemaVersion = data['schemaVersion'];
    if (data['__reconciliationState'] != true ||
        (schemaVersion != 1 && schemaVersion != 2) ||
        data['sessionId'] != sessionId) {
      throw const FormatException('Invalid reconciliation sync payload');
    }
    await _db.transaction(() async {
      final normalized = await _normalizeIncomingRuns(
        sessionId,
        _maps(data['runs']),
        _maps(data['invalidations']),
      );
      final runDecision = await _resolveRunMerge(
        sessionId,
        normalized.runs,
        normalized.invalidations,
      );
      if (runDecision == _RunMergeDecision.keepLocal) return;
      if (runDecision == _RunMergeDecision.replaceLocal) {
        await _clearReconciliationLane(sessionId);
      }
      await _mergeSourceRows(sessionId, data);
      final importedComplete = await _mergeRuns(sessionId, normalized.runs);
      if (importedComplete) {
        await _mergeEffects(
          sessionId,
          schemaVersion == 2 ? _maps(data['effects']) : const [],
          normalized.idMap,
        );
      }
      await _mergeInvalidations(
        sessionId,
        normalized.invalidations,
        ignoreUnknown: !importedComplete,
      );
      final collectors = normalized.identitiesChanged
          ? <Map<String, dynamic>>[]
          : _maps(data['collectors']);
      final resetDerivedLane = await _resetDerivedLaneForInvalidations(
        sessionId,
        collectors,
      );
      if (importedComplete && !resetDerivedLane) {
        final collectorsValid = await _mergeCollectors(sessionId, collectors);
        if (collectorsValid) {
          if (!normalized.identitiesChanged) {
            await _mergeObservations(sessionId, _maps(data['observations']));
            await _mergeCompletedClaims(
              sessionId,
              _maps(data['completedClaims']),
            );
          }
        }
      }
    });
    return await getBySessionId(sessionId) ?? _emptyPayload(sessionId);
  }

  Future<_NormalizedReconciliationPayload> _normalizeIncomingRuns(
    String sessionId,
    List<Map<String, dynamic>> incoming,
    List<Map<String, dynamic>> invalidations,
  ) async {
    incoming.sort(
      (a, b) => (a['ordinal'] as int).compareTo(b['ordinal'] as int),
    );
    final normalized = <Map<String, dynamic>>[];
    final idMap = <String, String>{};
    var predecessor = '';
    var changed = false;
    for (var index = 0; index < incoming.length; index++) {
      final row = LedgerReconciliationSuccessfulRunRow.fromJson(
        incoming[index],
      );
      _requireSession(sessionId, row.sessionId);
      final decoded = _runFromRow(row);
      final occupied = await (_db.select(
        _db.ledgerReconciliationSuccessfulRuns,
      )..where((item) => item.id.equals(row.id))).getSingleOrNull();
      final canonical = LedgerReconciliationRun(
        id: '',
        sessionId: sessionId,
        ordinal: index + 1,
        anchors: decoded.anchors,
        acceptedManifestRefs: decoded.acceptedManifestRefs,
        effectiveCanonStamp: decoded.effectiveCanonStamp,
        effectiveCanonRevision: decoded.effectiveCanonRevision,
        effectiveCanonHash: decoded.effectiveCanonHash,
        canonicalResult: decoded.canonicalResult,
        predecessorChainHash: predecessor,
        contractVersion: decoded.contractVersion,
        opsApplied: decoded.opsApplied,
        createdAt: decoded.createdAt,
      );
      final canonicalId = await LedgerReconciliationRunRepo(
        _db,
      ).allocateId(sessionId, canonical.contentHash);
      final storedCanonical =
          row.ordinal != canonical.ordinal ||
          row.contentHash != canonical.contentHash ||
          row.predecessorChainHash != canonical.predecessorChainHash ||
          row.chainHash != canonical.chainHash;
      final foreignIdentity =
          occupied != null && occupied.sessionId != sessionId;
      final legacyBranchCopy =
          foreignIdentity &&
          row.contentHash == occupied.contentHash &&
          row.predecessorChainHash == occupied.predecessorChainHash &&
          row.chainHash == occupied.chainHash;
      if (storedCanonical && !legacyBranchCopy) {
        changed = true;
        break;
      }
      final needsNormalization = storedCanonical || foreignIdentity;
      final outputId = needsNormalization ? canonicalId : row.id;
      if (needsNormalization && canonical.acceptedManifestRefs.isNotEmpty) {
        changed = true;
        break;
      }
      final output = needsNormalization
          ? {
              ...row.toJson(),
              'id': outputId,
              'ordinal': canonical.ordinal,
              'contentHash': canonical.contentHash,
              'predecessorChainHash': canonical.predecessorChainHash,
              'chainHash': canonical.chainHash,
            }
          : row.toJson();
      normalized.add(output);
      idMap[row.id] = output['id'] as String;
      predecessor = output['chainHash'] as String;
      changed = changed || needsNormalization;
    }
    final remappedInvalidations = <Map<String, dynamic>>[];
    for (final invalidation in invalidations) {
      final oldId = invalidation['runId'] as String;
      final newId = idMap[oldId];
      if (newId == null) {
        changed = true;
        continue;
      }
      remappedInvalidations.add({...invalidation, 'runId': newId});
      changed = changed || newId != oldId;
    }
    return _NormalizedReconciliationPayload(
      runs: normalized,
      invalidations: remappedInvalidations,
      idMap: idMap,
      identitiesChanged: changed,
    );
  }

  Future<_RunMergeDecision> _resolveRunMerge(
    String sessionId,
    List<Map<String, dynamic>> incoming,
    List<Map<String, dynamic>> incomingInvalidations,
  ) async {
    incoming.sort(
      (a, b) => (a['ordinal'] as int).compareTo(b['ordinal'] as int),
    );
    final local =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
            .get();
    final overlap = local.length < incoming.length
        ? local.length
        : incoming.length;
    var divergent = false;
    for (var i = 0; i < overlap; i++) {
      final cloud = LedgerReconciliationSuccessfulRunRow.fromJson(incoming[i]);
      _requireSession(sessionId, cloud.sessionId);
      if (!_sameDataClass(local[i], cloud)) {
        divergent = true;
        break;
      }
    }
    if (!divergent) return _RunMergeDecision.merge;

    final localVisible = await LedgerReconciliationRunRepo(
      _db,
    ).readSession(sessionId);
    final incomingInvalidatedIds = incomingInvalidations
        .map((row) => row['runId'] as String)
        .toSet();
    final incomingVisible = incoming
        .map(LedgerReconciliationSuccessfulRunRow.fromJson)
        .where((run) => !incomingInvalidatedIds.contains(run.id))
        .toList();
    final repo = LedgerReconciliationRunRepo(_db);
    final incomingMatchesChat = await Future.wait(
      incomingVisible.map((row) => repo.anchorsMatchSession(_runFromRow(row))),
    );
    if (incomingMatchesChat.any((matches) => !matches)) {
      return localVisible.isNotEmpty
          ? _RunMergeDecision.keepLocal
          : _RunMergeDecision.replaceLocal;
    }
    if (localVisible.isEmpty || incomingVisible.isEmpty) {
      if (incomingVisible.isNotEmpty) return _RunMergeDecision.replaceLocal;
      if (localVisible.isNotEmpty) return _RunMergeDecision.keepLocal;
      throw StateError('Divergent reconciliation chains have no live head');
    }

    final chat = await _db
        .customSelect(
          'SELECT messages_json FROM chat_sessions WHERE session_id = ?',
          variables: [Variable.withString(sessionId)],
        )
        .getSingleOrNull();
    if (chat == null) {
      throw StateError('Cannot resolve reconciliation chains without chat');
    }
    final messageIds = (jsonDecode(chat.read<String>('messages_json')) as List)
        .cast<Map<String, dynamic>>()
        .map((message) => message['id'] as String)
        .toList();
    final localHead = localVisible.last;
    final incomingHead = incomingVisible.last;
    final localEndpoint = messageIds.indexOf(localHead.endMessageId);
    final incomingEndpoint = messageIds.indexOf(incomingHead.endMessageId);
    if (localEndpoint < 0 && incomingEndpoint >= 0) {
      return _RunMergeDecision.replaceLocal;
    }
    if (incomingEndpoint < 0) return _RunMergeDecision.keepLocal;
    if (incomingEndpoint > localEndpoint) {
      return _RunMergeDecision.replaceLocal;
    }
    if (localEndpoint > incomingEndpoint) {
      return _RunMergeDecision.keepLocal;
    }
    if (incomingHead.createdAt != localHead.createdAt) {
      return incomingHead.createdAt > localHead.createdAt
          ? _RunMergeDecision.replaceLocal
          : _RunMergeDecision.keepLocal;
    }
    return incomingHead.chainHash.compareTo(localHead.chainHash) > 0
        ? _RunMergeDecision.replaceLocal
        : _RunMergeDecision.keepLocal;
  }

  Future<void> _clearReconciliationLane(String sessionId) async {
    await (_db.delete(
      _db.ledgerReconciliationCheckpoints,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.cardEvolutionCollectorRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.cardEvolutionObservations,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.cardEvolutionWriterCalls,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.cardEvolutionClaims,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationRunInvalidations,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationEffects,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.ledgerReconciliationSuccessfulRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.lorebookUseAcceptanceRecords,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.lorebookUseManifestEntries,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.lorebookUseManifests,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  }

  Future<void> _mergeSourceRows(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    for (final json in _maps(data['manifests'])) {
      final row = LorebookUseManifestRow.fromJson(json);
      _requireSession(sessionId, row.sessionId);
      final existing =
          await (_db.select(_db.lorebookUseManifests)..where(
                (table) =>
                    table.sessionId.equals(row.sessionId) &
                    table.messageId.equals(row.messageId) &
                    table.swipeId.equals(row.swipeId) &
                    table.agentSwipeId.equals(row.agentSwipeId),
              ))
              .getSingleOrNull();
      _requireExact(existing, row);
      if (existing == null) {
        await _db.into(_db.lorebookUseManifests).insert(row);
      }
    }
    for (final json in _maps(data['manifestEntries'])) {
      final row = LorebookUseManifestEntryRow.fromJson(json);
      _requireSession(sessionId, row.sessionId);
      final existing =
          await (_db.select(_db.lorebookUseManifestEntries)..where(
                (table) =>
                    table.sessionId.equals(row.sessionId) &
                    table.messageId.equals(row.messageId) &
                    table.swipeId.equals(row.swipeId) &
                    table.agentSwipeId.equals(row.agentSwipeId) &
                    table.lorebookId.equals(row.lorebookId) &
                    table.entryId.equals(row.entryId) &
                    table.entryOrder.equals(row.entryOrder),
              ))
              .getSingleOrNull();
      _requireExact(existing, row);
      if (existing == null) {
        await _db.into(_db.lorebookUseManifestEntries).insert(row);
      }
    }
    for (final json in _maps(data['acceptances'])) {
      final row = LorebookUseAcceptanceRecordRow.fromJson(json);
      _requireSession(sessionId, row.sessionId);
      final existing =
          await (_db.select(_db.lorebookUseAcceptanceRecords)
                ..where((table) => table.acceptanceId.equals(row.acceptanceId)))
              .getSingleOrNull();
      _requireExact(existing, row);
      if (existing == null) {
        await _db.into(_db.lorebookUseAcceptanceRecords).insert(row);
      }
    }
  }

  Future<bool> _mergeRuns(
    String sessionId,
    List<Map<String, dynamic>> incoming,
  ) async {
    incoming.sort(
      (a, b) => (a['ordinal'] as int).compareTo(b['ordinal'] as int),
    );
    final local =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
            .get();
    final overlap = local.length < incoming.length
        ? local.length
        : incoming.length;
    for (var i = 0; i < overlap; i++) {
      final cloud = LedgerReconciliationSuccessfulRunRow.fromJson(incoming[i]);
      if (!_sameDataClass(local[i], cloud)) {
        throw StateError('Divergent reconciliation chains for $sessionId');
      }
    }
    final repo = LedgerReconciliationRunRepo(_db);
    for (var i = local.length; i < incoming.length; i++) {
      final row = LedgerReconciliationSuccessfulRunRow.fromJson(incoming[i]);
      _requireSession(sessionId, row.sessionId);
      final result = await repo.append(_runFromRow(row));
      if (result is ReconciliationRunMalformed) return false;
      if (result is! ReconciliationRunAppended &&
          result is! ReconciliationRunIdempotent) {
        throw StateError(
          'Invalid reconciliation chain import: ${_integrityReason(result)}',
        );
      }
    }
    return true;
  }

  Future<void> _mergeEffects(
    String sessionId,
    List<Map<String, dynamic>> incoming,
    Map<String, String> runIdMap,
  ) async {
    final runs = {
      for (final run in await (_db.select(
        _db.ledgerReconciliationSuccessfulRuns,
      )..where((row) => row.sessionId.equals(sessionId))).get())
        run.id: run,
    };
    for (final json in incoming) {
      final original = LedgerReconciliationEffectRow.fromJson(json);
      _requireSession(sessionId, original.sessionId);
      final mappedRunId = runIdMap[original.runId];
      if (mappedRunId == null || !runs.containsKey(mappedRunId)) {
        throw StateError('Reconciliation effect references an unknown run');
      }
      final row = original.copyWith(runId: mappedRunId);
      final existing = await (_db.select(
        _db.ledgerReconciliationEffects,
      )..where((table) => table.runId.equals(mappedRunId))).getSingleOrNull();
      _requireExact(existing, row);
      if (existing == null) {
        await _db.into(_db.ledgerReconciliationEffects).insert(row);
      }
      final validation = await LedgerReconciliationRunRepo(
        _db,
      ).validateEffect(runs[mappedRunId]!);
      if (validation is! ReconciliationEffectValid) {
        throw StateError('Invalid reconciliation effect payload');
      }
    }
  }

  Future<void> _mergeInvalidations(
    String sessionId,
    List<Map<String, dynamic>> incoming, {
    bool ignoreUnknown = false,
  }) async {
    final runIds =
        (await (_db.select(
              _db.ledgerReconciliationSuccessfulRuns,
            )..where((row) => row.sessionId.equals(sessionId))).get())
            .map((row) => row.id)
            .toSet();
    for (final json in incoming) {
      final row = LedgerReconciliationRunInvalidationRow.fromJson(json);
      _requireSession(sessionId, row.sessionId);
      if (!runIds.contains(row.runId)) {
        if (ignoreUnknown) continue;
        throw StateError('Invalidation references an unknown run');
      }
      await _db
          .into(_db.ledgerReconciliationRunInvalidations)
          .insert(
            LedgerReconciliationRunInvalidationsCompanion.insert(
              sessionId: row.sessionId,
              runId: row.runId,
              causeMessageId: row.causeMessageId,
              reason: row.reason,
              createdAt: row.createdAt,
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  Future<bool> _resetDerivedLaneForInvalidations(
    String sessionId,
    List<Map<String, dynamic>> incomingCollectors,
  ) async {
    final invalidatedRunIds =
        (await (_db.select(
              _db.ledgerReconciliationRunInvalidations,
            )..where((row) => row.sessionId.equals(sessionId))).get())
            .map((row) => row.runId)
            .toSet();
    if (invalidatedRunIds.isEmpty) return false;
    final affectedCollector =
        await (_db.select(_db.cardEvolutionCollectorRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.reconciliationRunId.isIn(invalidatedRunIds))
              ..limit(1))
            .getSingleOrNull();
    final incomingAffected = incomingCollectors.any(
      (row) => invalidatedRunIds.contains(row['reconciliationRunId']),
    );
    if (affectedCollector == null && !incomingAffected) return false;
    await (_db.delete(
      _db.cardEvolutionCollectorRuns,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (_db.delete(
      _db.cardEvolutionObservations,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    return true;
  }

  Future<bool> _mergeCollectors(
    String sessionId,
    List<Map<String, dynamic>> incoming,
  ) async {
    final runRepo = LedgerReconciliationRunRepo(_db);
    final runs = await runRepo.readSession(sessionId);
    final pairs = <String, CardEvolutionCollectorPair>{};
    for (var i = 0; i + 1 < runs.length; i += 2) {
      final pair = CardEvolutionCollectorPair(runs[i], runs[i + 1]);
      pairs[pair.boundary.id] = pair;
    }
    final rows = incoming.map(CardEvolutionCollectorRunRow.fromJson).toList();
    for (final row in rows) {
      _requireSession(sessionId, row.sessionId);
      final pair = pairs[row.reconciliationRunId];
      if (row.status != 'completed' ||
          pair == null ||
          pair.boundary.ordinal != row.reconciliationRunOrdinal ||
          pair.boundary.chainHash != row.reconciliationChainHash ||
          pair.rangeHash != row.rangeHash) {
        return false;
      }
    }
    for (final row in rows) {
      final conflicts =
          await (_db.select(_db.cardEvolutionCollectorRuns)..where(
                (table) =>
                    table.sessionId.equals(sessionId) &
                    (table.collectorOrdinal.equals(row.collectorOrdinal) |
                        table.reconciliationRunId.equals(
                          row.reconciliationRunId,
                        )),
              ))
              .get();
      final completed = conflicts
          .where((existing) => existing.status == 'completed')
          .toList();
      for (final existing in completed) {
        _requireExact(existing, row, normalize: _collectorForSync);
      }
      final replaceableIds = conflicts
          .where((existing) => existing.status != 'completed')
          .map((existing) => existing.id)
          .toList();
      if (replaceableIds.isNotEmpty) {
        await (_db.delete(
          _db.cardEvolutionCollectorRuns,
        )..where((item) => item.id.isIn(replaceableIds))).go();
      }
      if (completed.isEmpty) {
        await _db
            .into(_db.cardEvolutionCollectorRuns)
            .insert(row.copyWith(ownerId: 'cloud-sync', leaseExpiresAt: 0));
      }
    }
    return true;
  }

  Future<void> _mergeObservations(
    String sessionId,
    List<Map<String, dynamic>> incoming,
  ) async {
    for (final json in incoming) {
      final cloud = CardEvolutionObservationRow.fromJson(json);
      _requireSession(sessionId, cloud.sessionId);
      final local =
          await (_db.select(_db.cardEvolutionObservations)..where(
                (row) =>
                    row.sessionId.equals(sessionId) &
                    row.semanticScopeKey.equals(cloud.semanticScopeKey),
              ))
              .getSingleOrNull();
      if (local == null) {
        await _db
            .into(_db.cardEvolutionObservations)
            .insert(
              cloud.copyWith(
                id: _observationId(sessionId, cloud.semanticScopeKey),
              ),
            );
        continue;
      }
      if (cloud.firstSeenRun != local.firstSeenRun) {
        if (cloud.firstSeenRun > local.firstSeenRun) {
          await (_db.update(
            _db.cardEvolutionObservations,
          )..where((row) => row.id.equals(local.id))).write(
            CardEvolutionObservationsCompanion(
              characterId: Value(cloud.characterId),
              runOrdinal: Value(cloud.runOrdinal),
              semanticScopeKey: Value(cloud.semanticScopeKey),
              observedChange: Value(cloud.observedChange),
              canonicalClaim: Value(cloud.canonicalClaim),
              evidenceMessageIds: Value(cloud.evidenceMessageIds),
              evidenceClustersJson: Value(cloud.evidenceClustersJson),
              retrievalKeysJson: Value(cloud.retrievalKeysJson),
              targetKind: Value(cloud.targetKind),
              cardFieldPath: Value(cloud.cardFieldPath),
              lorebookEntryId: Value(cloud.lorebookEntryId),
              confidence: Value(cloud.confidence),
              status: Value(cloud.status),
              firstSeenRun: Value(cloud.firstSeenRun),
              repeatCount: Value(cloud.repeatCount),
              lastConfirmedRun: Value(cloud.lastConfirmedRun),
              updatedAt: Value(cloud.updatedAt),
            ),
          );
        }
        continue;
      }
      if (local.characterId != cloud.characterId ||
          local.targetKind != cloud.targetKind ||
          local.cardFieldPath != cloud.cardFieldPath ||
          local.lorebookEntryId != cloud.lorebookEntryId ||
          local.observedChange != cloud.observedChange ||
          local.canonicalClaim != cloud.canonicalClaim) {
        throw StateError('Divergent observation identity');
      }
      final clusters = _mergeClusters(
        local.evidenceClustersJson,
        cloud.evidenceClustersJson,
      );
      final evidence = <String>{for (final cluster in clusters) ...cluster};
      final retrievalKeys = <String>{
        ..._strings(local.retrievalKeysJson),
        ..._strings(cloud.retrievalKeysJson),
      }.toList()..sort();
      await (_db.update(
        _db.cardEvolutionObservations,
      )..where((row) => row.id.equals(local.id))).write(
        CardEvolutionObservationsCompanion(
          evidenceClustersJson: Value(jsonEncode(clusters)),
          evidenceMessageIds: Value(jsonEncode(evidence.toList()..sort())),
          retrievalKeysJson: Value(jsonEncode(retrievalKeys)),
          runOrdinal: Value(
            local.runOrdinal < cloud.runOrdinal
                ? local.runOrdinal
                : cloud.runOrdinal,
          ),
          repeatCount: Value(clusters.length),
          firstSeenRun: Value(local.firstSeenRun),
          lastConfirmedRun: Value(
            _maxNullable(local.lastConfirmedRun, cloud.lastConfirmedRun),
          ),
          confidence: Value(
            local.confidence > cloud.confidence
                ? local.confidence
                : cloud.confidence,
          ),
          status: Value(_mergedObservationStatus(local.status, cloud.status)),
          updatedAt: Value(
            local.updatedAt > cloud.updatedAt
                ? local.updatedAt
                : cloud.updatedAt,
          ),
        ),
      );
    }
  }

  Future<void> _mergeCompletedClaims(
    String sessionId,
    List<Map<String, dynamic>> incoming,
  ) async {
    for (final json in incoming) {
      final row = CardEvolutionClaimRow.fromJson({
        ...json,
        'selectedInputJson': json['selectedInputJson'],
        'writerOptionsJson': json['writerOptionsJson'] ?? '{}',
        'failureCode': json['failureCode'],
        'failureDetail': json['failureDetail'],
        'failedAt': json['failedAt'],
      });
      _requireSession(sessionId, row.sessionId);
      if (row.status != 'completed') continue;
      final boundary =
          await (_db.select(_db.cardEvolutionCollectorRuns)..where(
                (item) =>
                    item.sessionId.equals(sessionId) &
                    item.collectorOrdinal.equals(row.predecessorRunOrdinal) &
                    item.status.equals('completed'),
              ))
              .getSingleOrNull();
      if (boundary == null ||
          boundary.reconciliationChainHash != row.predecessorCursorHash) {
        continue;
      }
      final existing =
          await (_db.select(_db.cardEvolutionClaims)..where(
                (item) =>
                    item.sessionId.equals(sessionId) &
                    item.inputHash.equals(row.inputHash),
              ))
              .getSingleOrNull();
      if (existing != null && existing.status == 'claimed') {
        await (_db.delete(
          _db.cardEvolutionClaims,
        )..where((item) => item.id.equals(existing.id))).go();
      }
      final completed = existing?.status == 'completed' ? existing : null;
      if (completed == null) {
        await _db
            .into(_db.cardEvolutionClaims)
            .insert(
              row.copyWith(
                ownerId: 'cloud-sync',
                leaseExpiresAt: 0,
                rewriteJobId: const Value(null),
              ),
            );
      } else if (!_sameDataClass(completed, row, normalize: _claimForSync)) {
        throw StateError('Conflicting completed writer boundary');
      }
    }
  }

  static void _requireExact(
    DataClass? existing,
    DataClass incoming, {
    Map<String, dynamic> Function(DataClass row)? normalize,
  }) {
    if (existing != null &&
        !_sameDataClass(existing, incoming, normalize: normalize)) {
      throw StateError('Conflicting immutable sync row');
    }
  }

  static bool _sameDataClass(
    DataClass first,
    DataClass second, {
    Map<String, dynamic> Function(DataClass row)? normalize,
  }) {
    final firstJson = normalize?.call(first) ?? first.toJson();
    final secondJson = normalize?.call(second) ?? second.toJson();
    return jsonEncode(firstJson) == jsonEncode(secondJson);
  }

  static Map<String, dynamic> _collectorForSync(DataClass value) {
    final row = value as CardEvolutionCollectorRunRow;
    return {...row.toJson(), 'ownerId': '', 'leaseExpiresAt': 0};
  }

  static Map<String, dynamic> _invalidationForSync(
    LedgerReconciliationRunInvalidationRow row,
  ) => {...row.toJson(), 'id': 0};

  static Map<String, dynamic> _observationForSync(
    CardEvolutionObservationRow row,
  ) => {
    ...row.toJson(),
    'id': _observationId(row.sessionId, row.semanticScopeKey),
  };

  static String _observationId(String sessionId, String semanticScopeKey) =>
      'cloud-observation-${computeHash('$sessionId\u001f$semanticScopeKey')}';

  static String _manifestKey(LorebookUseManifestRow row) =>
      '${row.messageId}\u001f${row.swipeId}\u001f${row.agentSwipeId}';

  static String _manifestEntryKey(LorebookUseManifestEntryRow row) =>
      '${row.messageId}\u001f${row.swipeId}\u001f${row.agentSwipeId}'
      '\u001f${row.lorebookId}\u001f${row.entryId}\u001f${row.entryOrder}';

  static Map<String, dynamic> _claimForSync(DataClass value) {
    final row = value as CardEvolutionClaimRow;
    return {
      ...row.toJson(),
      'ownerId': '',
      'leaseExpiresAt': 0,
      'rewriteJobId': null,
      'selectedInputJson': null,
      'writerOptionsJson': '{}',
      'failureCode': null,
      'failureDetail': null,
      'failedAt': null,
    };
  }

  LedgerReconciliationRun _runFromRow(
    LedgerReconciliationSuccessfulRunRow row,
  ) {
    final anchors = (jsonDecode(row.anchorsJson) as List)
        .cast<Map<String, dynamic>>()
        .map(
          (item) => ReconciliationAnchor(
            messageId: item['messageId'] as String,
            swipeId: item['swipeId'] as int,
            agentSwipeId: item['agentSwipeId'] as int,
            role: item['role'] as String,
            contentHash: item['contentHash'] as String,
          ),
        )
        .toList();
    final refs = (jsonDecode(row.acceptedManifestRefsJson) as List)
        .cast<Map<String, dynamic>>()
        .map(
          (item) => AcceptedManifestRef(
            acceptanceId: item['acceptanceId'] as String,
            sessionId: item['sessionId'] as String,
            messageId: item['messageId'] as String,
            swipeId: item['swipeId'] as int,
            agentSwipeId: item['agentSwipeId'] as int,
            manifestHash: item['manifestHash'] as String,
            acceptedByUserMessageId: item['acceptedByUserMessageId'] as String,
          ),
        )
        .toList();
    return LedgerReconciliationRun(
      id: row.id,
      sessionId: row.sessionId,
      ordinal: row.ordinal,
      anchors: anchors,
      acceptedManifestRefs: refs,
      effectiveCanonStamp: row.effectiveCanonStamp,
      effectiveCanonRevision: row.effectiveCanonRevision,
      effectiveCanonHash: row.effectiveCanonHash,
      canonicalResult: Map<String, dynamic>.from(
        jsonDecode(row.canonicalResultJson) as Map,
      ),
      predecessorChainHash: row.predecessorChainHash,
      contractVersion: row.contractVersion,
      opsApplied: (jsonDecode(row.opsAppliedJson) as List).cast<String>(),
      createdAt: row.createdAt,
    );
  }

  static List<Map<String, dynamic>> _maps(Object? value) =>
      (value as List? ?? const []).cast<Map<String, dynamic>>();

  static List<String> _strings(String value) =>
      (jsonDecode(value) as List).cast<String>();

  static void _requireSession(String expected, String actual) {
    if (actual != expected) throw const FormatException('Session mismatch');
  }

  static List<List<String>> _mergeClusters(String first, String second) {
    final result = <List<String>>[];
    for (final encoded in [first, second]) {
      for (final raw in jsonDecode(encoded) as List) {
        final cluster = (raw as List).cast<String>().toSet().toList()..sort();
        if (!result.any((item) => _sameStrings(item, cluster))) {
          result.add(cluster);
        }
      }
    }
    result.sort((a, b) => a.join('\u001f').compareTo(b.join('\u001f')));
    return result;
  }

  static bool _sameStrings(List<String> a, List<String> b) =>
      a.length == b.length && a.indexed.every((item) => item.$2 == b[item.$1]);

  static int? _maxNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  static String _mergedObservationStatus(String a, String b) {
    const rank = {'active': 0, 'promoted': 1, 'expired': 2, 'consumed': 3};
    return rank[a]! >= rank[b]! ? a : b;
  }

  @override
  Future<void> deleteBySessionId(String sessionId) async {
    await _db.transaction(() async {
      await _clearReconciliationLane(sessionId);
    });
  }
}

Map<String, dynamic> _emptyPayload(String sessionId) => {
  '__reconciliationState': true,
  'schemaVersion': 2,
  'sessionId': sessionId,
  'runs': <dynamic>[],
  'effects': <dynamic>[],
  'invalidations': <dynamic>[],
  'manifests': <dynamic>[],
  'manifestEntries': <dynamic>[],
  'acceptances': <dynamic>[],
  'collectors': <dynamic>[],
  'observations': <dynamic>[],
  'completedClaims': <dynamic>[],
};

String _integrityReason(ReconciliationRunIntegrity integrity) =>
    switch (integrity) {
      ReconciliationRunMalformed(:final reason) => reason,
      ReconciliationRunChainGap(:final reason) => reason,
      ReconciliationRunConcurrencyConflict(:final reason) => reason,
      ReconciliationRunConflict(:final reason) => reason,
      _ => integrity.runtimeType.toString(),
    };

enum _RunMergeDecision { merge, keepLocal, replaceLocal }

final class _NormalizedReconciliationPayload {
  const _NormalizedReconciliationPayload({
    required this.runs,
    required this.invalidations,
    required this.idMap,
    required this.identitiesChanged,
  });

  final List<Map<String, dynamic>> runs;
  final List<Map<String, dynamic>> invalidations;
  final Map<String, String> idMap;
  final bool identitiesChanged;
}
