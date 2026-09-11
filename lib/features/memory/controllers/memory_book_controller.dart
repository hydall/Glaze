import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/memory_injection_service.dart';
import '../../../core/llm/memory_draft_planner.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/memory_book_ops_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/state/pipeline_settings_provider.dart';
import '../../chat/chat_provider.dart';
import '../../settings/api_list_provider.dart';
import 'memory_book_write_queue.dart';
import 'memory_draft_generation_controller.dart';
import 'memory_settings_mapper.dart';

/// Controller for memory book operations, separating business logic from UI.
///
/// Thin orchestrator: owns the [MemoryBook] + entry/index CRUD + settings
/// mapping + reindex, and delegates the draft-generation lifecycle (active
/// set, cancel tokens, elapsed timer, memory-workflow leases) to
/// [MemoryDraftGenerationController].
class MemoryBookController {
  final WidgetRef _ref;
  final String _sessionId;
  final String _charId;

  MemoryBook? _book;
  bool _loading = true;
  bool _isReindexing = false;
  final MemorySettingsMapper _settingsMapper = const MemorySettingsMapper();
  late final MemoryBookWriteQueue _bookWrites = MemoryBookWriteQueue(
    readLatest: () => _book,
    publish: (book) => _book = book,
    persist: (book) => _ref.read(memoryBookOpsProvider).saveMemoryBook(book),
  );
  late final MemoryDraftGenerationController _draftGen =
      MemoryDraftGenerationController(
        ref: _ref,
        charId: _charId,
        sessionId: _sessionId,
        settingsMapper: _settingsMapper,
        bookGetter: () => _book,
        persistMutation: _bookWrites.mutate,
      );

  MemoryBookController(this._ref, this._sessionId, this._charId);

  MemoryBook? get book => _book;
  bool get loading => _loading;
  bool get isReindexing => _isReindexing;
  Map<String, bool> get generatingDrafts => _draftGen.generatingDrafts;
  Map<String, DateTime> get genStartTimes => _draftGen.genStartTimes;

  MemoryGlobalSettings get globalSettings =>
      _ref.read(memoryGlobalSettingsProvider);

  /// Global pipeline LLM settings (singleton, SharedPreferences-backed).
  PipelineSettings get pipelineSettings => _ref.read(pipelineSettingsProvider);

  /// Returns the global [PipelineSettings]. Kept as a method for call-site
  /// compatibility — pipeline settings are now a singleton global, so this
  /// is just [pipelineSettings].
  PipelineSettings globalPipelineAsPipeline() => pipelineSettings;

  Future<void> load() async {
    _book = await _ref.read(memoryBookOpsProvider).ensureForSession(_sessionId);
    _loading = false;
  }

  Future<void> save() async {
    if (_book == null) return;
    await _bookWrites.saveLatest();
  }

  MemoryBookSettings globalSettingsAsBookSettings() =>
      _settingsMapper.globalToBook(globalSettings);

  /// The active retrieval mode, as shown on the collapsed configuration row.
  String get modeLabel => switch (globalSettings.memoryMode) {
    'balanced' => 'memory_mode_balanced'.tr(),
    'deep' => 'memory_mode_deep'.tr(),
    'legacy' => 'memory_mode_legacy'.tr(),
    // `agentic` was removed in Phase 4 — migrate to `deep` for display.
    'agentic' => 'memory_mode_deep'.tr(),
    _ => 'memory_mode_fast'.tr(),
  };

