import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/repositories/embedding_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../db/repositories/memory_catalog_repo.dart';
import '../db/repositories/memory_salience_repo.dart';
import '../db/repositories/memory_entity_repo.dart';
import '../models/chat_message.dart';
import '../models/memory_book.dart';
import '../models/memory_graph.dart';
import '../state/db_provider.dart';
import '../state/memory_settings_provider.dart';
import 'embedding_service.dart';
import 'embedding_types.dart';
import 'chat_message_embedding_service.dart';
import 'memory_budget.dart';
import 'memory_diagnostics.dart';
import 'memory_embedding_service.dart';
import 'memory_excerpt_selector.dart';
import 'memory_formatting.dart';
import 'message_recall_service.dart';
import 'memory_selector.dart';
import 'retrieval_query_builder.dart';
import 'memory/memory_catalog_matcher.dart';
import 'memory/memory_vector_searcher.dart';

export 'memory/memory_catalog_matcher.dart'
    show CatalogMatchResult, MemoryCatalogMatcher;
export 'memory/memory_vector_searcher.dart'
    show MemoryVectorMatchResult, MemoryVectorSearcher;

class MemoryInjectionResult {
  final List<MemoryEntry> entries;
  final String content;
  final String injectionTarget;
  final String macroContent;
  final int totalTokens;
  final int? maxInjectionTokens;
  final bool budgetTrimmed;
  final List<MemoryCandidateScore> diagnostics;
  final MemoryDiagnostics? memoryDiagnostics;
  final int excludedBySourceWindow;
  final int candidatesTotal;

  const MemoryInjectionResult({
    this.entries = const [],
    this.content = '',
    this.injectionTarget = 'hard_block',
    this.macroContent = '',
    this.totalTokens = 0,
    this.maxInjectionTokens,
    this.budgetTrimmed = false,
    this.diagnostics = const [],
    this.memoryDiagnostics,
    this.excludedBySourceWindow = 0,
    this.candidatesTotal = 0,
  });
}

class MemoryCandidateBuildResult {
  final MemorySelection selection;
  final MemoryDiagnostics? diagnostics;
  final MemoryBookSettings? settings;

  const MemoryCandidateBuildResult({
    required this.selection,
    required this.diagnostics,
    this.settings,
  });
}

class MemoryInjectionService {
  final MemoryBookRepo _repo;
  final EmbeddingRepo _embeddingRepo;
  final MemoryCatalogRepo _catalogRepo;
  final MemorySalienceRepo? _salienceRepo;
  final MemoryEntityRepo? _entityRepo;
  final EmbeddingService _embeddingService;
  final MemoryGlobalSettings Function() _readGlobalSettings;
  late final MemoryVectorSearcher _vectorSearcher;
  late final MemoryCatalogMatcher _catalogMatcher;

  MemoryInjectionService(
    this._repo,
    this._embeddingRepo,
    this._catalogRepo,
    this._embeddingService,
    this._readGlobalSettings, {
    this._salienceRepo,
    this._entityRepo,
  }) {
    _vectorSearcher = MemoryVectorSearcher(_embeddingRepo, _embeddingService);
    _catalogMatcher = MemoryCatalogMatcher(_catalogRepo);
  }

  /// Build injection candidates + diagnostics. Returns the raw selection
  /// (with source-window exclusion applied) plus all scored candidates
  /// for visibility. The caller is responsible for token-budget
  /// re-finalization if the prompt-window cutoff is known after this
  /// call (see [finalizeWithVisibleWindow]).
  Future<MemorySelection> buildCandidates({
    required String sessionId,
    required List<ChatMessage> history,
    required String currentText,
    EmbeddingConfig? embeddingConfig,
    bool Function()? shouldAbort,
    CancelToken? cancelToken,
    int? contextBudgetTokens,
    Set<String> visibleMessageIds = const {},
  }) async {
    final result = await buildCandidatesWithDiagnostics(
      sessionId: sessionId,
      history: history,
      currentText: currentText,
      embeddingConfig: embeddingConfig,
      shouldAbort: shouldAbort,
      cancelToken: cancelToken,
      contextBudgetTokens: contextBudgetTokens,
      visibleMessageIds: visibleMessageIds,
    );
    return result.selection;
  }

