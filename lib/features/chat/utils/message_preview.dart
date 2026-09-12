import '../../../core/models/chat_message.dart';

/// Build a short single-line preview of a chat message for use in
/// system notifications (Android foreground/background).
/// Strips common markdown markers so the preview is readable in the
/// notification body. Pure function — no Riverpod, no state.
///
/// A message a Continue run extended is previewed from its continuation
/// boundary, so the notification announces the text that was just generated
/// instead of the opening the user has already read (INV-CM7).
String? buildMessagePreview(List<ChatMessage> messages) {
  try {
    for (final m in messages.reversed) {
      final content = previewSource(m.content, m.continuationOffset);
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
