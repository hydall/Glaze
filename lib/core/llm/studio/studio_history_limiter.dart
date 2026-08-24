import '../history_assembler.dart';
import '../../models/studio_config.dart';
import '../tokenizer.dart';

/// History-trimming + text-truncation specialist extracted from
/// `StudioMessageBuilder` (plan Phase 5b). Pure static methods — no deps.
class StudioHistoryLimiter {
  /// Hard cap on tracker context size (Marinara MAX_AGENT_CONTEXT_MESSAGES).
  static const maxTrackerContextSize = 200;

  /// High-water mark for the final generator's chat history.
  /// 70K tokens keeps a generous history window while leaving room for the
  /// preset's static and dynamic blocks.
  static const finalHistoryTokenBudget = 70000;

  /// Session variable storing the first chat message in the stable Studio
  /// history window. The boundary advances only after a completed assistant
  /// turn, so adding a user message never invalidates the cached prefix.
  static const historyWindowStartVar = '__studioHistoryWindowStart';

  static final _htmlTagRegex = RegExp(r'</?[a-zA-Z][^>]*>');
  static final _multiNewlineRegex = RegExp(r'\n{3,}');
  static final _fontTagRegex = RegExp(r'</?font\b[^>]*>', caseSensitive: false);

  /// Cap how many trailing chat messages reach the FINAL responder.
  ///
  /// Two high-water marks, whichever is hit first:
  /// 1. **Message count** — at most [StudioPreset.maxFinalHistoryMessages]
  ///    (default 50) trailing messages.
  /// 2. **Token budget** — at most [finalHistoryTokenBudget] (70K) estimated
  ///    tokens across the selected messages.
  ///
  /// A persisted window boundary is stable between rotations. Rotation happens
  /// after a completed assistant reply, drops roughly half the old window on a
  /// chunk boundary, and never runs merely because a user message was added.
  /// Each returned message has `<font>` tags stripped.
  static List<PromptMessage> limitFinalHistory(
    List<PromptMessage> history,
    StudioPreset preset, {
    int pipelineOverride = 0,
    int reasoningHistoryCount = 0,
    bool excludeReasoningFromContextBudget = false,
    String? historyWindowStartMessageId,
  }) {
    if (history.isEmpty) return const [];

    final cleanedHistory = history.map(_cleanMessage).toList(growable: false);
    final persistedStart = cleanedHistory.indexWhere(
      (message) => message.sourceMessageId == historyWindowStartMessageId,
    );
    if (persistedStart >= 0) {
      return cleanedHistory.sublist(persistedStart);
    }

    final maxMessages = pipelineOverride > 0
        ? pipelineOverride
        : preset.maxFinalHistoryMessages;
    return _bootstrapWindow(
      cleanedHistory,
      maxMessages: maxMessages,
      reasoningHistoryCount: reasoningHistoryCount,
      excludeReasoningFromContextBudget: excludeReasoningFromContextBudget,
    );
  }

  /// Derives a safe initial window for sessions created before stable window
  /// boundaries existed. A trailing incomplete chunk is always retained, while
  /// only the already-completed prefix is eligible for rotation.
  static List<PromptMessage> _bootstrapWindow(
    List<PromptMessage> history, {
    required int maxMessages,
    required int reasoningHistoryCount,
    required bool excludeReasoningFromContextBudget,
  }) {
    var completedEnd = history.length;
    while (completedEnd > 0 && history[completedEnd - 1].role != 'assistant') {
      completedEnd--;
    }
    if (completedEnd == 0) return history;

    final completedPlan = planCompletedWindow(
      history.sublist(0, completedEnd),
      maxMessages: maxMessages,
      reasoningHistoryCount: reasoningHistoryCount,
      excludeReasoningFromContextBudget: excludeReasoningFromContextBudget,
    );
    if (completedEnd == history.length) return completedPlan.messages;
    return [...completedPlan.messages, ...history.sublist(completedEnd)];
  }

  /// Advances a stable history window after a complete user-assistant chunk.
  /// When either high-water mark is crossed, whole chunks are discarded until
  /// roughly half the configured message capacity remains.
  static StudioHistoryWindowPlan planCompletedWindow(
    List<PromptMessage> history, {
    required int maxMessages,
    int reasoningHistoryCount = 0,
    bool excludeReasoningFromContextBudget = false,
  }) {
    if (history.isEmpty || history.last.role != 'assistant') {
      return StudioHistoryWindowPlan(messages: history);
    }

    var selected = history;
    var dropped = 0;
    while (_exceedsWindow(
      selected,
      maxMessages: maxMessages,
      reasoningHistoryCount: reasoningHistoryCount,
      excludeReasoningFromContextBudget: excludeReasoningFromContextBudget,
    )) {
      final targetCount = (selected.length / 2).ceil();
      final idealStart = (selected.length - targetCount).clamp(
        1,
        selected.length - 1,
      );
      final nextStart = _nextChunkStart(selected, idealStart);
      if (nextStart <= 0 || nextStart >= selected.length) break;
      dropped += nextStart;
      selected = selected.sublist(nextStart);
    }

    return StudioHistoryWindowPlan(
      messages: selected,
      droppedMessageCount: dropped,
      didRotate: dropped > 0,
    );
  }