  Future<MemoryCandidateBuildResult> buildCandidatesWithDiagnostics({
    required String sessionId,
    required List<ChatMessage> history,
    required String currentText,
    EmbeddingConfig? embeddingConfig,
    bool Function()? shouldAbort,
    CancelToken? cancelToken,
    int? contextBudgetTokens,
    Set<String> visibleMessageIds = const {},
  }) async {
    final sw = Stopwatch()..start();
    MemoryCandidateBuildResult finish(
      MemorySelection selection, {
      MemoryBudgetBreakdown budget = const MemoryBudgetBreakdown(
        source: 'none',
      ),
      MemoryBookSettings? settings,
      String? agenticStatus,
      int? agenticLatencyMs,
    }) {
      sw.stop();
      final resolvedSettings = settings ?? const MemoryBookSettings();
      return MemoryCandidateBuildResult(
        selection: selection,
        settings: settings,
        diagnostics: settings == null
            ? null
            : MemoryDiagnostics.fromSelection(
                selection,
                budget: budget,
                latencyMs: sw.elapsedMilliseconds,
                currentText: currentText,
                memoryMode: resolvedSettings.memoryMode,
                factualContinuityGuardEnabled:
                    resolvedSettings.factualContinuityGuardEnabled,
                agenticStatus: agenticStatus,
                agenticAttempts: const [],
                agenticLatencyMs: agenticLatencyMs,
              ),
      );
    }

    if (shouldAbort?.call() == true) {
      return finish(const MemorySelection());
    }
    final book = await _repo.getBySessionId(sessionId);
    if (shouldAbort?.call() == true) {
      return finish(const MemorySelection());
    }
    if (book == null) {
      return finish(const MemorySelection());
    }

    final gs = _readGlobalSettings();
    if (!gs.enabled || !book.settings.enabled) {
      return finish(const MemorySelection());
    }

    final activeEntries = book.entries
        .where(
          (e) =>
              e.status == 'active' &&
              e.content.trim().isNotEmpty &&
              e.source != 'studio_ledger',
        )
        .toList();
    if (activeEntries.isEmpty) return finish(const MemorySelection());

    final salienceByEntryId = <String, MemorySalience>{};
    if (_salienceRepo != null && book.settings.memoryMode != 'fast') {
      final salienceRows = await _salienceRepo.getBySessionId(sessionId);
      for (final s in salienceRows) {
        salienceByEntryId[s.memoryEntryId] = s;
      }
    }

    // Entity fusion (Phase G3): match entity names/aliases in query text
    var entityOverlapByEntryId = const <String, int>{};
    if (_entityRepo != null && book.settings.memoryMode != 'fast') {
      final scanText = MemoryCatalogMatcher.selectorScanText(
        book.settings,
        history,
        currentText,
      );
      final entities = await _entityRepo.getBySessionId(sessionId);
      if (entities.isNotEmpty) {
        final lowerQuery = scanText.toLowerCase();
        for (final entity in entities) {
          final names = [entity.name, ...entity.aliases];
          if (names.any(
            (n) => n.isNotEmpty && lowerQuery.contains(n.toLowerCase()),
          )) {
            entityOverlapByEntryId = Map.fromEntries([
              ...entityOverlapByEntryId.entries,
            ]);
            entityOverlapByEntryId[entity.memoryEntryId] =
                (entityOverlapByEntryId[entity.memoryEntryId] ?? 0) + 1;
          }
        }
      }
    }

    // Emotional recall (Phase G2): extract emotional context from query
    var queryEmotions = const <String>[];
    if (book.settings.memoryMode != 'fast') {
      queryEmotions = RetrievalQueryBuilder.extractEmotionalContext(
        MemoryCatalogMatcher.selectorScanText(
          book.settings,
          history,
          currentText,
        ),
      );
    }

    var vectorMatches = const MemoryVectorMatchResult();
    final keywordMatchedTerms = MemoryCatalogMatcher.keywordMatches(
      activeEntries,
      MemoryCatalogMatcher.selectorScanText(
        book.settings,
        history,
        currentText,
      ),
      book.settings.keyMatchMode,
    );
    final catalogMatches = book.settings.memoryMode == 'balanced'
        ? await _catalogMatcher.match(
            book: book,
            activeEntries: activeEntries,
            history: history,
            currentText: currentText,
          )
        : const CatalogMatchResult();
    if (shouldAbort?.call() == true) {
      return finish(const MemorySelection(), settings: book.settings);
    }
    if (gs.vectorSearchEnabled &&
        embeddingConfig != null &&
        embeddingConfig.endpoint.isNotEmpty &&
        history.isNotEmpty) {
      vectorMatches = await _vectorSearcher.search(
        activeEntries,
        history,
        currentText,
        embeddingConfig,
        gs,
        shouldAbort: shouldAbort,
        cancelToken: cancelToken,
      );
    }

    final budget = MemoryInjectionBudget.describeBudget(
      contextBudgetTokens: contextBudgetTokens,
      percent: book.settings.maxInjectionBudgetPercent,
      absoluteCap: book.settings.memoryMode == 'legacy'
          ? null
          : book.settings.maxInjectedTokens,
    );

    final selection = MemorySelector.select(
      MemorySelectionInput(
        selectionMode: book.settings.memoryMode == 'legacy' ? 'legacy' : 'v2',
        entries: activeEntries,
        vectorScores: vectorMatches.scores,
        vectorMatchedChunks: vectorMatches.chunksByEntryId,
        keywordMatchedTerms: keywordMatchedTerms,
        catalogScores: catalogMatches.scores,
        catalogMatchedTerms: catalogMatches.termsByEntryId,
        visibleMessageIds: visibleMessageIds,
        maxInjectionTokens: budget.effectiveTokens,
        maxInjectedEntries: book.settings.maxInjectedEntries,
        diversityAware: book.settings.diversityAware,
        diversityPenalty: book.settings.diversityPenalty,
        recencyBoost: book.settings.recencyBoost,
        recencyHalfLifeDays: book.settings.recencyHalfLifeDays,
        importanceBoost: book.settings.importanceBoost,
        importanceWeight: book.settings.importanceWeight,
        sourceWindowExclusion: book.settings.sourceWindowExclusion,
        currentMessageIndex: history.length,
        chunkBudgeting: book.settings.memoryPackingMode == 'chunk_first',
        salienceByEntryId: salienceByEntryId,
        queryEmotions: queryEmotions,
        entityOverlapByEntryId: entityOverlapByEntryId,
      ),
    );

    // Agentic read (searchMemory tool) was previously gated by
    // `memoryMode == 'agentic'`, but that mode was removed in Phase 4 of
    // docs/PLAN_AGENTIC_STUDIO.md. Agentic read will be wired as a
    // pre-generation memory tracker in a later phase; until then it is
    // disabled.

    return finish(selection, budget: budget, settings: book.settings);
  }

