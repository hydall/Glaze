import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/generation_pipeline.dart';

void main() {
  test(
    'regeneration identifies changed evidence under a stable message id',
    () {
      final before = _session(_assistant('old', swipeId: 0, agentSwipeId: 0));
      final after = _session(
        _assistant('regenerated', swipeId: 1, agentSwipeId: 2),
      );

      expect(
        changedRegenerationEvidenceIds(
          before: before,
          after: after,
          regenTargetId: 'assistant',
        ),
        {'assistant'},
      );
      expect(
        changedRegenerationEvidenceIds(
          before: before,
          after: before,
          regenTargetId: 'assistant',
        ),
        isEmpty,
      );
      expect(
        changedRegenerationEvidenceIds(
          before: before,
          after: after,
          regenTargetId: null,
        ),
        isEmpty,
      );
    },
  );
}

ChatSession _session(ChatMessage message) => ChatSession(
  id: 'session',
  characterId: 'character',
  sessionIndex: 0,
  messages: [message],
);

ChatMessage _assistant(
  String content, {
  required int swipeId,
  required int agentSwipeId,
}) => ChatMessage(
  id: 'assistant',
  role: 'assistant',
  content: content,
  swipeId: swipeId,
  agentSwipeId: agentSwipeId,
);
