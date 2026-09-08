import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/memory_injection_service.dart';
import '../../../core/llm/memory_draft_planner.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../../core/state/memory_book_ops_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/state/pipeline_settings_provider.dart';
import '../../chat/chat_provider.dart';
import '../../settings/api_list_provider.dart';
import 'memory_draft_generation_controller.dart';
import 'memory_settings_mapper.dart';

/// Controller for memory book operations, separating business logic from UI.
///
/// Thin orchestrator: owns the [MemoryBook] + entry/index CRUD + settings
/// mapping + reindex, and delegates the draft-generation lifecycle (active
/// set, cancel tokens, elapsed timer, INV-M3 mutex) to
/// [MemoryDraftGenerationController].
class MemoryBookController {
  final WidgetRef _ref;
  final String _sessionId;
  final String _charId;

  MemoryBook? _book;
  bool _loading = true;
  bool _isReindexing = false;
  final MemorySettingsMapper _settingsMapper = const MemorySettingsMapper();
  late final MemoryDraftGenerationController _draftGen =
      MemoryDraftGenerationController(
        ref: _ref,
        charId: _charId,
        sessionId: _sessionId,
        settingsMapper: _settingsMapper,
        bookGetter: () => _book,
        persistAndSet: (book) async {
          _book = book;
          await save();
        },
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
    await _ref.read(memoryBookOpsProvider).saveMemoryBook(_book!);
  }

  MemoryBookSettings globalSettingsAsBookSettings() =>
      _settingsMapper.globalToBook(globalSettings);

  String get settingsSummary {
    if (_book == null) return '';
    final s = globalSettings;
    final mode = switch (s.memoryMode) {
      'balanced' => 'memory_mode_balanced'.tr(),
      'deep' => 'memory_mode_deep'.tr(),
      'legacy' => 'memory_mode_legacy'.tr(),
      // `agentic` was removed in Phase 4 — migrate to `deep` for display.
      'agentic' => 'memory_mode_deep'.tr(),
      _ => 'memory_mode_fast'.tr(),
    };
    final interval = s.autoCreateInterval;
    final autoCreate = s.autoCreateEnabled
        ? 'memory_books_summary_auto_on'.tr()
        : 'memory_books_summary_auto_off'.tr();
    final autoGen = s.autoGenerateEnabled
        ? 'memory_books_summary_auto_text'.tr()
        : 'memory_books_summary_manual_text'.tr();
    final delayed = s.useDelayedAutomation
        ? 'memory_books_summary_delayed'.tr()
        : 'memory_books_summary_immediate'.tr();
    final target = s.injectionTarget == 'macro'
        ? 'memory_injection_macro'.tr()
        : 'memory_injection_hard_block'.tr();
    final vectorThreshold = s.vectorThreshold.toStringAsFixed(2);
    final maxEntries = s.maxInjectedEntries;
    final packing = switch (s.memoryPackingMode) {
      'full' => 'memory_packing_full'.tr(),
      'chunk_first' => 'memory_packing_chunk_first'.tr(),
      _ => 'memory_packing_hybrid'.tr(),
    };
    final memoryBudget = s.maxInjectedTokens == null
        ? 'memory_books_summary_auto_out'.tr()
        : '${s.maxInjectedTokens} memory tokens';
    final batchSize = s.batchSize;
    final pg = pipelineSettings;
    final outTokens =
        (pg.memoryBookApi.generationMaxTokens != null &&
            pg.memoryBookApi.generationMaxTokens! > 0)
        ? '${pg.memoryBookApi.generationMaxTokens} out'
        : 'memory_books_summary_auto_out'.tr();
    return '$mode • $interval msgs • Batch $batchSize • $outTokens • $autoCreate • $autoGen • $delayed • $target • th=$vectorThreshold • $maxEntries entries • $memoryBudget • $packing • ${s.memoryExcerptChunksPerEntry}x${s.memoryExcerptTokensPerChunk} chunks';
  }

  String get searchModelLabel {
    final pg = pipelineSettings;
    return pg.memoryBookApi.generationModel.isNotEmpty
        ? pg.memoryBookApi.generationModel
        : 'memory_books_current_llm_model'.tr();
  }

  String get searchTypeLabel {
    final s = _book?.settings;
    if (s == null) return 'memory_books_search_vector'.tr();
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
    final draftIndex = _book!.pendingDrafts.indexWhere((d) => d.id == draftId);
    if (draftIndex < 0) return;
    final draft = _book!.pendingDrafts[draftIndex];
    if (draft.content.isEmpty) return;

    final entry = MemoryEntry(
      id: draft.id.replaceAll('draft_', 'mem_'),
      title: draft.title,
      content: draft.content,
      keys: draft.keys,
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
    _book = _book!.copyWith(
      pendingDrafts: _book!.pendingDrafts
          .where((d) => d.id != draftId)
          .toList(),
    );
    await save();
  }

  Future<void> deleteAllDrafts() async {
    if (_book == null) return;
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

  /// Reindexes all memory entries. Returns a result message.
  Future<String?> reindexAll() async {
    if (_book == null) return null;
    await _ref.read(apiListProvider.future);
    final config = _ref.read(embeddingConfigProvider);
    if (config.endpoint.isEmpty) {
      return 'memory_books_setup_embedding_first'.tr();
    }

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
      return 'memory_books_reindex_result'.tr(
        namedArgs: {
          'indexed': '${result.indexed}',
          'skipped': '${result.skipped}',
          'failed': '${result.failed}',
        },
      );
    } catch (e) {
      return 'memory_books_reindex_failed'.tr(args: ['$e']);
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
    final drafts = [..._book!.pendingDrafts];
    final idx = drafts.indexWhere((d) => d.id == draft.id);
    if (idx >= 0) {
      drafts[idx] = drafts[idx].copyWith(
        title: result.title,
        content: result.content,
        keys: result.keys,
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
  }

  /// Runs memory deduplication. When [entryIds] is provided, dedup is
  /// scoped to those entries only (used by the "only selected swipes"
  /// filter). Returns a human-readable result string for toast display.
  Future<String> runDedup({Set<String>? entryIds}) async {
    final pipeline = _ref.read(pipelineSettingsProvider);
    final dedupService = _ref.read(memoryDedupServiceProvider);

    final result = await dedupService.runDedup(
      sessionId: _sessionId,
      settings: pipeline,
      entryIds: entryIds,
      threshold: pipeline.memoryPipeline.memoryDedupThreshold,
    );

    if (result.status == 'ok') {
      await load();
    }

    return switch (result.status) {
      'ok' =>
        'Dedup: ${result.merged} merged, ${result.dropped} dropped, '
            '${result.kept} kept (${result.pairsSentToLlm} pairs from '
            '${result.candidatesChecked} entries)',
      'no_book' => 'No memory book found.',
      'aborted' => 'Dedup aborted.',
      'timeout' => 'Dedup timed out.',
      'llm_error' => 'Dedup: LLM error (${result.pairsSentToLlm} pairs found).',
      'error' => 'Dedup failed.',
      _ => 'Dedup: ${result.status}',
    };
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
