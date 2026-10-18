import '../models/chat_message.dart';

/// Adds the active variation's Ledger clock for auxiliary consumers such as
/// Memory and Summary. Main-model chat history must use [ChatMessage.content]
/// directly and must never call this helper.
String auxiliaryTimedContent(ChatMessage message) {
  final time = message.time?.trim();
  if (time == null || time.isEmpty) return message.content;
  return '[$time] ${message.content}';
}
