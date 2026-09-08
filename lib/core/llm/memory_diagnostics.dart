import '../models/agent_operation_record.dart';
import '../models/memory_book.dart';
import 'memory_budget.dart';
import 'memory_excerpt_selector.dart';
import 'memory_selector.dart';

class MemoryCandidateDiagnostics {
  final String entryId;
  final String title;
  final int tokenCost;
  final bool selected;
  final double score;
  final double keywordScore;
  final double vectorScore;
  final double catalogScore;
  final double recencyScore;
  final double importanceScore;
  final double diversityPenalty;
  final List<String> matchedKeys;
  final List<String> catalogMatchedTerms;
  final String reason;
  final List<String> messageIds;
  final String messageRange;
  final String arc;
  final String kind;
  final String injectionType;
  final int originalTokenCost;
  final List<int> excerptChunkIndexes;
  final List<String> excerptMatchedTerms;
  final int excerptChunksTotal;
  final int excerptChunksInjected;
  final double salienceScore;
  final double emotionalScore;
  final double entityScore;
  final bool isCore;
  final List<String> emotionalTags;
  final List<String> narrativeFlags;

  const MemoryCandidateDiagnostics({
    required this.entryId,
    required this.title,
    required this.tokenCost,
    required this.selected,
    required this.score,
    required this.keywordScore,
    required this.vectorScore,
    required this.catalogScore,
    required this.recencyScore,
    required this.importanceScore,
    required this.diversityPenalty,
    required this.matchedKeys,
    required this.catalogMatchedTerms,
    required this.reason,
    required this.messageIds,
    required this.messageRange,
    required this.arc,
    required this.kind,
    this.injectionType = 'none',
    this.originalTokenCost = 0,
    this.excerptChunkIndexes = const [],
    this.excerptMatchedTerms = const [],
    this.excerptChunksTotal = 0,
    this.excerptChunksInjected = 0,
    this.salienceScore = 0,
    this.emotionalScore = 0,
    this.entityScore = 0,
    this.isCore = false,
    this.emotionalTags = const [],
    this.narrativeFlags = const [],
  });

  Map<String, dynamic> toJson() => {
    'entryId': entryId,
    'title': title,
    'tokenCost': tokenCost,
    'selected': selected,
    'score': score,
    'keywordScore': keywordScore,
    'vectorScore': vectorScore,
    'catalogScore': catalogScore,
    'recencyScore': recencyScore,
    'importanceScore': importanceScore,
    'diversityPenalty': diversityPenalty,
    'matchedKeys': matchedKeys,
    'catalogMatchedTerms': catalogMatchedTerms,
    'reason': reason,
    'messageIds': messageIds,
    'messageRange': messageRange,
    'arc': arc,
    'kind': kind,
    'injectionType': injectionType,
    'originalTokenCost': originalTokenCost,
    'excerptChunkIndexes': excerptChunkIndexes,
    'excerptMatchedTerms': excerptMatchedTerms,
    'excerptChunksTotal': excerptChunksTotal,
    'excerptChunksInjected': excerptChunksInjected,
    'salienceScore': salienceScore,
    'emotionalScore': emotionalScore,
    'entityScore': entityScore,
    'isCore': isCore,
    'emotionalTags': emotionalTags,
    'narrativeFlags': narrativeFlags,
  };
}

class MemoryDiagnostics {
  final List<String> selectedEntryIds;
  final List<MemoryCandidateDiagnostics> candidates;
  final bool missingContextSuspected;
  final List<String> missingContextReasons;
  final bool reliableCandidateFound;
  final bool factualContinuityGuardEnabled;
  final bool factualContinuityGuardActive;
  final String memoryMode;
  final int selectedCount;
  final int skippedCount;
  final int totalCandidates;
  final int selectedTokens;
  final MemoryBudgetBreakdown budget;
  final bool budgetTrimmed;
  final int excludedBySourceWindow;
  final int latencyMs;
  final String? agenticStatus;
  final int? agenticLatencyMs;
  final List<AgentOperationAttempt> agenticAttempts;

  const MemoryDiagnostics({
    required this.selectedEntryIds,
    required this.candidates,
    required this.missingContextSuspected,
    required this.missingContextReasons,
    required this.reliableCandidateFound,
    this.factualContinuityGuardEnabled = false,
    this.factualContinuityGuardActive = false,
    this.memoryMode = 'fast',
    required this.selectedCount,
    required this.skippedCount,
    required this.totalCandidates,
    required this.selectedTokens,
    required this.budget,
    required this.budgetTrimmed,
    required this.excludedBySourceWindow,
    this.latencyMs = 0,
    this.agenticStatus,
    this.agenticLatencyMs,
    this.agenticAttempts = const [],
  });

