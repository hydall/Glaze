import '../../models/chat_message.dart';
import '../context_calculator.dart';
import '../history_assembler.dart';
import '../memory_budget.dart';
import '../memory_diagnostics.dart';
import '../memory_excerpt_selector.dart';
import '../memory_formatting.dart';
import '../memory_selector.dart';
import '../tokenizer.dart';
import 'prompt_payload.dart';
import 'resolved_block.dart';

const deferredMemoryPlaceholder = '[[GLAZE_DEFERRED_MEMORY_CONTEXT]]';

class DeferredMemoryResult {
  final TokenBreakdown breakdown;
  final MemorySelection? finalMemorySelection;
  final MemoryExcerptSelection? finalExcerptSelection;
  final bool memoryMacroMissing;

  const DeferredMemoryResult({
    required this.breakdown,
    required this.finalMemorySelection,
    required this.finalExcerptSelection,
    required this.memoryMacroMissing,
  });
}

class RebuiltMemoryContent {
  final String content;
  final String macroContent;
  const RebuiltMemoryContent(this.content, this.macroContent);
}

bool shouldInjectFactualContinuityGuard(PromptPayload payload) {
  final diagnostics = payload.memoryCoverage['diagnostics'];
  if (diagnostics is! Map) return false;
  final active = diagnostics['factualContinuityGuardActive'] == true;
  final reliable = diagnostics['reliableCandidateFound'] == true;
  return active && !reliable;
}

void injectMemoryBlock(
  List<PromptMessage> messages,
  List<StaticBlock> attributionBlocks,
  String content,
) {
  attributionBlocks.add(StaticBlock(id: 'memory', content: content));
  final memMsg = PromptMessage(
    role: 'system',
    content: content,
    blockId: 'memory',
    blockName: 'Memory Book',
  );
  final historyIdx = messages.indexWhere((m) => m.isHistory);
  if (historyIdx >= 0) {
    messages.insert(historyIdx, memMsg);
  } else {
    messages.add(memMsg);
  }
}

/// Injects the `<recalled_messages>` system block before the first history
/// message (and before the memory block, since this is called first). The
/// raw chunks are the lossless backstop for the lossy MemoryBook compression.
/// Rationale (patch #3): top-K semantically closest message chunks injected
/// before the first history message (Marinara memory-recall analog).
void injectRecalledMessagesBlock(
  List<PromptMessage> messages,
  List<StaticBlock> attributionBlocks,
  String content,
) {
  attributionBlocks.add(StaticBlock(id: 'recalled_messages', content: content));
  final recallMsg = PromptMessage(
    role: 'system',
    content: content,
    blockId: 'recalled_messages',
    blockName: 'Recalled Messages',
  );
  final historyIdx = messages.indexWhere((m) => m.isHistory);
  if (historyIdx >= 0) {
    messages.insert(historyIdx, recallMsg);
  } else {
    messages.add(recallMsg);
  }
}

void injectCharacterKnowledgeBlock(
  List<PromptMessage> messages,
  List<StaticBlock> attributionBlocks,
  String content,
) {
  attributionBlocks.add(
    StaticBlock(id: 'current_character_state', content: content),
  );
  final stateMsg = PromptMessage(
    role: 'system',
    content: content,
    blockId: 'current_character_state',
    blockName: 'Current Character State',
  );
  final historyIdx = messages.indexWhere((m) => m.isHistory);
  if (historyIdx >= 0) {
    messages.insert(historyIdx, stateMsg);
  } else {
    messages.add(stateMsg);
  }
}

/// Injects the `<studio_session_state>` system block before the first history
/// message so the LLM sees committed entity/relationship/arc/world canon state
/// overriding character-card baseline. Placed before recalled_messages to give
/// it higher context-window authority.
/// Rationale: Studio prompt assembly injects committed canon state as
/// hidden/system prompt context only — never as a chat message. Priority:
/// latest ledger > entity state > relationship state > arc state (for card
/// hooks it overrides) > world/scene state > MemoryBook chunks > raw recalled
/// messages. Manual overrides/locks are never trimmed before raw recall.
void injectStudioSessionStateBlock(
  List<PromptMessage> messages,
  List<StaticBlock> attributionBlocks,
  String content,
) {
  attributionBlocks.add(
    StaticBlock(id: 'studio_session_state', content: content),
  );
  final stateMsg = PromptMessage(
    role: 'system',
    content: content,
    blockId: 'studio_session_state',
    blockName: 'Studio Session State',
  );
  final historyIdx = messages.indexWhere((m) => m.isHistory);
  if (historyIdx >= 0) {
    messages.insert(historyIdx, stateMsg);
  } else {
    messages.add(stateMsg);
  }
}