  /// The configuration shown above the list, as label/value rows.
  ///
  /// Was a single `•`-joined string of 13 fields: it did not fit the 12 px
  /// subtitle it rendered into, and it glued translated fragments to English
  /// literals (`msgs`, `Batch`, `th=`, `entries`, `chunks`), which no locale
  /// could repair. Each row now carries its own key on both halves.
  List<MemoryConfigRow> get configRows {
    if (_book == null) return const [];
    final s = globalSettings;
    final pg = pipelineSettings;

    final packing = switch (s.memoryPackingMode) {
      'full' => 'memory_packing_full'.tr(),
      'chunk_first' => 'memory_packing_chunk_first'.tr(),
      _ => 'memory_packing_hybrid'.tr(),
    };
    final maxTokens = pg.memoryBookApi.generationMaxTokens;
    final budget = s.maxInjectedTokens == null
        ? 'memory_books_summary_auto_out'.tr()
        : 'memory_tokens_n'.plural(s.maxInjectedTokens!);

    return [
      MemoryConfigRow('memory_mode'.tr(), modeLabel),
      MemoryConfigRow(
        'memory_books_auto_create'.tr(),
        s.autoCreateEnabled
            ? 'memory_books_summary_auto_on'.tr()
            : 'memory_books_summary_auto_off'.tr(),
      ),
      MemoryConfigRow(
        'memory_books_auto_generate'.tr(),
        s.autoGenerateEnabled
            ? 'memory_books_summary_auto_text'.tr()
            : 'memory_books_summary_manual_text'.tr(),
      ),
      MemoryConfigRow(
        'memory_books_auto_create_interval'.tr(),
        'memory_messages_n'.plural(s.autoCreateInterval),
      ),
      MemoryConfigRow('memory_books_batch_size'.tr(), '${s.batchSize}'),
      MemoryConfigRow(
        'memory_books_delayed_automation'.tr(),
        s.useDelayedAutomation
            ? 'memory_books_summary_delayed'.tr()
            : 'memory_books_summary_immediate'.tr(),
      ),
      MemoryConfigRow(
        'label_embedding_target'.tr(),
        s.injectionTarget == 'macro'
            ? 'memory_injection_macro'.tr()
            : 'memory_injection_hard_block'.tr(),
      ),
      MemoryConfigRow('label_search_type'.tr(), searchTypeLabel),
      if (s.vectorSearchEnabled)
        MemoryConfigRow(
          'label_similarity_threshold'.tr(),
          s.vectorThreshold.toStringAsFixed(2),
        ),
      MemoryConfigRow(
        'memory_books_max_entries_prompt'.tr(),
        '${s.maxInjectedEntries}',
      ),
      MemoryConfigRow('memory_budget'.tr(), budget),
      MemoryConfigRow('memory_packing_mode'.tr(), packing),
      MemoryConfigRow(
        'memory_excerpt_chunks_per_entry'.tr(),
        'memory_chunks_shape'.tr(
          namedArgs: {
            'chunks': '${s.memoryExcerptChunksPerEntry}',
            'tokens': '${s.memoryExcerptTokensPerChunk}',
          },
        ),
      ),
      MemoryConfigRow('label_model'.tr(), searchModelLabel),
      MemoryConfigRow(
        'memory_books_generation_max_tokens'.tr(),
        maxTokens != null && maxTokens > 0
            ? 'memory_tokens_n'.plural(maxTokens)
            : 'memory_books_summary_auto_out'.tr(),
      ),
    ];
  }

  String get searchModelLabel {
    final pg = pipelineSettings;
    return pg.memoryBookApi.generationModel.isNotEmpty
        ? pg.memoryBookApi.generationModel
        : 'memory_books_current_llm_model'.tr();
  }

  /// Reads the global settings, which is what [cycleSearchType] writes — the
  /// per-book snapshot is a projection of them and would otherwise pin the
  /// label to whatever the book was last saved with.
  String get searchTypeLabel {
    final s = globalSettings;
    if (!s.vectorSearchEnabled) return 'memory_books_search_keys'.tr();
    if (s.keyMatchMode == 'both') return 'memory_books_vector_and_keys'.tr();
    return 'memory_books_search_vector'.tr();
  }

