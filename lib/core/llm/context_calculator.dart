import 'history_trim.dart';
import 'tokenizer.dart';
import 'history_assembler.dart';

class StaticBlock {
  final String id;
  final String content;
  const StaticBlock({required this.id, required this.content});

  Map<String, dynamic> toJson() => {'id': id, 'content': content};

  factory StaticBlock.fromJson(Map<String, dynamic> json) =>
      StaticBlock(id: json['id'] as String, content: json['content'] as String);
}

class ContextCalculator {
  final int contextSize;
  final int maxTokens;
  final int reasoningHistoryCount;
  final bool excludeReasoningFromContextBudget;

  /// [HistoryTrimMode.sliding] or [HistoryTrimMode.stepped].
  final String historyTrimMode;

  /// Oldest message the last stepped trim anchored on, when there is one. It is
  /// honoured only while the window it opens still fits the budget — that check
  /// is what makes a smaller window (a raised `maxTokens`, a grown lorebook)
  /// move the anchor instead of silently overflowing.
  final String? historyAnchorId;

  /// Stepped mode: how full the held window may get before the anchor moves,
  /// and how much of the budget the move gives back. Percentages of the history
  /// budget, clamped to sane ranges by the trim itself.
  final int historyTrimTriggerPercent;
  final int historyTrimStepPercent;

  ContextCalculator({
    required this.contextSize,
    required this.maxTokens,
    this.reasoningHistoryCount = 0,
    this.excludeReasoningFromContextBudget = false,
    String historyTrimMode = HistoryTrimMode.sliding,
    this.historyAnchorId,
    this.historyTrimTriggerPercent = kDefaultHistoryTrimTriggerPercent,
    this.historyTrimStepPercent = kDefaultHistoryTrimStepPercent,
  }) : historyTrimMode = HistoryTrimMode.normalize(historyTrimMode);

  /// Context window available for the *prompt*, i.e. everything we send.
  ///
  /// The provider enforces `prompt_tokens + max_tokens <= contextSize`, where
  /// `max_tokens` is the completion budget the transport layer sends with every
  /// request (see *_chat_transport.dart). If we let the prompt grow up to the
  /// full [contextSize] the model has no room left to answer and returns an
  /// empty completion. Reserving [maxTokens] up front mirrors the fallback
  /// builder and keeps a guaranteed completion budget. Clamped to >= 0 so a
  /// misconfigured `maxTokens >= contextSize` never yields a negative window.
  int get safeContext {
    final reserved = contextSize - maxTokens;
    return reserved > 0 ? reserved : 0;
  }

  TokenBreakdown calculate({
    required List<StaticBlock> staticBlocks,
    required List<PromptMessage> historyMessages,
    int lorebookReserveTokens = 0,
    int memoryTokens = 0,
    int vectorLoreTokens = 0,
    Map<String, int> macroTokens = const {},
  }) {
    final sourceTokens = <String, int>{};
    var staticTotal = 0;

    for (final block in staticBlocks) {
      final tokens = estimateTokens(block.content);
      final source = _sourceForBlock(block.id);
      sourceTokens[source] = (sourceTokens[source] ?? 0) + tokens;
      staticTotal += tokens;
    }

    final actualLorebook =
        (sourceTokens['lorebook'] ?? 0) + (macroTokens['lorebooks'] ?? 0);
    final effectiveReserve = lorebookReserveTokens > actualLorebook
        ? lorebookReserveTokens - actualLorebook
        : 0;

    final historyBudget =
        safeContext - staticTotal - effectiveReserve - memoryTokens;

    final (trimmedHistory, cutoffIndex) = _trimHistory(
      historyMessages,
      historyBudget > 0 ? historyBudget : 0,
    );

    // The anchor a stepped trim settled on, for the caller to persist. Null in
    // sliding mode, so switching back to stepped re-anchors from scratch
    // instead of resurrecting a stale cutoff.
    final resolvedAnchor = historyTrimMode == HistoryTrimMode.stepped
        ? trimmedHistory.firstOrNull?.sourceMessageId
        : null;

    final historyTokens = _historyTokens(trimmedHistory);
    sourceTokens['history'] = historyTokens;

    if (vectorLoreTokens > 0) {
      sourceTokens['vectorLore'] = vectorLoreTokens;
    }

    final fixedTotal =
        staticTotal + effectiveReserve + memoryTokens + vectorLoreTokens;
    final remaining = safeContext - fixedTotal - historyTokens;

    // sentTokens = tokens actually sent in the request (no unspent reserve).
    // fixedTotal includes effectiveReserve which shrinks the history budget but
    // is never literally in the payload; exclude it so HeroCard matches
    // the provider's prompt_tokens as closely as possible.
    final sentTokens =
        staticTotal + memoryTokens + vectorLoreTokens + historyTokens;

    return TokenBreakdown(
      sourceTokens: sourceTokens,
      macroTokens: macroTokens,
      staticTotal: staticTotal,
      historyBudget: historyBudget,
      historyTokens: historyTokens,
      totalTokens: sentTokens,
      cutoffIndex: cutoffIndex,
      trimmedHistory: trimmedHistory,
      historyAnchorId: resolvedAnchor,
      lorebookReserveTokens: lorebookReserveTokens,
      memoryTokens: memoryTokens,
      vectorLoreTokens: vectorLoreTokens,
      fixedTotal: fixedTotal,
      remaining: remaining,
      visibleMessageIds: trimmedHistory
          .map((m) => m.sourceMessageId)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet(),
    );
  }