  static bool _exceedsWindow(
    List<PromptMessage> history, {
    required int maxMessages,
    required int reasoningHistoryCount,
    required bool excludeReasoningFromContextBudget,
  }) {
    if (maxMessages > 0 && history.length > maxMessages) return true;
    return _historyTokens(
          history,
          reasoningHistoryCount: reasoningHistoryCount,
          excludeReasoningFromContextBudget: excludeReasoningFromContextBudget,
        ) >
        finalHistoryTokenBudget;
  }

  static int _nextChunkStart(List<PromptMessage> history, int from) {
    for (var i = from; i < history.length; i++) {
      if (history[i].role == 'user' && history[i - 1].role == 'assistant') {
        return i;
      }
    }
    return 0;
  }

  static int _historyTokens(
    List<PromptMessage> history, {
    required int reasoningHistoryCount,
    required bool excludeReasoningFromContextBudget,
  }) {
    var total = 0;
    final includeAllReasoning = reasoningHistoryCount == -1;
    var remainingReasoning = reasoningHistoryCount;
    for (var i = history.length - 1; i >= 0; i--) {
      final message = history[i];
      total += estimateTokens(message.content);
      final reasoning = message.reasoningContent?.trim();
      if ((includeAllReasoning || remainingReasoning > 0) &&
          message.role == 'assistant' &&
          reasoning?.isNotEmpty == true) {
        if (!excludeReasoningFromContextBudget) {
          total += estimateTokens(reasoning!);
        }
        if (!includeAllReasoning) remainingReasoning--;
      }
    }
    return total;
  }

  static PromptMessage _cleanMessage(PromptMessage message) => PromptMessage(
    role: message.role,
    content: stripFontTags(message.content),
    sourceMessageId: message.sourceMessageId,
    reasoningContent: message.reasoningContent,
    imagePath: message.imagePath,
  );

  /// Trim trailing chat history for a tracker (intermediate agent).
  ///
  /// Returns the last [contextSize] messages (clamped to
  /// `1..[maxTrackerContextSize]`), each stripped of HTML via [stripHtmlTags].
  /// No per-message character cap — Sonnet's 200K context easily absorbs full
  /// messages, and truncating the middle of a scene breaks continuity tracking.
  static List<PromptMessage> limitTrackerHistory(
    List<PromptMessage> history,
    int contextSize,
  ) {
    final normalized = contextSize.clamp(1, maxTrackerContextSize);
    if (history.length <= normalized) {
      return history
          .map(
            (m) => PromptMessage(
              role: m.role,
              content: stripHtmlTags(m.content),
              sourceMessageId: m.sourceMessageId,
              imagePath: m.imagePath,
            ),
          )
          .toList();
    }
    final trimmed = history.sublist(history.length - normalized);
    return trimmed
        .map(
          (m) => PromptMessage(
            role: m.role,
            content: stripHtmlTags(m.content),
            sourceMessageId: m.sourceMessageId,
            imagePath: m.imagePath,
          ),
        )
        .toList();
  }

  /// Port of Marinara `stripHtmlTags`. Removes HTML/XML-like tags, collapses
  /// 3+ newlines to 2, trims. Conservative: only strips tags that start with
  /// a letter (avoids eating `==...==` custom markers or fenced code).
  static String stripHtmlTags(String text) {
    final stripped = text.replaceAll(_htmlTagRegex, '');
    final collapsed = stripped.replaceAll(_multiNewlineRegex, '\n\n');
    return collapsed.trim();
  }

  /// Strips only `<font>` tags from text, preserving the inner content and
  /// all other HTML (e.g. `<lumiaooc>`, `<i>`, `<b>`). Used for the final
  /// responder's chat history so the model does not see cosmetic color
  /// styling applied by the post-cleaner and does not mimic it.
  static String stripFontTags(String text) {
    return text.replaceAll(_fontTagRegex, '');
  }
}

class StudioHistoryWindowPlan {
  final List<PromptMessage> messages;
  final int droppedMessageCount;
  final bool didRotate;

  const StudioHistoryWindowPlan({
    required this.messages,
    this.droppedMessageCount = 0,
    this.didRotate = false,
  });

  String? get startMessageId =>
      messages.isEmpty ? null : messages.first.sourceMessageId;
}