  /// Scans chat messages and creates draft segments for uncovered messages.
  /// Returns a result message to display to the user.
  Future<String?> scanChat() async {
    if (_book == null) return null;
    final chatState = _ref.read(chatProvider(_charId));
    final session = chatState.value?.session;
    if (session == null) return null;

    final plan = MemoryDraftPlanner.plan(
      book: _book!,
      messages: session.messages,
      interval: globalSettings.autoCreateInterval,
      lagMessages: globalSettings.autoCreateLagMessages,
      source: 'scan_chat',
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    if (plan.stableMessageCount == 0) {
      return 'memory_books_no_stable_messages'.tr();
    }
    if (plan.eligibleMessageCount == 0) {
      return 'memory_books_waiting_for_messages'.tr(
        args: ['${globalSettings.autoCreateLagMessages}'],
      );
    }
    if (plan.uncoveredMessageCount == 0) {
      return 'memory_books_all_covered'.tr();
    }
    if (plan.drafts.isEmpty) {
      return 'memory_books_need_more_uncovered'.tr();
    }

    _book = _book!.copyWith(
      pendingDrafts: [..._book!.pendingDrafts, ...plan.drafts],
    );
    await save();
    return 'memory_books_drafts_created'.tr(args: ['${plan.drafts.length}']);
  }

  void generateAllPending() => _draftGen.generateAllPending();

  /// Generates a draft. Callbacks are for UI updates.
  Future<void> generateDraft(
    String draftId, {
    required void Function() onStart,
    required void Function() onComplete,
    required void Function(String error) onError,
  }) => _draftGen.generateDraft(
    draftId,
    onStart: onStart,
    onComplete: onComplete,
    onError: onError,
  );

  void cancelDraftGeneration(String draftId) =>
      _draftGen.cancelDraftGeneration(draftId);

  Future<void> batchGenerate({
    required void Function() onStart,
    required void Function() onComplete,
    required void Function(String error) onError,
  }) => _draftGen.batchGenerate(
    onStart: onStart,
    onComplete: onComplete,
    onError: onError,
  );

  Future<void> approveDraft(String draftId) async {
    if (_book == null) return;
    // The card hides Approve while generating; keep the same invariant at the
    // controller boundary for stale callbacks or programmatic callers.
    if (_draftGen.isDraftGenerating(draftId)) return;
    final draftIndex = _book!.pendingDrafts.indexWhere((d) => d.id == draftId);
    if (draftIndex < 0) return;
    final draft = _book!.pendingDrafts[draftIndex];
    if (draft.content.isEmpty) return;

    final entry = MemoryEntry(
      id: draft.id.replaceAll('draft_', 'mem_'),
      title: draft.title,
      content: draft.content,
      keys: draft.keys,
      keyParagraphs: draft.keyParagraphs,
      ledgerRange: draft.ledgerRange,
      vectorSearch: draft.vectorSearch,
      messageIds: draft.messageIds,
      messageRange: draft.messageRange,
      status: 'active',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      // Preserve the draft's provenance marker for scan/manual entries.
      source: draft.source,
      kind: 'curated',
    );

    _book = _book!.copyWith(
      entries: [..._book!.entries, entry],
      pendingDrafts: _book!.pendingDrafts
          .where((d) => d.id != draftId)
          .toList(),
    );
    await save();
    await _autoIndexEntry(entry);
  }

  Future<void> deleteDraft(String draftId) async {
    if (_book == null) return;
    // Invalidate an in-flight request before removing the draft so a late
    // completion cannot publish it back into the book.
    _draftGen.cancelDraftGeneration(draftId);
    _book = _book!.copyWith(
      pendingDrafts: _book!.pendingDrafts
          .where((d) => d.id != draftId)
          .toList(),
    );
    await save();
  }

  Future<void> deleteAllDrafts() async {
    if (_book == null) return;
    for (final draft in _book!.pendingDrafts) {
      _draftGen.cancelDraftGeneration(draft.id);
    }
    _book = _book!.copyWith(pendingDrafts: []);
    await save();
  }

  Future<void> deleteEntry(String entryId) async {
    if (_book == null) return;
    _book = _book!.copyWith(
      entries: _book!.entries.where((e) => e.id != entryId).toList(),
    );
    await save();
    await _ref.read(memoryBookOpsProvider).deleteEmbeddingEntry(entryId);
  }

  Future<MemoryGlobalSettings?> updateSettings(
    MemoryBookSettings newSettings,
    double vectorThreshold,
  ) async {
    final currentGlobal = globalSettings;
    final newGlobal = _settingsMapper.bookToGlobal(
      newSettings,
      currentGlobal,
      vectorThreshold,
    );
    await _ref.read(memoryGlobalSettingsProvider.notifier).save(newGlobal);
    if (_book != null) {
      _book = _book!.copyWith(settings: newSettings);
      await _ref
          .read(memoryBookOpsProvider)
          .updateSettings(_sessionId, newSettings);
    }
    return newGlobal;
  }

  /// Reindexes all memory entries.
  ///
  /// Returns a typed outcome rather than a display string: the caller used to
  /// decide between an error dialog and a toast by matching the English
  /// prefixes of an already-translated message, so in any non-English locale
  /// both branches missed and a failure degraded to a toast.
  Future<ReindexOutcome> reindexAll() async {
    if (_book == null) return const ReindexNotReady();
    await _ref.read(apiListProvider.future);
    final config = _ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) return const ReindexNeedsEmbeddingApi();

    _isReindexing = true;
    try {
      final service = _ref.read(memoryEmbeddingServiceProvider);
      final result = await service.reindexAll(
        _book!,
        charId: _charId,
        sessionId: _sessionId,
        config: config,
        embeddingTarget: 'content',
      );
      return ReindexDone(
        indexed: result.indexed,
        skipped: result.skipped,
        failed: result.failed,
      );
    } catch (e) {
      return ReindexFailed(e);
    } finally {
      _isReindexing = false;
    }
  }

