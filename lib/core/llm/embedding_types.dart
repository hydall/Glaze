/// Shared data types for embedding and vector search operations.
library;

class ChatMessageForSearch {
  final String role;
  final String content;

  const ChatMessageForSearch({required this.role, required this.content});
}
