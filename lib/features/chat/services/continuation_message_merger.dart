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
            reasoning: generated.reasoning,
            genTime: generated.genTime,
            tokens: generated.tokens,
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
  );

  final swipesMeta = List<Map<String, dynamic>>.from(original.swipesMeta);
  while (swipesMeta.length < swipes.length) {
    swipesMeta.add(<String, dynamic>{});
  }
  swipesMeta[swipeId] = {
    ...swipesMeta[swipeId],
    'agentSwipes': agentSwipes.map((swipe) => swipe.toJson()).toList(),
    'agentSwipeId': agentSwipeId,
  };

  return original.copyWith(
    content: content,
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