  factory MemoryDiagnostics.fromSelection(
    MemorySelection selection, {
    required MemoryBudgetBreakdown budget,
    int Function(MemoryCandidateScore score)? tokenCounter,
    int latencyMs = 0,
    String currentText = '',
    String memoryMode = 'fast',
    bool factualContinuityGuardEnabled = false,
    MemoryExcerptSelection? excerptSelection,
    int excerptTokensPerChunk = defaultMemoryExcerptTokensPerEntry,
    int Function(String text)? chunkTokenCounter,
    String? agenticStatus,
    List<AgentOperationAttempt> agenticAttempts = const [],
    int? agenticLatencyMs,
  }) {
    final selectedIds = (excerptSelection?.entries ?? selection.entries)
        .map((e) => e.id)
        .toSet();
    final injectionItems = {
      for (final item
          in excerptSelection?.items ?? const <MemoryInjectionItem>[])
        item.entry.id: item,
    };
    final costs = <String, int>{};
    var selectedTokens = 0;

    int costOf(MemoryCandidateScore score) {
      return costs.putIfAbsent(
        score.entry.id,
        () =>
            tokenCounter?.call(score) ?? MemorySelector.tokenCost(score.entry),
      );
    }

    final candidates = selection.allScores
        .map((score) {
          final selected = selectedIds.contains(score.entry.id);
          final item = injectionItems[score.entry.id];
          final tokenCost = item?.tokenCost ?? costOf(score);
          if (selected) selectedTokens += tokenCost;
          return MemoryCandidateDiagnostics(
            entryId: score.entry.id,
            title: score.entry.title,
            tokenCost: tokenCost,
            selected: selected,
            score: score.score,
            keywordScore: score.keywordScore,
            vectorScore: score.vectorScore,
            catalogScore: score.catalogScore,
            recencyScore: score.recencyScore,
            importanceScore: score.importanceScore,
            diversityPenalty: score.diversityPenalty,
            matchedKeys: score.matchedKeys,
            catalogMatchedTerms: score.catalogMatchedTerms,
            reason: _reasonFor(
              score,
              selected,
              selection,
              excerptSelection: excerptSelection,
            ),
            messageIds: score.entry.messageIds,
            messageRange: _formatMessageRange(score.entry.messageRange),
            arc: score.entry.arc,
            kind: score.entry.kind,
            injectionType: item == null
                ? 'none'
                : item.excerpt
                ? 'excerpt'
                : 'full_entry',
            originalTokenCost: item?.originalTokenCost ?? costOf(score),
            excerptChunkIndexes: item?.chunkIndexes ?? const [],
            excerptMatchedTerms: item?.matchedTerms ?? const [],
            excerptChunksTotal: MemoryExcerptSelector.countChunks(
              score.entry.content,
              excerptTokensPerChunk,
              tokenCounter: chunkTokenCounter,
            ),
            excerptChunksInjected: item?.chunkIndexes.length ?? 0,
            salienceScore: score.salienceScore,
            emotionalScore: score.emotionalScore,
            entityScore: score.entityScore,
            isCore: score.isCore,
            emotionalTags: score.emotionalTags,
            narrativeFlags: score.narrativeFlags,
          );
        })
        .toList(growable: false);
    final missingContext = memoryMode == 'balanced'
        ? _missingContextSignals(selection, currentText)
        : const <String>[];

    return MemoryDiagnostics(
      selectedEntryIds: (excerptSelection?.entries ?? selection.entries)
          .map((e) => e.id)
          .toList(growable: false),
      candidates: candidates,
      missingContextSuspected: missingContext.isNotEmpty,
      missingContextReasons: missingContext,
      reliableCandidateFound: _reliableCandidateFound(selection),
      factualContinuityGuardEnabled: factualContinuityGuardEnabled,
      factualContinuityGuardActive:
          factualContinuityGuardEnabled && missingContext.isNotEmpty,
      memoryMode: memoryMode,
      selectedCount: selectedIds.length,
      skippedCount: candidates.length - selectedIds.length,
      totalCandidates: candidates.length,
      selectedTokens:
          excerptSelection?.totalTokens ??
          (tokenCounter == null && selection.totalTokens > 0
              ? selection.totalTokens
              : selectedTokens),
      budget: budget,
      budgetTrimmed: excerptSelection?.budgetTrimmed ?? selection.budgetTrimmed,
      excludedBySourceWindow: selection.excludedBySourceWindow,
      latencyMs: latencyMs,
      agenticStatus: agenticStatus,
      agenticLatencyMs: agenticLatencyMs,
      agenticAttempts: agenticAttempts,
    );
  }

