import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_db.dart';
import '../tables.dart';
import '../../models/memory_book.dart';
import '../../models/memory_entry_revisions.dart';
import '../../services/memory_prompt_presets.dart';
import '../../state/memory_settings_provider.dart';
import '../../utils/time_helpers.dart';
import '../../application/sync_repo_interfaces.dart';

part 'memory_book_repo.g.dart';

@DriftAccessor(tables: [MemoryBookRows])
class MemoryBookRepo extends DatabaseAccessor<AppDatabase>
    with _$MemoryBookRepoMixin
    implements SyncMemoryBookStore {
  MemoryBookRepo(super.db, this._ref);

  final Ref _ref;

  Future<MemoryBook> ensureForSession(String sessionId) async {
    final existing = await getBySessionId(sessionId);
    if (existing != null) return existing;
    final global = _ref.read(memoryGlobalSettingsProvider);
    final book = MemoryBook(
      id: 'memorybook_$sessionId',
      sessionId: sessionId,
      settings: MemoryBookSettings(
        enabled: global.enabled,
        memoryMode: global.memoryMode,
        autoCreateEnabled: global.autoCreateEnabled,
        autoGenerateEnabled: global.autoGenerateEnabled,
        maxInjectedEntries: global.maxInjectedEntries,
        memoryExcerptingEnabled: global.memoryExcerptingEnabled,
        memoryPackingMode: global.memoryPackingMode,
        memoryExcerptTokensPerChunk: global.memoryExcerptTokensPerChunk,
        memoryExcerptChunksPerEntry: global.memoryExcerptChunksPerEntry,
        chunkFirstTopEntries: global.chunkFirstTopEntries,
        chunkFirstTopChunks: global.chunkFirstTopChunks,
        maxInjectedTokens: global.maxInjectedTokens,
        memoryBudgetPreset: global.memoryBudgetPreset,
        autoCreateInterval: global.autoCreateInterval,
        autoCreateLagMessages: global.autoCreateLagMessages,
        useDelayedAutomation: global.useDelayedAutomation,
        injectionTarget: global.injectionTarget,
        batchSize: global.batchSize,
        vectorSearchEnabled: global.vectorSearchEnabled,
        keyMatchMode: global.keyMatchMode,
        promptPreset: global.promptPreset,
        diversityAware: global.diversityAware,
        diversityPenalty: global.diversityPenalty,
        recencyBoost: global.recencyBoost,
        recencyHalfLifeDays: global.recencyHalfLifeDays,
        importanceBoost: global.importanceBoost,
        importanceWeight: global.importanceWeight,
        sourceWindowExclusion: global.sourceWindowExclusion,
        factualContinuityGuardEnabled: global.factualContinuityGuardEnabled,
        queryIncludeAssistant: global.queryIncludeAssistant,
        queryRecentTurns: global.queryRecentTurns,
        queryMaxChars: global.queryMaxChars,
        cadenceInterval: global.cadenceInterval,
      ),
    );
    await put(book);
    return book;
  }

  @override
  Future<List<MemoryBook>> getAll() async {
    final rows = await select(memoryBookRows).get();
    return rows.map(_rowToModel).toList();
  }

  @override
  Future<void> put(MemoryBook book) => transaction(() => _put(book));

  Future<void> _put(MemoryBook book) async {
    final existing = await getBySessionId(book.sessionId);
    final priorEntries = {
      for (final entry in existing?.entries ?? const <MemoryEntry>[])
        entry.id: entry,
    };
    book = book.copyWith(
      entries: book.entries
          .map(
            (entry) =>
                MemoryEntryRevisions.prepare(entry, priorEntries[entry.id]),
          )
          .toList(),
    );
    final retiredEntryIds = <String>{
      ...?existing?.entries
          .where((entry) => entry.source == 'agentic')
          .map((entry) => entry.id),
      ...book.entries
          .where((entry) => entry.source == 'agentic')
          .map((entry) => entry.id),
    };
    final sanitized = book.copyWith(
      entries: book.entries
          .where((entry) => entry.source != 'agentic')
          .toList(),
      pendingDrafts: book.pendingDrafts
          .where((draft) => draft.source != 'agentic')
          .toList(),
    );

    await into(memoryBookRows).insertOnConflictUpdate(
      MemoryBookRowsCompanion.insert(
        sessionId: sanitized.sessionId,
        entriesJson: Value(
          jsonEncode(sanitized.entries.map((e) => e.toJson()).toList()),
        ),
        pendingDraftsJson: Value(
          jsonEncode(sanitized.pendingDrafts.map((d) => d.toJson()).toList()),
        ),
        settingsJson: Value(jsonEncode(sanitized.settings.toJson())),
        lastProcessedMessageCount: Value(sanitized.lastProcessedMessageCount),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
    for (final entryId in retiredEntryIds) {
      await customStatement('DELETE FROM embeddings WHERE entry_id = ?', [
        entryId,
      ]);
      await customStatement(
        'DELETE FROM memory_catalog_rows WHERE memory_entry_id = ?',
        [entryId],
      );
      await customStatement(
        'DELETE FROM memory_entity_rows WHERE memory_entry_id = ?',
        [entryId],
      );
      await customStatement(
        'DELETE FROM memory_salience_rows WHERE memory_entry_id = ?',
        [entryId],
      );
    }
  }

  Future<void> updateSettings(String sessionId, MemoryBookSettings settings) {
    return (update(
      memoryBookRows,
    )..where((t) => t.sessionId.equals(sessionId))).write(
      MemoryBookRowsCompanion(
        settingsJson: Value(jsonEncode(settings.toJson())),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  /// Checks that the exact entries selected for a prepared request are still
  /// active and unchanged. Historical source validation belongs to the
  /// historical-request path; ordinary sends do not rescan old chat text.
  Future<bool> areEntriesCurrent(
    String sessionId,
    Iterable<MemoryEntry> used,
  ) => transaction(() async {
    final book = await getBySessionId(sessionId);
    for (final entry in used) {
      final current = book?.entries.where((e) => e.id == entry.id).firstOrNull;
      if (current == null || current != entry || current.status != 'active') {
        return false;
      }
    }
    return true;
  });

  /// Approval and source validation share a transaction with the durable chat.
  Future<MemoryBook?> approveDraft(
    String sessionId,
    String draftId,
    MemoryDraft expected,
  ) => transaction(() async {
    final book = await getBySessionId(sessionId);
    if (book == null) return null;
    final draft = book.pendingDrafts.where((d) => d.id == draftId).firstOrNull;
    if (draft == null) return null;
    if (jsonEncode(draft.toJson()) != jsonEncode(expected.toJson())) {
      throw StateError('Memory draft changed. Reload it before approval.');
    }
    if (draft.content.trim().isEmpty) return null;
    final entry = MemoryEntryRevisions.initialize(
      MemoryEntry(
        id: draft.id.replaceAll('draft_', 'mem_'),
        title: draft.title,
        content: draft.content,
        keys: draft.keys,
        keyParagraphs: draft.keyParagraphs,
        ledgerRange: draft.ledgerRange,
        vectorSearch: draft.vectorSearch,
        messageIds: draft.messageIds,
        messageRange: draft.messageRange,
        sourceManifest: draft.sourceManifest,
        sourceSwipeId: draft.sourceSwipeId,
        sourceAgentSwipeId: draft.sourceAgentSwipeId,
        source: draft.source,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      reason: 'approved_generation',
      reviewer: 'user',
    );
    final updated = book.copyWith(
      entries: [...book.entries, entry],
      pendingDrafts: book.pendingDrafts.where((d) => d.id != draftId).toList(),
    );
    await put(updated);
    return getBySessionId(sessionId);
  });

  /// Repairs prompt selections after the complete set of available presets
  /// changes. Only the settings JSON of affected existing books is updated.
  /// Entries, drafts, cursors, and all unrelated settings remain untouched.
  Future<int> repairPromptPresetSelections(
    Iterable<String> customPresetKeys,
  ) async {
    final safeKeys = {
      ...MemoryPromptPresets.builtIn.map((preset) => preset.key),
      ...customPresetKeys,
    };
    var repaired = 0;
    await transaction(() async {
      final rows = await select(memoryBookRows).get();
      for (final row in rows) {
        final Map<String, dynamic> rawSettings;
        try {
          final decoded = jsonDecode(row.settingsJson);
          if (decoded is! Map<String, dynamic>) continue;
          rawSettings = decoded;
        } catch (_) {
          continue;
        }
        final normalized = MemoryPromptPresets.normalizeSerializedSelection(
          rawSettings,
          safeKeys,
        );
        if (identical(normalized, rawSettings)) continue;
        await (update(
          memoryBookRows,
        )..where((table) => table.sessionId.equals(row.sessionId))).write(
          MemoryBookRowsCompanion(
            settingsJson: Value(jsonEncode(normalized)),
            updatedAt: Value(currentTimestampSeconds()),
          ),
        );
        repaired++;
      }
    });
    return repaired;
  }

  /// Atomically appends [drafts] to the pending drafts of the memory book
  /// for [sessionId]. Wraps the read-modify-write in a transaction so
  /// concurrent writes cannot interleave (database.md Rule 3).
  ///
  /// Used by user-directed MemoryBook draft workflows without racing with
  /// other MemoryBook writes.
  Future<void> appendDrafts(String sessionId, List<MemoryDraft> drafts) async {
    if (drafts.isEmpty) return;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      final book =
          existing ??
          MemoryBook(id: 'memorybook_$sessionId', sessionId: sessionId);
      await put(
        book.copyWith(pendingDrafts: [...book.pendingDrafts, ...drafts]),
      );
    });
  }

  /// Applies a narrow mutation to one draft using the latest durable book.
  /// Returns false when the book or draft was removed while work was in flight.
  Future<bool> mutateDraft({
    required String sessionId,
    required String draftId,
    required MemoryDraft Function(MemoryDraft current) mutate,
  }) async {
    var updated = false;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final index = existing.pendingDrafts.indexWhere((d) => d.id == draftId);
      if (index < 0) return;
      final drafts = [...existing.pendingDrafts];
      drafts[index] = mutate(drafts[index]);
      await put(existing.copyWith(pendingDrafts: drafts));
      updated = true;
    });
    return updated;
  }

  /// Atomically appends [entries] to the approved entries of the memory book
  /// for [sessionId]. Wraps the read-modify-write in a transaction so
  /// concurrent writes cannot interleave (database.md Rule 3).
  ///
  /// Callers must validate [entries] before appending them.
  Future<void> appendApprovedEntries(
    String sessionId,
    List<MemoryEntry> entries,
  ) async {
    if (entries.isEmpty) return;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      final book =
          existing ??
          MemoryBook(id: 'memorybook_$sessionId', sessionId: sessionId);
      await put(book.copyWith(entries: [...book.entries, ...entries]));
    });
  }

  /// Atomically replaces the entry with [entryId] in the memory book for
  /// [sessionId] with [updated]. Wraps the read-modify-write in a transaction
  /// (database.md Rule 3). Used by the memory dedup service to merge
  /// near-duplicate entries.
  ///
  /// Returns true if the entry was found and updated, false otherwise.
  Future<bool> updateEntry({
    required String sessionId,
    required String entryId,
    required MemoryEntry updated,
  }) async {
    var didUpdate = false;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final idx = existing.entries.indexWhere((e) => e.id == entryId);
      if (idx < 0) return;
      didUpdate = true;
      final updatedEntries = List<MemoryEntry>.from(existing.entries);
      updatedEntries[idx] = updated;
      await put(existing.copyWith(entries: updatedEntries));
    });
    return didUpdate;
  }

  /// Applies an editor result only if [expected] is still the durable entry.
  /// Text changes append a revision; the previous active snapshot is never
  /// replaced or deleted.
  Future<MemoryEntry?> reviseEntry({
    required String sessionId,
    required MemoryEntry expected,
    required MemoryEntry proposed,
    String reason = 'manual_edit',
  }) => transaction(() async {
    final book = await getBySessionId(sessionId);
    final current = book?.entries
        .where((entry) => entry.id == expected.id)
        .firstOrNull;
    if (book == null || current == null) return null;
    final normalizedExpected = MemoryEntryRevisions.initialize(expected);
    final normalizedCurrent = MemoryEntryRevisions.initialize(current);
    if (normalizedCurrent != normalizedExpected || proposed.id != current.id) {
      throw StateError('Memory changed while editing. Reload before saving.');
    }
    final edited = current.copyWith(
      title: proposed.title,
      content: proposed.content,
      keys: proposed.keys,
      keyParagraphs: proposed.keyParagraphs,
      ledgerRange: proposed.ledgerRange,
    );
    final revised = MemoryEntryRevisions.prepare(
      edited,
      current,
      author: 'user',
      reason: reason,
      reviewer: 'user',
    );
    await put(
      book.copyWith(
        entries: book.entries
            .map((entry) => entry.id == current.id ? revised : entry)
            .toList(),
      ),
    );
    return revised;
  });

  /// Restores the text from [revisionId] by appending a new active revision.
  /// The historical revision remains untouched and the active pointer never
  /// moves backwards.
  Future<MemoryEntry?> restoreEntryRevision({
    required String sessionId,
    required MemoryEntry expected,
    required String revisionId,
  }) async {
    final current = await getBySessionId(sessionId).then(
      (book) =>
          book?.entries.where((entry) => entry.id == expected.id).firstOrNull,
    );
    if (current == null) return null;
    final restored = MemoryEntryRevisions.restoreRevision(current, revisionId);
    return reviseEntry(
      sessionId: sessionId,
      expected: expected,
      proposed: restored,
      reason: 'restore_revision',
    );
  }

  /// Atomically removes the entry with [entryId] from the memory book for
  /// [sessionId]. Wraps the read-modify-write in a transaction (database.md
  /// Rule 3). Used by the memory dedup service to drop redundant entries.
  ///
  /// Returns true if the entry was found and deleted, false otherwise.
  Future<bool> deleteEntry({
    required String sessionId,
    required String entryId,
  }) async {
    var didDelete = false;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final kept = existing.entries.where((e) => e.id != entryId).toList();
      if (kept.length == existing.entries.length) return;
      didDelete = true;
      await put(existing.copyWith(entries: kept));
    });
    return didDelete;
  }

  /// Retains manifested history as invalid evidence when its source is deleted.
  /// Legacy records retain their existing deletion behavior.
  Future<void> deleteForMessage(String sessionId, String messageId) async {
    await deleteForMessages(sessionId, {messageId});
  }

  /// Atomically invalidates manifested records and removes legacy dependants.
  Future<void> deleteForMessages(
    String sessionId,
    Set<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final keptEntries = existing.entries
          .where(
            (e) =>
                e.sourceManifest != null ||
                !e.messageIds.any(messageIds.contains),
          )
          .map(
            (e) =>
                e.sourceManifest != null &&
                    e.messageIds.any(messageIds.contains)
                ? e.copyWith(sourceManifest: e.sourceManifest!.invalidate())
                : e,
          )
          .toList();
      final keptDrafts = existing.pendingDrafts
          .where(
            (d) =>
                d.sourceManifest != null ||
                !d.messageIds.any(messageIds.contains),
          )
          .map(
            (d) =>
                d.sourceManifest != null &&
                    d.messageIds.any(messageIds.contains)
                ? d.copyWith(
                    sourceManifest: d.sourceManifest!.invalidate(),
                    status: 'needs_regeneration',
                  )
                : d,
          )
          .toList();
      if (!existing.entries.any((e) => e.messageIds.any(messageIds.contains)) &&
          !existing.pendingDrafts.any(
            (d) => d.messageIds.any(messageIds.contains),
          ) &&
          keptEntries.length == existing.entries.length &&
          keptDrafts.length == existing.pendingDrafts.length) {
        return;
      }
      await put(
        existing.copyWith(entries: keptEntries, pendingDrafts: keptDrafts),
      );
    });
  }

  Future<void> deleteSwipeAndShift({
    required String sessionId,
    required String messageId,
    required int removedSwipeId,
  }) => _deleteVariationAndShift(
    sessionId: sessionId,
    messageId: messageId,
    removedSwipeId: removedSwipeId,
  );

  Future<void> deleteAgentSwipeAndShift({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int removedAgentSwipeId,
  }) => _deleteVariationAndShift(
    sessionId: sessionId,
    messageId: messageId,
    removedSwipeId: swipeId,
    removedAgentSwipeId: removedAgentSwipeId,
  );

  Future<void> _deleteVariationAndShift({
    required String sessionId,
    required String messageId,
    required int removedSwipeId,
    int? removedAgentSwipeId,
  }) => transaction(() async {
    final existing = await getBySessionId(sessionId);
    if (existing == null) return;

    bool belongsToMessage(List<String> ids) => ids.contains(messageId);
    bool removeAnchor(int swipeId, int agentSwipeId) =>
        swipeId == removedSwipeId &&
        (removedAgentSwipeId == null || agentSwipeId == removedAgentSwipeId);
    int shiftedSwipe(int value) =>
        removedAgentSwipeId == null && value > removedSwipeId
        ? value - 1
        : value;
    int shiftedAgent(int swipeId, int value) =>
        removedAgentSwipeId != null &&
            swipeId == removedSwipeId &&
            value > removedAgentSwipeId
        ? value - 1
        : value;

    final entries = existing.entries
        .where(
          (entry) =>
              entry.sourceManifest != null ||
              !belongsToMessage(entry.messageIds) ||
              !removeAnchor(entry.sourceSwipeId, entry.sourceAgentSwipeId),
        )
        .map(
          (entry) => entry.sourceManifest != null
              ? entry.copyWith(
                  sourceManifest: entry.sourceManifest!.removeVariation(
                    messageId,
                    removedSwipeId,
                    removedAgentSwipeId,
                  ),
                )
              : !belongsToMessage(entry.messageIds)
              ? entry
              : entry.copyWith(
                  sourceSwipeId: shiftedSwipe(entry.sourceSwipeId),
                  sourceAgentSwipeId: shiftedAgent(
                    entry.sourceSwipeId,
                    entry.sourceAgentSwipeId,
                  ),
                ),
        )
        .toList();
    final drafts = existing.pendingDrafts
        .where(
          (draft) =>
              draft.sourceManifest != null ||
              !belongsToMessage(draft.messageIds) ||
              !removeAnchor(draft.sourceSwipeId, draft.sourceAgentSwipeId),
        )
        .map(
          (draft) => draft.sourceManifest != null
              ? draft.copyWith(
                  sourceManifest: draft.sourceManifest!.removeVariation(
                    messageId,
                    removedSwipeId,
                    removedAgentSwipeId,
                  ),
                )
              : !belongsToMessage(draft.messageIds)
              ? draft
              : draft.copyWith(
                  sourceSwipeId: shiftedSwipe(draft.sourceSwipeId),
                  sourceAgentSwipeId: shiftedAgent(
                    draft.sourceSwipeId,
                    draft.sourceAgentSwipeId,
                  ),
                ),
        )
        .toList();
    await put(existing.copyWith(entries: entries, pendingDrafts: drafts));
  });

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required Set<String> messageIds,
  }) async {
    final source = await getBySessionId(fromSessionId);
    if (source == null) return;
    bool isRetained(List<String> sourceIds) =>
        sourceIds.isNotEmpty && sourceIds.every(messageIds.contains);
    await put(
      source.copyWith(
        id: 'memorybook_$toSessionId',
        sessionId: toSessionId,
        entries: source.entries
            .where((entry) => isRetained(entry.messageIds))
            .map((entry) => entry.copyWith(id: '${entry.id}@$toSessionId'))
            .toList(),
        pendingDrafts: source.pendingDrafts
            .where((draft) => isRetained(draft.messageIds))
            .map((draft) => draft.copyWith(id: '${draft.id}@$toSessionId'))
            .toList(),
        // Derived indexes are intentionally not copied. Reprocessing the
        // retained history is safer than inheriting an opaque source cursor.
        lastProcessedMessageCount: 0,
      ),
    );
  }

  @override
  Future<void> deleteBySessionId(String sessionId) {
    return (delete(
      memoryBookRows,
    )..where((t) => t.sessionId.equals(sessionId))).go();
  }

  @override
  Future<MemoryBook?> getBySessionId(String sessionId) async {
    final row = await (select(
      memoryBookRows,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    return _rowToModel(row);
  }

  MemoryBook _rowToModel(MemoryBookRow row) {
    List<MemoryEntry> entries;
    try {
      final list = jsonDecode(row.entriesJson) as List<dynamic>;
      entries = list
          .map((e) => MemoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      entries = [];
    }

    List<MemoryDraft> pendingDrafts;
    try {
      final list = jsonDecode(row.pendingDraftsJson) as List<dynamic>;
      pendingDrafts = list
          .map((e) => MemoryDraft.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      pendingDrafts = [];
    }

    MemoryBookSettings settings;
    try {
      settings = MemoryBookSettings.fromJson(
        jsonDecode(row.settingsJson) as Map<String, dynamic>,
      );
    } catch (_) {
      settings = const MemoryBookSettings();
    }

    return MemoryBook(
      id: 'memorybook_${row.sessionId}',
      sessionId: row.sessionId,
      entries: entries,
      pendingDrafts: pendingDrafts,
      settings: settings,
      lastProcessedMessageCount: row.lastProcessedMessageCount,
      updatedAt: row.updatedAt,
    );
  }
}
