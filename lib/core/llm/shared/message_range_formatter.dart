import '../../models/chat_message.dart';

/// Default per-message character cap for [formatRecentMessages].
const kDefaultMaxMessageChars = 3000;

/// Formats recent chat messages into a compact literal block for LLM prompts.
///
/// Each message is trimmed to [maxChars] characters to keep the prompt within
/// a reasonable token budget. Empty messages are skipped. The role is
/// normalized to `assistant` or `user` and the message id is appended as
/// `#<id>` when present.
///
/// Used by `PostCleanerService` (cleaner + audit prompts) and available as a
/// shared utility for any other prompt builder that needs a compact recent-
/// history block.
String formatRecentMessages(
  List<ChatMessage> messages, [
  int maxChars = kDefaultMaxMessageChars,
]) {
  final buf = StringBuffer();
  for (final m in messages) {
    if (m.content.trim().isEmpty) continue;
    final role = m.role == 'assistant' ? 'assistant' : 'user';
    final idSuffix = m.id.isNotEmpty ? ' #${m.id}' : '';
    var content = m.content;
    if (content.length > maxChars) {
      content = '${content.substring(0, maxChars)}…';
    }
    buf.writeln('[$role$idSuffix]');
    buf.writeln(content);
    buf.writeln();
  }
  return buf.toString().trimRight();
}
