import '../../../core/models/chat_message.dart';

/// Chat history visible to a block attached to [anchorMessageId]
/// (inclusive — the anchor message is included).
List<ChatMessage> messagesUpToAnchor(
  List<ChatMessage> messages,
  String anchorMessageId,
) {
  if (messages.isEmpty || anchorMessageId.isEmpty) {
    return List<ChatMessage>.from(messages);
  }
  final idx = messages.indexWhere((m) => m.id == anchorMessageId);
  if (idx < 0) return List<ChatMessage>.from(messages);
  return messages.sublist(0, idx + 1);
}

/// Builds the message list sent to the block LLM as chat context.
///
/// Count is applied **relative to [anchorMessageId]**, not the end of the
/// session. E.g. count `1` on an older assistant message returns that message
/// even when newer chat messages exist after it.
///
/// - `0` — no chat log (character card / preamble only)
/// - `-1` — full history up to and including the anchor
/// - `N > 0` — last N messages within that scoped history
List<ChatMessage> buildContextMessages({
  required List<ChatMessage> messages,
  required String anchorMessageId,
  required int count,
}) {
  if (count == 0) return [];
  final scoped = messagesUpToAnchor(messages, anchorMessageId);
  if (scoped.isEmpty) return [];
  if (count < 0) return scoped;
  final startIdx = (scoped.length - count).clamp(0, scoped.length);
  return scoped.sublist(startIdx);
}

/// Messages strictly before [anchorMessageId] (for inject / prior-block lookup).
List<ChatMessage> messagesBeforeAnchor(
  List<ChatMessage> messages,
  String anchorMessageId,
) {
  if (messages.isEmpty || anchorMessageId.isEmpty) {
    return List<ChatMessage>.from(messages);
  }
  final idx = messages.indexWhere((m) => m.id == anchorMessageId);
  if (idx <= 0) return const [];
  return messages.sublist(0, idx);
}
