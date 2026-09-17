import 'chat_message.dart';

/// Exact selected variations preceding a regeneration target. Message order,
/// rather than database write time, determines the historical boundary.
final class HistoricalMessageWindow {
  HistoricalMessageWindow(Iterable<ChatMessage> messages)
    : messages = List.unmodifiable(messages),
      byId = Map.unmodifiable({
        for (final message in messages) message.id: message,
      });

  factory HistoricalMessageWindow.before(
    List<ChatMessage> messages,
    String targetId,
  ) {
    final index = messages.indexWhere((message) => message.id == targetId);
    if (index < 0) throw StateError('Historical generation target is missing.');
    return HistoricalMessageWindow(messages.take(index));
  }

  final List<ChatMessage> messages;
  final Map<String, ChatMessage> byId;

  bool containsAnchor(String messageId, int swipeId, int agentSwipeId) {
    final message = byId[messageId];
    return message != null &&
        message.swipeId == swipeId &&
        message.agentSwipeId == agentSwipeId;
  }

  bool containsSources(Iterable<String> ids) =>
      ids.isNotEmpty && ids.every(byId.containsKey);
}
