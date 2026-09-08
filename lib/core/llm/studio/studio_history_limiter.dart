import '../history_assembler.dart';
import '../../models/studio_config.dart';
import '../tokenizer.dart';

/// History-trimming + text-truncation specialist extracted from
/// `StudioMessageBuilder` (plan Phase 5b). Pure static methods — no deps.
class StudioHistoryLimiter {
  /// Hard cap on tracker context size (Marinara MAX_AGENT_CONTEXT_MESSAGES).
  static const maxTrackerContextSize = 200;

  /// Token budget for the final generator's chat history. After slicing to
  /// [maxFinalHistoryMessages], messages are trimmed from the oldest end
  /// until the total token count (estimated via o200k_base) fits this budget.
  /// 60K tokens ≈ 240K chars — enough for ~30 messages of typical RP length
  /// while preventing context overflow on very long messages.
  static const finalHistoryTokenBudget = 60000;

  static final _htmlTagRegex = RegExp(r'</?[a-zA-Z][^>]*>');
  static final _multiNewlineRegex = RegExp(r'\n{3,}');
  static final _fontTagRegex = RegExp(r'</?font\b[^>]*>', caseSensitive: false);

  /// Cap how many trailing chat messages reach the FINAL responder.
  ///
  /// Two limits, whichever is hit first:
  /// 1. **Message count** — at most [StudioConfig.maxFinalHistoryMessages]
  ///    (default 30) trailing messages.
  /// 2. **Token budget** — at most [finalHistoryTokenBudget] (60K) estimated
  ///    tokens across the selected messages.
  ///
  /// We walk backwards from the end of [history], accumulating messages until
  /// either limit is reached. The current user turn (last message) is always
  /// included. 0 (or negative) message count means no message-count limit
  /// (token budget still applies). Each message has `<font>` tags stripped.
  static List<PromptMessage> limitFinalHistory(
    List<PromptMessage> history,
    StudioConfig config, {
    int pipelineOverride = 0,
    int reasoningHistoryCount = 0,
  }) {
    final msgLimit = pipelineOverride > 0
        ? pipelineOverride
        : config.maxFinalHistoryMessages;

    if (history.isEmpty) return const [];

    // Walk backwards from the end, stop at msgLimit or tokenBudget.
    final selected = <PromptMessage>[];
    var totalTokens = 0;
    final includeAllReasoning = reasoningHistoryCount == -1;
    var remainingReasoning = reasoningHistoryCount;
    for (var i = history.length - 1; i >= 0; i--) {
      final m = history[i];
      final cleaned = stripFontTags(m.content);
      var tokens = estimateTokens(cleaned);
      final reasoning = m.reasoningContent?.trim();
      if ((includeAllReasoning || remainingReasoning > 0) &&
          m.role == 'assistant' &&
          reasoning?.isNotEmpty == true) {
        tokens += estimateTokens(reasoning!);
        if (!includeAllReasoning) remainingReasoning--;
      }
      // Always keep at least the last message.
      if (selected.isNotEmpty &&
          totalTokens + tokens > finalHistoryTokenBudget) {
        break;
      }
      selected.insert(
        0,
        PromptMessage(
          role: m.role,
          content: cleaned,
          reasoningContent: m.reasoningContent,
          imagePath: m.imagePath,
        ),
      );
      totalTokens += tokens;
      if (msgLimit > 0 && selected.length >= msgLimit) break;
    }

    return selected;
  }

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