  /// Backwards-compatible facade for callers that still expect an
  /// assembled injection payload in one shot (tokenizer sheet, etc.).
  Future<MemoryInjectionResult> buildInjection({
    required String sessionId,
    required String historyText,
    required int messageCount,
    String? summaryExcerpt,
    List<ChatMessageForSearch>? history,
    String? currentText,
    EmbeddingConfig? embeddingConfig,
    bool Function()? shouldAbort,
    CancelToken? cancelToken,
    int? contextBudgetTokens,
    Set<String> visibleMessageIds = const {},
  }) async {
    final chatHistory = (history ?? const [])
        .map((m) => ChatMessage(id: '', role: m.role, content: m.content))
        .toList();
    final candidateResult = await buildCandidatesWithDiagnostics(
      sessionId: sessionId,
      history: chatHistory,
      currentText: currentText ?? '',
      embeddingConfig: embeddingConfig,
      shouldAbort: shouldAbort,
      cancelToken: cancelToken,
      contextBudgetTokens: contextBudgetTokens,
      visibleMessageIds: visibleMessageIds,
    );
    final selection = candidateResult.selection;
    final settings = candidateResult.settings ?? const MemoryBookSettings();

    if (selection.entries.isEmpty) {
      return MemoryInjectionResult(
        diagnostics: selection.allScores,
        memoryDiagnostics: candidateResult.diagnostics,
        excludedBySourceWindow: selection.excludedBySourceWindow,
        candidatesTotal: selection.allScores.length,
        maxInjectionTokens: selection.budgetTokens,
      );
    }

    final useExcerptPacking =
        settings.memoryExcerptingEnabled ||
        settings.memoryPackingMode == 'chunk_first';
    final excerptSelection = useExcerptPacking
        ? MemoryExcerptSelector.select(
            selection,
            packingMode: settings.memoryPackingMode,
            maxExcerptTokensPerEntry: settings.memoryExcerptTokensPerChunk,
            maxExcerptChunksPerEntry: settings.memoryExcerptChunksPerEntry,
            chunkFirstTopEntries: settings.chunkFirstTopEntries,
            chunkFirstTopChunks: settings.chunkFirstTopChunks,
          )
        : MemoryExcerptSelector.fullEntries(selection);
    final maxInjectionTokens = selection.budgetTokens;
    final totalTokens = excerptSelection.totalTokens;
    final macroContent = formatMemoryItems(
      excerptSelection.items,
      includeContextHeader: false,
    );

    final contentParts = <String>[];
    if (summaryExcerpt != null && summaryExcerpt.isNotEmpty) {
      contentParts.add('Summary excerpt:\n$summaryExcerpt');
    }
    contentParts.add(
      formatMemoryItems(excerptSelection.items, includeContextHeader: true),
    );

    final injectionTarget = settings.injectionTarget == 'macro'
        ? 'macro'
        : 'hard_block';

    return MemoryInjectionResult(
      entries: excerptSelection.entries,
      content: contentParts.join('\n\n'),
      injectionTarget: injectionTarget,
      macroContent: macroContent,
      totalTokens: totalTokens,
      maxInjectionTokens: maxInjectionTokens,
      budgetTrimmed: excerptSelection.budgetTrimmed,
      diagnostics: selection.allScores,
      memoryDiagnostics: candidateResult.diagnostics,
      excludedBySourceWindow: selection.excludedBySourceWindow,
      candidatesTotal: selection.allScores.length,
    );
  }
}