  Future<void> _autoIndexEntry(MemoryEntry entry) async {
    if (!globalSettings.vectorSearchEnabled) return;
    if (entry.content.trim().isEmpty) return;
    final config = _ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) return;
    try {
      await _ref
          .read(memoryEmbeddingServiceProvider)
          .indexMemoryEntry(
            entry,
            charId: _charId,
            sessionId: _sessionId,
            config: config,
          );
    } catch (_) {}
  }

  Future<void> deleteAllMemoryIndexes() async {
    await _ref.read(memoryEmbeddingServiceProvider).deleteAllMemoryIndexes();
  }

  Future<MemoryEntry?> editEntry(MemoryEntry entry, MemoryEntry result) async {
    if (_book == null) return null;
    final entries = [..._book!.entries];
    final idx = entries.indexWhere((e) => e.id == entry.id);
    if (idx >= 0) entries[idx] = result;
    _book = _book!.copyWith(entries: entries);
    await save();
    await _ref.read(memoryBookOpsProvider).deleteEmbeddingEntry(result.id);
    await _autoIndexEntry(result);
    return result;
  }

  Future<MemoryEntry?> addEntry(MemoryEntry result) async {
    if (_book == null) return null;
    _book = _book!.copyWith(entries: [..._book!.entries, result]);
    await save();
    await _autoIndexEntry(result);
    return result;
  }

  Future<void> editDraft(MemoryDraft draft, MemoryEntry result) async {
    if (_book == null) return;
    // Editing a draft that has an active generation would create ambiguous
    // last-writer-wins semantics. Delete remains intentionally allowed.
    if (_draftGen.isDraftGenerating(draft.id)) return;
    final drafts = [..._book!.pendingDrafts];
    final idx = drafts.indexWhere((d) => d.id == draft.id);
    if (idx >= 0) {
      drafts[idx] = drafts[idx].copyWith(
        title: result.title,
        content: result.content,
        keys: result.keys,
        keyParagraphs: result.keyParagraphs,
        ledgerRange: result.ledgerRange,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    _book = _book!.copyWith(pendingDrafts: drafts);
    await save();
  }

  Future<void> cycleSearchType() async {
    final s = globalSettings;
    String nextMode;
    bool nextVector;
    if (!s.vectorSearchEnabled) {
      nextVector = true;
      nextMode = 'glaze';
    } else if (s.keyMatchMode == 'glaze') {
      nextVector = true;
      nextMode = 'both';
    } else if (s.keyMatchMode == 'both') {
      nextVector = false;
      nextMode = 'plain';
    } else {
      nextVector = false;
      nextMode = 'plain';
    }
    await _ref
        .read(memoryGlobalSettingsProvider.notifier)
        .save(
          s.copyWith(vectorSearchEnabled: nextVector, keyMatchMode: nextMode),
        );
    // Retrieval reads the book's own snapshot (`book.settings.keyMatchMode`),
    // so mirror the two fields there as well — saving only the global settings
    // left the sheet showing a value the search never used.
    final book = _book;
    if (book == null) return;
    final bookSettings = book.settings.copyWith(
      vectorSearchEnabled: nextVector,
      keyMatchMode: nextMode,
    );
    _book = book.copyWith(settings: bookSettings);
    await _ref
        .read(memoryBookOpsProvider)
        .updateSettings(_sessionId, bookSettings);
  }

  void dispose() => _draftGen.dispose();

  /// Updates the book state (called from UI when state changes).
  void updateBook(MemoryBook newBook) {
    _book = newBook;
  }

  List<MemoryDraft> get draftsNeedingGeneration =>
      _draftGen.draftsNeedingGeneration;

  bool get isGenerating => _draftGen.isGenerating;

  int get activeEntryCount =>
      _book?.entries.where((e) => e.status == 'active').length ?? 0;
  int get needsRebuildCount =>
      _book?.entries.where((e) => e.status == 'needs_rebuild').length ?? 0;
}

/// One label/value line of [MemoryBookController.configRows].
class MemoryConfigRow {
  final String label;
  final String value;

  const MemoryConfigRow(this.label, this.value);
}

/// Result of [MemoryBookController.reindexAll].
///
/// The UI maps each case to its own copy and its own presentation — a dialog
/// for the two failures, a toast for the summary — instead of pattern-matching
/// a localized sentence.
sealed class ReindexOutcome {
  const ReindexOutcome();
}

/// No book loaded yet; nothing was attempted and nothing is reported.
class ReindexNotReady extends ReindexOutcome {
  const ReindexNotReady();
}

/// No embedding endpoint is configured, so there is nothing to index against.
class ReindexNeedsEmbeddingApi extends ReindexOutcome {
  const ReindexNeedsEmbeddingApi();
}

/// The run finished; the three counters are what the summary reports.
class ReindexDone extends ReindexOutcome {
  final int indexed;
  final int skipped;
  final int failed;

  const ReindexDone({
    required this.indexed,
    required this.skipped,
    required this.failed,
  });
}

/// The run threw. [error] is surfaced through `GlazeErrorDialog`, which
/// formats it, so it is kept as the original object.
class ReindexFailed extends ReindexOutcome {
  final Object error;

  const ReindexFailed(this.error);
}
