import '../../../core/models/chat_message.dart';

List<ChatMessage>? mergeContinuationMessages(
  List<ChatMessage> generatedMessages,
  ChatMessage original,
) {
  if (generatedMessages.isEmpty) return null;
  final generated = generatedMessages.last;
  if (generated.role != 'assistant') return null;

  final messages = generatedMessages.sublist(0, generatedMessages.length - 1);
  final originalIdx = messages.indexWhere(
    (message) => message.id == original.id,
  );
  if (originalIdx < 0) return null;
  messages[originalIdx] = mergeContinuationMessage(original, generated);
  return messages;
}

ChatMessage mergeContinuationMessage(
  ChatMessage original,
  ChatMessage generated,
) {
  final content = joinContinuation(original.content, generated.content);
  final reasoning = joinContinuationReasoning(
    original.reasoning,
    generated.reasoning,
  );
  // The badge counts everything generated for this one message, so the
  // continuation's cost is added to the original turn's rather than replacing
  // it (INV-CM7). A run that produced no text adds nothing and leaves the
  // previous boundary alone.
  final tokens = sumContinuationTokens(original.tokens, generated.tokens);
  final genTime = sumContinuationGenTime(original.genTime, generated.genTime);
  final continuationOffset = generated.content.isEmpty
      ? original.continuationOffset
      : continuationOffsetFor(original.content, generated.content);

  final swipes = original.swipes.isEmpty
      ? [content]
      : List<String>.from(original.swipes);
  final swipeId = original.swipes.isEmpty
      ? 0
      : original.swipeId.clamp(0, swipes.length - 1);
  swipes[swipeId] = content;

  final agentSwipes = original.agentSwipes.isEmpty
      ? [
          AgentSwipe(
            content: content,
            kind: 'final',
            reasoning: reasoning,
            genTime: genTime,
            tokens: tokens,
            time: original.time,
            studioOutputs: generated.studioOutputs,
            parentSwipeId: swipeId,
          ),
        ]
      : List<AgentSwipe>.from(original.agentSwipes);
  final agentSwipeId = original.agentSwipes.isEmpty
      ? 0
      : original.agentSwipeId.clamp(0, agentSwipes.length - 1);
  agentSwipes[agentSwipeId] = agentSwipes[agentSwipeId].copyWith(
    content: content,
    reasoning: reasoning,
    genTime: genTime,
    tokens: tokens,
  );

  final swipesMeta = List<Map<String, dynamic>>.from(original.swipesMeta);
  while (swipesMeta.length < swipes.length) {
    swipesMeta.add(<String, dynamic>{});
  }
  swipesMeta[swipeId] = {
    ...swipesMeta[swipeId],
    'reasoning': reasoning,
    'genTime': genTime,
    'tokens': tokens,
    'continuationOffset': continuationOffset,
    'agentSwipes': agentSwipes.map((swipe) => swipe.toJson()).toList(),
    'agentSwipeId': agentSwipeId,
  };

  return original.copyWith(
    content: content,
    reasoning: reasoning,
    genTime: genTime,
    tokens: tokens,
    continuationOffset: continuationOffset,
    swipes: swipes,
    swipeId: swipeId,
    swipesMeta: swipesMeta,
    agentSwipes: agentSwipes,
    agentSwipeId: agentSwipeId,
  );
}

/// Joins an assistant message with the text a continuation run produced.
/// Shared with the live WebView preview so the bubble streams exactly the
/// text the merge will persist.
String joinContinuation(String original, String continuation) {
  if (original.isEmpty) return continuation;
  if (continuation.isEmpty) return original;
  return '$original\n\n$continuation';
}

/// Index in the merged content where the continuation's text begins — that is,
/// how much of [joinContinuation]'s output belongs to the original turn. Used
/// by preview surfaces that would otherwise show the head of a message the
/// user has already read (INV-CM7). Zero when the whole message *is* the
/// continuation.
int continuationOffsetFor(String original, String continuation) {
  if (original.isEmpty || continuation.isEmpty) return 0;
  // joinContinuation glues the two halves with a blank line.
  return original.length + 2;
}

/// Sums the token counts of a message and the continuation that extended it,
/// so the badge reflects everything generated for that one message rather
/// than only the last run. A missing count on either side falls through to the
/// other instead of zeroing the total.
int? sumContinuationTokens(int? original, int? continuation) {
  if (original == null) return continuation;
  if (continuation == null) return original;
  return original + continuation;
}

/// Sums two `"12.3s"` generation times the same way, keeping one decimal. A
/// value that does not parse counts as absent, so a malformed string can never
/// wipe out a good one.
String? sumContinuationGenTime(String? original, String? continuation) {
  final first = _parseGenSeconds(original);
  final second = _parseGenSeconds(continuation);
  if (first == null && second == null) return original ?? continuation;
  final total = (first ?? 0) + (second ?? 0);
  return '${total.toStringAsFixed(1)}s';
}

double? _parseGenSeconds(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final digits = trimmed.endsWith('s')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  return double.tryParse(digits);
}

/// Header the continuation's reasoning is filed under inside the message's
/// existing reasoning block. `==accent==` renders in the active theme's accent
/// colour (see `docs/markdown-markers.md`); the rule above it separates the
/// original turn's thinking from the continuation's.
const _continueReasoningHeader = '---\n\n==accent==Continue==';

/// Joins the reasoning of an assistant message with the reasoning a
/// continuation run produced. The continuation's thinking must never reach the
/// reply text, so it is appended to the reasoning block under its own
/// `Continue` header instead of being dropped or merged into the prose.
/// See `docs/INVARIANTS.md` INV-CM5.
String? joinContinuationReasoning(String? original, String? continuation) {
  final previous = original?.trim() ?? '';
  final next = continuation?.trim() ?? '';
  if (next.isEmpty) return original;
  if (previous.isEmpty) return next;
  return '$previous\n\n$_continueReasoningHeader\n\n$next';
}