  Map<String, dynamic> toJson() {
    final eligibleCandidateCount = candidates
        .where((c) => c.reason != 'source_visible_in_prompt')
        .length;
    return {
      'selectedEntryIds': selectedEntryIds,
      'memoryMode': memoryMode,
      'missingContextSuspected': missingContextSuspected,
      'missingContextReasons': missingContextReasons,
      'reliableCandidateFound': reliableCandidateFound,
      'factualContinuityGuardEnabled': factualContinuityGuardEnabled,
      'factualContinuityGuardActive': factualContinuityGuardActive,
      'selectedCount': selectedCount,
      'skippedCount': skippedCount,
      'totalCandidates': totalCandidates,
      'eligibleCandidates': eligibleCandidateCount,
      'eligibleSkippedCount': (eligibleCandidateCount - selectedCount).clamp(
        0,
        eligibleCandidateCount,
      ),
      'selectedTokens': selectedTokens,
      'budget': budget.toJson(),
      'budgetTrimmed': budgetTrimmed,
      'excludedBySourceWindow': excludedBySourceWindow,
      'latencyMs': latencyMs,
      if (agenticStatus != null) 'agenticStatus': agenticStatus,
      if (agenticLatencyMs != null) 'agenticLatencyMs': agenticLatencyMs,
      if (agenticAttempts.isNotEmpty)
        'agenticAttempts': agenticAttempts.map((a) => a.toJson()).toList(),
      'candidates': candidates.map((c) => c.toJson()).toList(),
    };
  }

  String get summary => selectedCount == 0
      ? 'Memory: no entries selected'
      : 'Memory: $selectedCount entries, $selectedTokens tokens';

  static String _reasonFor(
    MemoryCandidateScore score,
    bool selected,
    MemorySelection selection, {
    MemoryExcerptSelection? excerptSelection,
  }) {
    if (selected) return 'selected';
    if (score.excludedBySourceWindow) {
      return score.exclusionReason ?? 'source_visible_in_prompt';
    }
    if (selection.budgetTrimmed && selection.budgetTokens != null) {
      return 'budget_trimmed';
    }
    if (selection.entryCap > 0 &&
        selection.entries.length >= selection.entryCap) {
      return 'entry_cap';
    }
    if (excerptSelection?.budgetTrimmed == true) {
      return 'chunk_budget_trimmed';
    }
    return 'chunk_rank_trimmed';
  }

  static List<String> _missingContextSignals(
    MemorySelection selection,
    String currentText,
  ) {
    final reasons = <String>[];
    final text = currentText.toLowerCase();
    final referencesOldContext = RegExp(
      r'\b(remember|earlier|before|last time|again|that time|promise|promised|where were we|what happened)\b',
    ).hasMatch(text);
    final reliable = _reliableCandidateFound(selection);

    if (referencesOldContext && !reliable) {
      reasons.add('old_context_reference_without_reliable_candidate');
    }
    if (selection.entries.isEmpty && selection.allScores.isEmpty) {
      reasons.add('empty_retrieval');
    }
    if (referencesOldContext && selection.allScores.isNotEmpty && !reliable) {
      reasons.add('weak_retrieval');
    }
    if (_hasConflictingTopCandidates(selection)) {
      reasons.add('conflicting_top_candidates');
    }
    return reasons;
  }

  static bool _reliableCandidateFound(MemorySelection selection) {
    if (selection.entries.isEmpty) return false;
    final selectedIds = selection.entries.map((entry) => entry.id).toSet();
    return selection.allScores.any(
      (score) => selectedIds.contains(score.entry.id) && score.score >= 1.25,
    );
  }

  static bool _hasConflictingTopCandidates(MemorySelection selection) {
    final scored = selection.allScores
        .where((score) => !score.excludedBySourceWindow && score.score >= 1.0)
        .toList(growable: false);
    if (scored.length < 2) return false;
    scored.sort((a, b) => b.score.compareTo(a.score));
    final first = scored[0];
    final second = scored[1];
    if ((first.score - second.score).abs() > 0.2) return false;
    final firstTokens = _identityTokens(first.entry);
    final secondTokens = _identityTokens(second.entry);
    if (firstTokens.isEmpty || secondTokens.isEmpty) return false;
    return firstTokens.intersection(secondTokens).isEmpty;
  }

  static Set<String> _identityTokens(MemoryEntry entry) {
    final words = [
      entry.title,
      ...entry.keys,
      entry.arc,
    ].expand((raw) => raw.toLowerCase().split(RegExp(r'[\s,.;:()]+')));
    return words.where((word) => word.length >= 3).toSet();
  }

  static String _formatMessageRange(MessageRange? range) {
    if (range == null) return '';
    return '${range.start}-${range.end}';
  }
}
