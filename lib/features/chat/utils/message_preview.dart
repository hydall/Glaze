import '../../../core/models/chat_message.dart';

/// Finds the completed assistant message without falling back to another turn.
ChatMessage? findNotificationMessage(
  List<ChatMessage> messages,
  String messageId,
) {
  for (final message in messages) {
    if (message.id != messageId) continue;
    final isAssistant =
        message.role == 'assistant' || message.role == 'character';
    if (!isAssistant ||
        message.isError ||
        message.isTyping ||
        message.isHidden) {
      return null;
    }
    return message;
  }
  return null;
}

/// Builds a short single-line notification preview for one known message.
/// A continued message is previewed from its continuation boundary so the
/// notification announces only the text that was just generated (INV-CM7).
String? buildMessagePreview(ChatMessage message) {
  try {
    final content = previewSource(message.content, message.continuationOffset);
    if (content.isNotEmpty) {
      final text = content
          .replaceAll(RegExp(r'\*\*[^*]+\*\*'), '')
          .replaceAll(RegExp(r'\*[^*]+\*'), '')
          .replaceAll(RegExp(r'==[^=]+=='), '')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isNotEmpty) {
        return text.length > 80 ? '${text.substring(0, 80)}...' : text;
      }
    }
  } catch (_) {}
  return null;
}
