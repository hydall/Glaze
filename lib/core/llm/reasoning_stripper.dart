/// Pure static helpers that strip chain-of-thought / `<think>` reasoning
/// directives from text. Extracted from the two near-identical regex sets that
/// previously lived in `AgentRunner` (message-level) and
/// `StudioDecompositionService` (prompt-shard-level). The two near-identical
/// regex sets were consolidated into this single helper.
///
/// The two operations are intentionally kept separate because they differ:
/// - [stripMessageReasoning] also rewrites literal `<think>` / `</think>` tags
///   to the words "hidden reasoning" (it runs on the final outbound `messages`
///   right before transport, where stray tags must not reach the model).
/// - [stripPromptShardReasoning] additionally strips a `## Language Rule`
///   directive and uses a stricter `Use <think>…</think>` pattern, but leaves
///   literal tags untouched (it runs at build time on agent prompt shards).
///
/// Both are no-behavior-change extractions of the original methods.
class ReasoningStripper {
  ReasoningStripper._();

  /// Strip `<think>` / "Plan internally" directives from a list of chat
  /// messages before sending to a model that won't honor them. Operates on the
  /// `content` field of each message map; non-string content is passed through.
  ///
  /// Ported verbatim from `AgentRunner.stripPromptLevelReasoning`.
  static List<Map<String, dynamic>> stripMessageReasoning(
    List<Map<String, dynamic>> messages,
  ) {
    return [
      for (final message in messages)
        {
          ...message,
          if (message['content'] is String)
            'content': _stripThinkDirective(message['content'] as String),
        },
    ];
  }

  static String _stripThinkDirective(String content) {
    var result = content;
    final patterns = <RegExp>[
      RegExp(
        r'\s*Plan internally[^.]*<think>[\s\S]*?(?:after\s*</think>|</think>)[^.]*\. ?',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*Think internally[^.]*<think>[\s\S]*?(?:after\s*</think>|</think>)[^.]*\. ?',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*Use\s\s*(?:for|to)[^.]*\. ?',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      result = result.replaceAll(pattern, ' ');
    }
    result = result.replaceAll('<think>', 'hidden reasoning');
    result = result.replaceAll('</think>', 'hidden reasoning');
    result = result.replaceAll(RegExp(r'\s{2,}'), ' ');
    return result.trim();
  }

  /// Strip chain-of-thought directives from a single agent prompt shard at
  /// build time. Unlike [stripMessageReasoning], this also removes a
  /// `## Language Rule` directive and does NOT rewrite literal `<think>` tags.
  ///
  /// Ported verbatim from `StudioDecompositionService._stripPromptLevelReasoning`.
  static String stripPromptShardReasoning(String text) {
    var result = text;
    final patterns = <RegExp>[
      RegExp(
        r'\s*Plan internally[^.]*<think>[\s\S]*?(?:after\s*</think>|</think>)[^.]*\. ?',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*Think internally[^.]*<think>[\s\S]*?(?:after\s*</think>|</think>)[^.]*\. ?',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*Use\s+<think>[\s\S]*?</think>\s*(?:for|to)[^.]*\. ?',
        caseSensitive: false,
      ),
      RegExp(
        r'\s*## Language Rule\s*- The hidden <think>[\s\S]*?(?:usually Russian\.|$)',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      result = result.replaceAll(pattern, ' ');
    }
    return result.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }
}