final memoryInjectionServiceProvider = Provider<MemoryInjectionService>((ref) {
  return MemoryInjectionService(
    ref.watch(memoryBookRepoProvider),
    ref.watch(embeddingRepoProvider),
    ref.watch(memoryCatalogRepoProvider),
    EmbeddingService(),
    () => ref.read(memoryGlobalSettingsProvider),
    salienceRepo: ref.watch(memorySalienceRepoProvider),
    entityRepo: ref.watch(memoryEntityRepoProvider),
  );
});

final memoryEmbeddingServiceProvider = Provider<MemoryEmbeddingService>((ref) {
  return MemoryEmbeddingService(
    ref.watch(embeddingRepoProvider),
    EmbeddingService(),
  );
});

// NEW (patch #3 — memory continuity): chat-message embedding + recall.
// Rationale: raw-message recall is a lossless backstop for the lossy MemoryBook
// compression — chunk=5 messages → embeddings → cosine search →
// `<recalled_messages>` injection (Marinara memory-recall.ts analog).
final chatMessageEmbeddingServiceProvider =
    Provider<ChatMessageEmbeddingService>((ref) {
      return ChatMessageEmbeddingService(
        ref.watch(embeddingRepoProvider),
        EmbeddingService(),
      );
    });

final messageRecallServiceProvider = Provider<MessageRecallService>((ref) {
  return MessageRecallService(
    ref.watch(embeddingRepoProvider),
    EmbeddingService(),
  );
});