  String _sourceForBlock(String blockId) {
    return switch (blockId) {
      'char_card' => 'description',
      'char_personality' => 'personality',
      'scenario' => 'scenario',
      'example_dialogue' => 'mesExamples',
      'char_depth_prompt' => 'depthPrompt',
      'user_persona' => 'persona',
      'summary' => 'summary',
      'authors_note' => 'authorsNote',
      'chat_history' => 'history',
      'worldInfoBefore' || 'worldInfoAfter' => 'lorebook',
      'memory' => 'memory',
      _ => 'preset',
    };
  }

  (List<PromptMessage>, int) _trimHistory(
    List<PromptMessage> messages,
    int budget,
  ) {
    if (budget <= 0) return (<PromptMessage>[], messages.length);
    return historyTrimMode == HistoryTrimMode.stepped
        ? _trimStepped(messages, budget)
        : _trimSliding(messages, budget);
  }

  /// Keeps the start of the history still for as long as it fits, then jumps it
  /// forward by a block instead of a message.
  ///
  /// Between jumps every request begins with the same bytes, which is what lets
  /// a provider's prefix cache hit; a sliding cut moves the start almost every
  /// turn and misses every time. See [HistoryTrimMode.stepped].
  (List<PromptMessage>, int) _trimStepped(
    List<PromptMessage> messages,
    int budget,
  ) {
    final anchorId = historyAnchorId;
    if (anchorId != null && anchorId.isNotEmpty) {
      final index = messages.indexWhere((m) => m.sourceMessageId == anchorId);
      // A missing anchor means the message was deleted or this is a branch —
      // step afresh rather than silently falling back to the whole history.
      if (index >= 0) {
        final kept = messages.sublist(index);
        // Trigger below 100 %: stepping only once the window is already over
        // budget leaves no room for the turn that pushed it there, and the
        // anchor would have to move again immediately.
        final trigger = historyTrimTriggerPercent.clamp(1, 100) / 100;
        if (_historyTokens(kept) <= budget * trigger) return (kept, index);
      }
    }

    // Re-anchor with headroom: the freed share is what the following turns
    // grow into, and how long the prefix — and the cache with it — holds still.
    final step = historyTrimStepPercent.clamp(1, 95) / 100;
    final target = (budget * (1 - step)).floor();
    if (target > 0) {
      final stepped = _trimSliding(messages, target);
      // Unless the newest message alone is bigger than the reduced target: a
      // stepped prompt must never carry less history than a sliding one would.
      if (stepped.$1.isNotEmpty) return stepped;
    }
    return _trimSliding(messages, budget);
  }

  (List<PromptMessage>, int) _trimSliding(
    List<PromptMessage> messages,
    int budget,
  ) {
    final kept = <PromptMessage>[];
    var used = 0;
    final includeAllReasoning = reasoningHistoryCount == -1;
    var remainingReasoning = reasoningHistoryCount;

    for (int i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      var tokens = estimateTokens(message.content);
      final reasoning = message.reasoningContent?.trim();
      final includesReasoning =
          (includeAllReasoning || remainingReasoning > 0) &&
          message.role == 'assistant' &&
          reasoning?.isNotEmpty == true;
      if (includesReasoning && !excludeReasoningFromContextBudget) {
        tokens += estimateTokens(reasoning!);
      }
      if (used + tokens > budget) break;
      used += tokens;
      kept.insert(0, message);
      if (includesReasoning && !includeAllReasoning) remainingReasoning--;
    }

    final cutoff = messages.length - kept.length;
    return (kept, cutoff);
  }

  int _historyTokens(List<PromptMessage> messages) {
    var tokens = 0;
    final includeAllReasoning = reasoningHistoryCount == -1;
    var remainingReasoning = reasoningHistoryCount;
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      tokens += estimateTokens(message.content);
      final reasoning = message.reasoningContent?.trim();
      if ((includeAllReasoning || remainingReasoning > 0) &&
          message.role == 'assistant' &&
          reasoning?.isNotEmpty == true) {
        tokens += estimateTokens(reasoning!);
        if (!includeAllReasoning) remainingReasoning--;
      }
    }
    return tokens;
  }
}

class TokenBreakdown {
  final Map<String, int> sourceTokens;
  final Map<String, int> macroTokens;
  final int staticTotal;
  final int historyBudget;
  final int historyTokens;
  final int totalTokens;
  final int cutoffIndex;
  final List<PromptMessage> trimmedHistory;

