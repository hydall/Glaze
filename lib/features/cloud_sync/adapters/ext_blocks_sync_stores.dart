import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/character_folder_repo.dart';
import '../../../core/db/repositories/extension_presets_repository.dart';
import '../../../core/db/repositories/info_blocks_repository.dart';
import '../../../core/db/repositories/summary_repo.dart';
import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/db/repositories/tracker_repo.dart';
import '../../../core/models/tracker.dart';
import '../../../core/models/tracker_snapshot.dart';
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
    await _repo.put(
      sessionId: sessionId,
      content: summary['content'] as String? ?? '',
      messageCount: summary['messageCount'] as int? ?? 0,
      enabled: summary['enabled'] as bool?,
      prompt: summary['prompt'] as String?,
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
