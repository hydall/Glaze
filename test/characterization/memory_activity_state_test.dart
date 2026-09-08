import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';
import 'package:glaze_flutter/features/chat/state/memory_activity_provider.dart';

void main() {
  group('Memory activity ephemeral state', () {
    test('writeAssistant strips diagnostics from persisted memoryCoverage', () {
      const writer = SavedMessageWriter();
      const session = ChatSession(id: 's1', characterId: 'c1', sessionIndex: 0);

      final state = writer.writeAssistant(
        text: 'Generated response',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
        memoryCoverage: {
          'entryIds': ['m1'],
          'budgetTokens': 1000,
          'diagnostics': {
            'selectedEntryIds': ['m1'],
            'candidates': [
              {'entryId': 'm1', 'reason': 'selected'},
            ],
          },
        },
      );

      final message = state.session!.messages.single;
      expect(message.memoryCoverage['entryIds'], ['m1']);
      expect(message.memoryCoverage['budgetTokens'], 1000);
      expect(message.memoryCoverage.containsKey('diagnostics'), isFalse);
      expect(message.content, 'Generated response');
    });

    test(
      'regen path strips diagnostics from the replaced assistant message',
      () {
        const writer = SavedMessageWriter();
        final session = ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          messages: const [
            ChatMessage(id: 'a1', role: 'assistant', content: 'Old'),
          ],
        );

        final state = writer.writeAssistant(
          text: 'New swipe',
          reasoning: null,
          currentSession: session,
          isAborted: () => false,
          regenTargetId: 'a1',
          memoryCoverage: const {
            'entryIds': ['m1'],
            'diagnostics': {'selectedCount': 1},
          },
        );

        final message = state.session!.messages.single;
        expect(message.id, 'a1');
        expect(message.memoryCoverage['entryIds'], ['m1']);
        expect(message.memoryCoverage.containsKey('diagnostics'), isFalse);
      },
    );

    test('MemoryActivityState holds diagnostics outside chat messages', () {
      final activity = MemoryActivityState(
        sessionId: 's1',
        messageId: 'a1',
        diagnostics: const {
          'selectedCount': 1,
          'candidates': [
            {'entryId': 'm1', 'reason': 'selected'},
          ],
        },
        updatedAtMillis: 123,
      );

      expect(activity.hasDiagnostics, isTrue);
      expect(activity.sessionId, 's1');
      expect(activity.messageId, 'a1');
      expect(activity.diagnostics['selectedCount'], 1);
    });
  });
}