  /// Oldest kept message under [HistoryTrimMode.stepped] — the anchor the next
  /// turn should reuse. Null in sliding mode, where there is nothing to hold.
  final String? historyAnchorId;
  final int lorebookReserveTokens;
  final int memoryTokens;
  final int vectorLoreTokens;
  final int fixedTotal;
  final int remaining;
  final Set<String> visibleMessageIds;

  const TokenBreakdown({
    required this.sourceTokens,
    this.macroTokens = const {},
    required this.staticTotal,
    required this.historyBudget,
    required this.historyTokens,
    required this.totalTokens,
    required this.cutoffIndex,
    required this.trimmedHistory,
    this.historyAnchorId,
    this.lorebookReserveTokens = 0,
    this.memoryTokens = 0,
    this.vectorLoreTokens = 0,
    this.fixedTotal = 0,
    this.remaining = 0,
    this.visibleMessageIds = const {},
  });

  Map<String, dynamic> toJson() => {
    'sourceTokens': sourceTokens,
    'macroTokens': macroTokens,
    'staticTotal': staticTotal,
    'historyBudget': historyBudget,
    'historyTokens': historyTokens,
    'totalTokens': totalTokens,
    'cutoffIndex': cutoffIndex,
    'trimmedHistory': trimmedHistory.map((m) => m.toJson()).toList(),
    'historyAnchorId': historyAnchorId,
    'lorebookReserveTokens': lorebookReserveTokens,
    'memoryTokens': memoryTokens,
    'vectorLoreTokens': vectorLoreTokens,
    'fixedTotal': fixedTotal,
    'remaining': remaining,
    'visibleMessageIds': visibleMessageIds.toList(),
  };

  factory TokenBreakdown.fromJson(Map<String, dynamic> json) => TokenBreakdown(
    sourceTokens: Map<String, int>.from(json['sourceTokens'] as Map),
    macroTokens: Map<String, int>.from(json['macroTokens'] as Map? ?? {}),
    staticTotal: json['staticTotal'] as int,
    historyBudget: json['historyBudget'] as int,
    historyTokens: json['historyTokens'] as int,
    totalTokens: json['totalTokens'] as int,
    cutoffIndex: json['cutoffIndex'] as int,
    trimmedHistory: (json['trimmedHistory'] as List)
        .map((m) => PromptMessage.fromJson(m as Map<String, dynamic>))
        .toList(),
    historyAnchorId: json['historyAnchorId'] as String?,
    lorebookReserveTokens: json['lorebookReserveTokens'] as int? ?? 0,
    memoryTokens: json['memoryTokens'] as int? ?? 0,
    vectorLoreTokens: json['vectorLoreTokens'] as int? ?? 0,
    fixedTotal: json['fixedTotal'] as int? ?? 0,
    remaining: json['remaining'] as int? ?? 0,
    visibleMessageIds: (json['visibleMessageIds'] as List? ?? const [])
        .whereType<String>()
        .toSet(),
  );

  /// Oldest message the prompt still carries — where the history the model
  /// sees begins. Null when the trim kept nothing, or when the kept messages
  /// carry no source id (a Studio-built window, a synthetic block).
  ///
  /// Read from [trimmedHistory] rather than from [historyAnchorId]: the anchor
  /// exists only under [HistoryTrimMode.stepped], and the chat marks the same
  /// boundary whichever mode produced it.
  String? get windowStartMessageId {
    for (final message in trimmedHistory) {
      final id = message.sourceMessageId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  int get lorebookTotal =>
      (sourceTokens['lorebook'] ?? 0) +
      (macroTokens['lorebooks'] ?? 0) +
      vectorLoreTokens;

  double get historyFillPercent => historyBudget > 0
      ? (historyTokens / historyBudget * 100).clamp(0, 100)
      : 0;

  /// Returns a copy with the visible message ids replaced. Used by
  /// [buildPrompt] to keep the recomputed breakdown consistent with
  /// the post-cutoff state after the deferred memory refilter.
  TokenBreakdown copyWithVisible(Set<String> visibleMessageIds) {
    return TokenBreakdown(
      sourceTokens: sourceTokens,
      macroTokens: macroTokens,
      staticTotal: staticTotal,
      historyBudget: historyBudget,
      historyTokens: historyTokens,
      totalTokens: totalTokens,
      cutoffIndex: cutoffIndex,
      trimmedHistory: trimmedHistory,
      historyAnchorId: historyAnchorId,
      lorebookReserveTokens: lorebookReserveTokens,
      memoryTokens: memoryTokens,
      vectorLoreTokens: vectorLoreTokens,
      fixedTotal: fixedTotal,
      remaining: remaining,
      visibleMessageIds: visibleMessageIds,
    );
  }

  /// Preset row in the tokenizer. Same as [sourceTokens]['preset']: external
  /// injections are already blanked in `contentForAccounting` (see INV-PS5).
  int get presetNetTokens => sourceTokens['preset'] ?? 0;
}