/// Places continuity layers directly before history in ascending authority.
/// Later system messages have greater practical recency, so Ledger canon is
/// deliberately last: card/lore → episodic MemoryBook/raw recall → durable
/// character state → current Ledger state.
void orderContinuityContextBlocks(List<PromptMessage> messages) {
  const orderedIds = <String>[
    'memory',
    'recalled_messages',
    'current_character_state',
    'studio_session_state',
  ];
  final blocks = <String, PromptMessage>{};
  messages.removeWhere((message) {
    if (!orderedIds.contains(message.blockId)) return false;
    blocks[message.blockId!] = message;
    return true;
  });
  if (blocks.isEmpty) return;
  final historyIdx = messages.indexWhere((message) => message.isHistory);
  final insertAt = historyIdx < 0 ? messages.length : historyIdx;
  messages.insertAll(
    insertAt,
    orderedIds
        .map((id) => blocks[id])
        .whereType<PromptMessage>()
        .toList(growable: false),
  );
}

/// Refilter a [MemorySelection] against the visible-window message ids
/// returned by [TokenBreakdown]. Re-runs the selector with the new
/// exclusion set so anything whose `messageIds` overlaps the visible
/// history is dropped. Preserves the existing budget/cap unless the
/// selection carried them via [MemorySelection.budgetTokens]/entryCap.
MemorySelection refilterMemorySelection(
  MemorySelection previous, {
  required Set<String> visibleMessageIds,
  bool chunkBudgeting = false,
  bool disableSourceWindowExclusion = false,
}) {
  if (previous.selectionMode == 'legacy') return previous;
  if (visibleMessageIds.isEmpty) return previous;
  final needsRefilter = previous.allScores.any(
    (s) =>
        !s.excludedBySourceWindow &&
        s.entry.messageIds.isNotEmpty &&
        s.entry.messageIds.any(visibleMessageIds.contains),
  );
  if (!needsRefilter) return previous;
  return MemorySelector.select(
    MemorySelectionInput(
      selectionMode: previous.selectionMode,
      entries: previous.allScores.map((s) => s.entry).toList(),
      keywordMatchedTerms: {
        for (final score in previous.allScores)
          if (score.matchedKeys.isNotEmpty) score.entry.id: score.matchedKeys,
      },
      visibleMessageIds: visibleMessageIds,
      maxInjectionTokens: previous.budgetTokens,
      maxInjectedEntries: previous.entryCap > 0
          ? previous.entryCap
          : previous.entries.length,
      sourceWindowExclusion: !disableSourceWindowExclusion,
      diversityAware: false,
      chunkBudgeting: chunkBudgeting,
    ),
  );
}

RebuiltMemoryContent buildMemoryContentFromSelection(
  MemorySelection selection, {
  MemoryExcerptSelection? excerptSelection,
  String? summaryExcerpt,
}) {
  final injected = excerptSelection ?? MemoryExcerptSelector.select(selection);
  final macro = formatMemoryItems(injected.items, includeContextHeader: false);
  final parts = <String>[];
  if (summaryExcerpt != null && summaryExcerpt.isNotEmpty) {
    parts.add('Summary excerpt:\n$summaryExcerpt');
  }
  parts.add(formatMemoryItems(injected.items, includeContextHeader: true));
  return RebuiltMemoryContent(parts.join('\n\n'), macro);
}

bool replaceDeferredMemoryPlaceholders(
  List<PromptMessage> messages,
  String memoryContent,
) {
  var replaced = false;
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (!message.content.contains(deferredMemoryPlaceholder)) continue;
    messages[i] = PromptMessage(
      role: message.role,
      content: message.content.replaceAll(
        deferredMemoryPlaceholder,
        memoryContent,
      ),
      blockId: message.blockId,
      depth: message.depth,
      isHistory: message.isHistory,
      isDepth: message.isDepth,
      isLorebook: message.isLorebook,
      isSummary: message.isSummary,
      blockName: message.blockName,
      sourceMessageId: message.sourceMessageId,
      reasoningContent: message.reasoningContent,
      imagePath: message.imagePath,
    );
    replaced = true;
  }
  return replaced;
}

