import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);

/// A full regeneration and a variation switch both restamp the message they
/// touch: the chat list sorts sessions on the last message's timestamp, so
/// without this a regenerated chat stayed buried. The message must not move
/// inside the chat — only the stamp changes.
void main() {
  test('full regen restamps the message it replaces', () {
    const writer = SavedMessageWriter();
    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        const ChatMessage(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
        const ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'old',
          timestamp: 2,
          swipes: ['old'],
        ),
      ],
    );

    final state = writer.writeAssistant(
      text: 'new',
      reasoning: null,
      currentSession: session,
      isAborted: () => false,
      previousSwipes: const ['old'],
      previousSwipeId: 0,
      regenTargetId: 'a1',
    );

    final messages = state.session!.messages;
    expect(messages.map((m) => m.id), ['u1', 'a1']);
    expect(messages.last.timestamp, greaterThan(2));
    expect(messages.first.timestamp, 1);
  });

  test('writeAssistant stamps the opening clock on the new variation', () {
    const writer = SavedMessageWriter();
    const clock = '01.01.2027 · RP_Day 0 · 09:00';
    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        const ChatMessage(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
      ],
    );

    final state = writer.writeAssistant(
      text: 'hello',
      reasoning: null,
      currentSession: session,
      isAborted: () => false,
      time: clock,
    );

    final message = state.session!.messages.last;
    expect(message.time, clock);
    expect(message.agentSwipes.single.time, clock);
    expect(message.swipesMeta.single['time'], clock);
  });

  test(
    'writeAssistant stamps the opening clock on a regenerated variation',
    () {
      const writer = SavedMessageWriter();
      const clock = '01.01.2027 · RP_Day 0 · 09:00';
      final session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: [
          const ChatMessage(
            id: 'u1',
            role: 'user',
            content: 'hi',
            timestamp: 1,
          ),
          const ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: 'old',
            timestamp: 2,
            time: '01.01.2027 · RP_Day 0 · 08:00',
            swipes: ['old'],
          ),
        ],
      );

      final state = writer.writeAssistant(
        text: 'new',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
        previousSwipes: const ['old'],
        previousSwipeId: 0,
        regenTargetId: 'a1',
        time: clock,
      );

      final message = state.session!.messages.last;
      expect(message.time, clock);
      expect(message.agentSwipes.single.time, clock);
      expect(message.swipesMeta.last['time'], clock);
    },
  );

  test('writeAssistant without a clock leaves the variation unstamped', () {
    const writer = SavedMessageWriter();
    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        const ChatMessage(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
      ],
    );

    final state = writer.writeAssistant(
      text: 'hello',
      reasoning: null,
      currentSession: session,
      isAborted: () => false,
    );

    final message = state.session!.messages.last;
    expect(message.time, isNull);
    expect(message.agentSwipes.single.time, isNull);
    expect(message.swipesMeta.single.containsKey('time'), isFalse);
  });

  test('switching variation restamps the message but keeps its slot', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        const ChatMessage(id: 'u1', role: 'user', content: 'hi', timestamp: 1),
        const ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'first',
          timestamp: 2,
          swipes: ['first', 'second'],
          swipeId: 0,
        ),
      ],
    );
    await container.read(chatRepoProvider).put(session);

    final updated = container
        .read(_messageServiceProvider)
        .setSwipe(session, 1, 1);

    expect(updated.messages.map((m) => m.id), ['u1', 'a1']);
    expect(updated.messages.last.content, 'second');
    expect(updated.messages.last.timestamp, greaterThan(2));
    expect(updated.messages.first.timestamp, 1);
  });

  test('switching green variations restores each game-time stamp', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final service = container.read(_messageServiceProvider);
    final session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'first',
          time: '12.05.2027 · RP_Day 2 · 14:12',
          swipes: const ['first', 'second'],
          swipeId: 0,
          swipesMeta: [
            <String, dynamic>{},
            <String, dynamic>{
              'time': '12.05.2027 · RP_Day 2 · 14:15',
              'agentSwipes': [
                const AgentSwipe(
                  content: 'second',
                  time: '12.05.2027 · RP_Day 2 · 14:15',
                ).toJson(),
              ],
            },
          ],
          agentSwipes: const [AgentSwipe(content: 'first')],
        ),
      ],
    );

    final second = service.setSwipe(session, 0, 1);
    expect(second.messages.single.time, contains('14:15'));

    final first = service.setSwipe(second, 0, 0);
    expect(first.messages.single.time, contains('14:12'));
  });

  test('switching nested variations restores each game-time stamp', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final service = container.read(_messageServiceProvider);
    const session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'first',
          time: '12.05.2027 · RP_Day 2 · 14:12',
          swipes: ['green'],
          agentSwipes: [
            AgentSwipe(content: 'first', time: '12.05.2027 · RP_Day 2 · 14:12'),
            AgentSwipe(
              content: 'second',
              kind: 'cleaned',
              time: '12.05.2027 · RP_Day 2 · 14:15',
            ),
          ],
        ),
      ],
    );

    final second = service.setAgentSwipe(session, 0, 1);
    expect(second.messages.single.time, contains('14:15'));

    final first = service.setAgentSwipe(second, 0, 0);
    expect(first.messages.single.time, contains('14:12'));
  });
}
