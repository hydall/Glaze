import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_db.dart';
import '../tables.dart';
import '../../models/memory_book.dart';
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
  Future<void> put(MemoryBook book) async {
    final existing = await getBySessionId(book.sessionId);
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

  /// Atomically removes all `MemoryEntry` and `MemoryDraft` items whose
  /// `messageIds` contain [messageId] from the memory book for [sessionId].
  /// Wraps the read-modify-write in a transaction (database.md Rule 3).
  ///
  /// Called by `ChatMessageService.deleteMessage` so deleting an assistant
  /// message also drops the memory entries/drafts that were sourced from it.
  /// Items whose `messageIds` does NOT contain [messageId] are preserved
  /// (they were sourced from other messages and should survive).
  Future<void> deleteForMessage(String sessionId, String messageId) async {
    await deleteForMessages(sessionId, {messageId});
  }

  /// Atomically removes entries and drafts sourced from any deleted message.
  Future<void> deleteForMessages(
    String sessionId,
    Set<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    await transaction(() async {
      final existing = await getBySessionId(sessionId);
      if (existing == null) return;
      final keptEntries = existing.entries
          .where((e) => !e.messageIds.any(messageIds.contains))
          .toList();
      final keptDrafts = existing.pendingDrafts
          .where((d) => !d.messageIds.any(messageIds.contains))
          .toList();
      if (keptEntries.length == existing.entries.length &&
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
  }) async {
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
              !belongsToMessage(entry.messageIds) ||
              !removeAnchor(entry.sourceSwipeId, entry.sourceAgentSwipeId),
        )
        .map(
          (entry) => !belongsToMessage(entry.messageIds)
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
              !belongsToMessage(draft.messageIds) ||
              !removeAnchor(draft.sourceSwipeId, draft.sourceAgentSwipeId),
        )
        .map(
          (draft) => !belongsToMessage(draft.messageIds)
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
  }

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