Map<String, dynamic> finalizeMemoryCoverage(
  Map<String, dynamic> coverage,
  MemorySelection? selection,
  MemoryExcerptSelection? excerptSelection, {
  bool memoryMacroMissing = false,
}) {
  if (selection == null) {
    if (memoryMacroMissing) {
      return {...coverage, 'memoryMacroMissing': true};
    }
    return coverage;
  }
  final packingMode = coverage['packingMode'] as String? ?? 'hybrid';
  final tokensPerChunk =
      coverage['excerptTokensPerChunk'] as int? ??
      defaultMemoryExcerptTokensPerEntry;
  final chunksPerEntry =
      coverage['excerptChunksPerEntry'] as int? ??
      defaultMemoryExcerptChunksPerEntry;
  final excerpted =
      excerptSelection ??
      MemoryExcerptSelector.select(
        selection,
        packingMode: packingMode,
        maxExcerptTokensPerEntry: tokensPerChunk,
        maxExcerptChunksPerEntry: chunksPerEntry,
      );
  final budget = MemoryBudgetBreakdown(
    effectiveTokens: selection.budgetTokens,
    source: selection.budgetTokens == null ? 'none' : 'effective',
  );
  final diagnostics = MemoryDiagnostics.fromSelection(
    selection,
    budget: budget,
    excerptSelection: excerpted,
    excerptTokensPerChunk: tokensPerChunk,
  ).toJson();
  // The card reads diagnostics directly, so embed the warning there too.
  diagnostics['memoryMacroMissing'] = memoryMacroMissing;
  return {
    ...coverage,
    'packingMode': packingMode,
    'excerptTokensPerChunk': tokensPerChunk,
    'excerptChunksPerEntry': chunksPerEntry,
    'entryIds': excerpted.entries.map((e) => e.id).toList(growable: false),
    'budgetTrimmed': excerpted.budgetTrimmed,
    'memoryMacroMissing': memoryMacroMissing,
    'diagnostics': diagnostics,
  };
}

List<TriggeredEntry> finalizeTriggeredMemories(
  List<TriggeredEntry> previous,
  MemorySelection? selection,
  MemoryExcerptSelection? excerptSelection,
) {
  if (selection == null) return previous;
  final entries = excerptSelection?.entries ?? selection.entries;
  return entries
      .map(
        (e) => TriggeredEntry(
          id: e.id,
          name: e.title.isNotEmpty ? e.title : e.id,
          source: 'memory',
        ),
      )
      .toList(growable: false);
}

/// Recompute a [TokenBreakdown] after the memory block is finalized so
/// `memoryTokens` / `historyBudget` / `totalTokens` / `visibleMessageIds`
/// all reflect the post-cutoff state.
TokenBreakdown recomputeBreakdownWithMemory({
  required ContextCalculator calculator,
  required TokenBreakdown baseBreakdown,
  required List<StaticBlock> attributionBlocks,
  required List<PromptMessage> historyMessages,
  required int lorebookReserveTokens,
  required Map<String, int> macroTokens,
  required int vectorLoreTokens,
  required String memoryContent,
  required String memoryMacroContent,
  required Set<String> visibleMessageIds,
}) {
  // Strip the memory block from attributionBlocks — ContextCalculator
  // would double-count the content otherwise (we pass it explicitly as
  // memoryTokens below).
  final filteredBlocks = attributionBlocks
      .where((b) => b.id != 'memory')
      .toList(growable: false);
  final memoryTokens = estimateTokens(memoryContent);
  final recalculated = calculator.calculate(
    staticBlocks: filteredBlocks,
    historyMessages: historyMessages,
    lorebookReserveTokens: lorebookReserveTokens,
    macroTokens: macroTokens,
    memoryTokens: memoryTokens,
    vectorLoreTokens: vectorLoreTokens,
  );
  // For the non-Studio path, visibleMessageIds came from the initial
  // breakdown (pre-memory cutoff) and is now stale — the recalculated
  // breakdown has the correct, narrower window. Use it directly.
  // For Studio, sourceWindowVisibleMessageIds is an explicit override
  // that must be preserved.
  if (visibleMessageIds.isEmpty) return recalculated;
  return recalculated.copyWithVisible(visibleMessageIds);
}

