// Regression test for the swipe-to-regenerate / stray-Regenerate-button bug:
// after swiping the last bot message and cancelling the new-variant
// generation, the swipe gesture stopped working and a Regenerate button
// appeared under the second-to-last user message.
//
// Root cause: `lastUserMessageId` returned the last *user* message even when
// a char message followed it. `setLastMessage` then moved `data-is-last` off
// the trailing char (blocking swipe-to-regen) and injected a Regenerate
// button under the non-trailing user message.
//
// The button must appear under a user message ONLY when that user message is
// genuinely the last message in the chat, mirroring the reference UI
// (`ChatMessage.vue`: `role === 'user' && isLast`).

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart' show ChatMessage;
import 'package:glaze_flutter/features/chat/widgets/chat_message_sync.dart';

ChatMessage _msg(String id, String role) =>
    ChatMessage(id: id, role: role, content: role, timestamp: 1);

void main() {
  group('lastUserMessageId', () {
    test('returns null on an empty list', () {
      expect(lastUserMessageId(const []), isNull);
    });

    test('returns the id when the trailing message is a user message', () {
      final msgs = [_msg('u1', 'user'), _msg('c1', 'assistant'), _msg('u2', 'user')];
      expect(lastUserMessageId(msgs), 'u2');
    });

    test('returns null when a char message is last (regression)', () {
      // user -> char: the user message is NOT the last message, so no
      // Regenerate button should be attributed to it.
      final msgs = [_msg('u1', 'user'), _msg('c1', 'assistant')];
      expect(lastUserMessageId(msgs), isNull);
    });

    test('treats "character" role as a non-user trailing message', () {
      final msgs = [_msg('u1', 'user'), _msg('c1', 'character')];
      expect(lastUserMessageId(msgs), isNull);
    });

    test('returns null for a char-only greeting chat', () {
      expect(lastUserMessageId([_msg('c1', 'assistant')]), isNull);
    });
  });
}
