import '../../../core/models/chat_message.dart';

/// Build a short single-line preview of a chat message for use in
/// system notifications (Android foreground/background).
/// Strips common markdown markers so the preview is readable in the
/// notification body. Pure function — no Riverpod, no state.
String? buildMessagePreview(List<ChatMessage> messages) {
  try {
    for (final m in messages.reversed) {
      final content = m.content;
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
    }
  } catch (_) {}
  return null;
}