/// Refilters the v2 memory selection against the visible window now that the
/// cutoff is known, then injects the hard block (or replaces the deferred
/// `{{memory}}` macro placeholder) and recomputes the breakdown with the
/// post-cutoff memory cost.
///
/// Mutates [messages] (memory block insertion / placeholder replacement),
/// [attributionBlocks] (memory static block), and [macroTokens] (memory macro
/// token count) in place. Returns the updated breakdown and selections.
DeferredMemoryResult finalizeDeferredMemory({
  required PromptPayload payload,
  required TokenBreakdown baseBreakdown,
  required List<PromptMessage> messages,
  required List<ResolvedRelativeBlock> appendedEntries,
  required List<StaticBlock> attributionBlocks,
  required List<PromptMessage> historyOnly,
  required Map<String, int> macroTokens,
  required ContextCalculator calculator,
  required int lorebookReserve,
  required int vectorLoreTokens,
}) {
  var breakdown = baseBreakdown;
  final selection = payload.memorySelection!;
  // sourceWindowVisibleMessageIds is the Studio explicit override.
  // For non-Studio, use the base breakdown's visible window — this is
  // already memory-aware because the caller pre-accounted for memory
  // tokens in the initial calculate().
  final sourceWindowVisibleMessageIds = payload.sourceWindowVisibleMessageIds;
  final visibleMessageIds = sourceWindowVisibleMessageIds.isNotEmpty
      ? sourceWindowVisibleMessageIds
      : breakdown.visibleMessageIds;
  final refiltered = refilterMemorySelection(
    selection,
    visibleMessageIds: visibleMessageIds,
    chunkBudgeting: payload.memoryPackingMode == 'chunk_first',
    disableSourceWindowExclusion: payload.disableSourceWindowExclusion,
  );
  MemorySelection? finalMemorySelection = refiltered;
  MemoryExcerptSelection? finalExcerptSelection;
  var memoryMacroMissing = false;

  final useExcerptPacking =
      payload.memoryExcerptingEnabled ||
      payload.memoryPackingMode == 'chunk_first';
  final excerpted = !useExcerptPacking
      ? MemoryExcerptSelector.fullEntries(refiltered)
      : MemoryExcerptSelector.select(
          refiltered,
          packingMode: payload.memoryPackingMode,
          maxExcerptTokensPerEntry: payload.memoryExcerptTokensPerChunk,
          maxExcerptChunksPerEntry: payload.memoryExcerptChunksPerEntry,
          chunkFirstTopEntries: payload.chunkFirstTopEntries,
          chunkFirstTopChunks: payload.chunkFirstTopChunks,
        );
  finalExcerptSelection = excerpted;

  var historyMsgs = historyOnly;

  if (excerpted.items.isNotEmpty) {
    final rebuilt = buildMemoryContentFromSelection(
      refiltered,
      excerptSelection: excerpted,
      summaryExcerpt: payload.summaryContent,
    );
    var memoryContent = rebuilt.content;
    var memoryMacroContent = rebuilt.macroContent;
    final replacedMacro = replaceDeferredMemoryPlaceholders(
      messages,
      rebuilt.macroContent,
    );
    if (replacedMacro) {
      memoryContent = rebuilt.macroContent;
      memoryMacroContent = rebuilt.macroContent;
      historyMsgs = messages.where((m) => m.isHistory).toList(growable: false);
      macroTokens['memory'] = estimateTokens(memoryMacroContent);
    } else if (payload.memoryInjectionTarget == 'hard_block') {
      memoryContent = rebuilt.content;
      final hasMemoryBlock =
          messages.any((m) => m.blockId == 'memory') ||
          appendedEntries.any((b) => b.id == 'memory');
      if (!hasMemoryBlock) {
        injectMemoryBlock(messages, attributionBlocks, rebuilt.content);
      }
    } else {
      // injectionTarget == 'macro' but the preset has no {{memory}}
      // placeholder, so the packed memory has nowhere to go and is dropped.
      final hasMemoryBlock =
          messages.any((m) => m.blockId == 'memory') ||
          appendedEntries.any((b) => b.id == 'memory');
      if (!hasMemoryBlock) {
        memoryMacroMissing = true;
      }
    }
    breakdown = recomputeBreakdownWithMemory(
      calculator: calculator,
      baseBreakdown: breakdown,
      attributionBlocks: attributionBlocks,
      historyMessages: historyMsgs,
      lorebookReserveTokens: lorebookReserve,
      macroTokens: macroTokens,
      vectorLoreTokens: vectorLoreTokens,
      memoryContent: memoryContent,
      memoryMacroContent: memoryMacroContent,
      visibleMessageIds: sourceWindowVisibleMessageIds,
    );
  } else if (refiltered.entries.isEmpty &&
      shouldInjectFactualContinuityGuard(payload)) {
    const guard =
        'Factual continuity note: The latest user message may refer to older context, but no reliable Memory Book entry was selected. Do not invent specific past events; ask for clarification or answer only from visible chat context.';
    final hasMemoryBlock =
        messages.any((m) => m.blockId == 'memory') ||
        appendedEntries.any((b) => b.id == 'memory');
    if (!hasMemoryBlock) {
      injectMemoryBlock(messages, attributionBlocks, guard);
    }
    breakdown = recomputeBreakdownWithMemory(
      calculator: calculator,
      baseBreakdown: breakdown,
      attributionBlocks: attributionBlocks,
      historyMessages: historyMsgs,
      lorebookReserveTokens: lorebookReserve,
      macroTokens: macroTokens,
      vectorLoreTokens: vectorLoreTokens,
      memoryContent: guard,
      memoryMacroContent: '',
      visibleMessageIds: sourceWindowVisibleMessageIds,
    );
  }

  return DeferredMemoryResult(
    breakdown: breakdown,
    finalMemorySelection: finalMemorySelection,
    finalExcerptSelection: finalExcerptSelection,
    memoryMacroMissing: memoryMacroMissing,
  );
}
