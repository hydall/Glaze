import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/image_gen_processor.dart';

void main() {
  late AppDatabase db;
  late ChatRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ChatRepo(db);
  });
  tearDown(() async => db.close());

  test('message mutation preserves a concurrently persisted draft', () async {
    await repo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        draft: 'old draft',
        messages: [ChatMessage(id: 'm1', role: 'user', content: 'before')],
      ),
    );
    await repo.updateDraftIfMessageCount(
      sessionId: 'session',
      draft: 'new draft',
      expectedMessageCount: 1,
    );

    final durable = await repo.mutateMessages(
      sessionId: 'session',
      updatedAt: 10,
      mutate: (messages) {
        messages[0] = messages[0].copyWith(content: 'after');
        return messages;
      },
    );

    expect(durable?.draft, 'new draft');
    expect(durable?.messages.single.content, 'after');
  });

  test('message mutation preserves a newer durable tail', () async {
    await repo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [ChatMessage(id: 'm1', role: 'user', content: 'first')],
      ),
    );
    await repo.appendUserMessageAndClearDraft(
      sessionId: 'session',
      message: const ChatMessage(id: 'm2', role: 'user', content: 'tail'),
      updatedAt: 11,
    );

    final durable = await repo.mutateMessages(
      sessionId: 'session',
      updatedAt: 12,
      mutate: (messages) {
        final index = messages.indexWhere((message) => message.id == 'm1');
        messages[index] = messages[index].copyWith(isHidden: true);
        return messages;
      },
    );

    expect(durable?.messages.map((message) => message.id), ['m1', 'm2']);
    expect(durable?.messages.first.isHidden, isTrue);
    expect(durable?.messages.last.content, 'tail');
  });

  test('image update by message ID preserves newer session fields', () async {
    await repo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(
            id: 'image',
            role: 'assistant',
            content: '[IMG:GEN]',
            swipes: ['[IMG:GEN]'],
          ),
        ],
      ),
    );
    await repo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        draft: 'new draft',
        sessionVars: {'concurrent': 'keep'},
        messages: [
          ChatMessage(
            id: 'image',
            role: 'assistant',
            content: '[IMG:GEN]',
            swipes: ['[IMG:GEN]'],
          ),
          ChatMessage(id: 'tail', role: 'user', content: 'newer tail'),
        ],
      ),
    );

    final durable = await repo.mutateMessage(
      sessionId: 'session',
      messageId: 'image',
      updatedAt: 12,
      mutate: (message) => ImageGenProcessor.replaceActiveImageContent(
        message,
        '[IMG:RESULT:/new.png]',
      ),
    );

    expect(durable?.messages.map((message) => message.id), ['image', 'tail']);
    expect(durable?.messages.first.content, '[IMG:RESULT:/new.png]');
    expect(durable?.draft, 'new draft');
    expect(durable?.sessionVars, {'concurrent': 'keep'});
  });

  test('image update preserves a newer swipe topology', () async {
    await repo.put(
      const ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(
            id: 'image',
            role: 'assistant',
            content: 'new active',
            swipes: ['[IMG:GEN]', 'new active'],
            swipeId: 1,
          ),
        ],
      ),
    );

    final durable = await repo.mutateMessage(
      sessionId: 'session',
      messageId: 'image',
      updatedAt: 12,
      mutate: (message) => ImageGenProcessor.replaceImageContentAt(
        message,
        '[IMG:RESULT:/new.png]',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );

    final message = durable!.messages.single;
    expect(message.swipes, ['[IMG:RESULT:/new.png]', 'new active']);
    expect(message.swipeId, 1);
    expect(message.content, 'new active');
  });

  test('image update does not copy the active clock to an inactive swipe', () {
    const message = ChatMessage(
      id: 'image',
      role: 'assistant',
      content: 'active',
      swipes: ['[IMG:GEN]', 'active'],
      swipesMeta: [
        {'time': '01.01.2026 · RP_Day 0 · 14:12'},
        {'time': '01.01.2026 · RP_Day 0 · 14:15'},
      ],
      swipeId: 1,
      time: '01.01.2026 · RP_Day 0 · 14:15',
    );

    final updated = ImageGenProcessor.replaceImageContentAt(
      message,
      '[IMG:RESULT:/new.png]',
      swipeId: 0,
      agentSwipeId: 0,
    );

    final stored = updated.swipesMeta.first['agentSwipes'] as List<dynamic>;
    expect(
      AgentSwipe.fromJson(
        Map<String, dynamic>.from(stored.single as Map<dynamic, dynamic>),
      ).time,
      '01.01.2026 · RP_Day 0 · 14:12',
    );
    expect(updated.time, '01.01.2026 · RP_Day 0 · 14:15');
  });

  test(
    'author note mutation preserves concurrent draft and messages',
    () async {
      await repo.put(
        const ChatSession(
          id: 'session',
          characterId: 'character',
          sessionIndex: 0,
          authorsNote: AuthorsNote(content: 'old'),
          messages: [ChatMessage(id: 'm1', role: 'user', content: 'first')],
        ),
      );
      await repo.updateDraftIfMessageCount(
        sessionId: 'session',
        draft: 'concurrent draft',
        expectedMessageCount: 1,
      );
      await repo.appendUserMessageAndClearDraft(
        sessionId: 'session',
        message: const ChatMessage(id: 'm2', role: 'user', content: 'tail'),
        updatedAt: 9,
      );
      await repo.updateDraftIfMessageCount(
        sessionId: 'session',
        draft: 'latest draft',
        expectedMessageCount: 2,
      );

      final durable = await repo.mutateAuthorsNote(
        sessionId: 'session',
        updatedAt: 10,
        mutate: (note) => note?.copyWith(content: 'new'),
      );

      expect(durable?.authorsNote?.content, 'new');
      expect(durable?.messages.map((message) => message.id), ['m1', 'm2']);
      expect(durable?.draft, 'latest draft');
    },
  );

  test('session var delta preserves concurrent keys', () {
    final merged = ChatRepo.applySessionVarDelta(
      {'unchanged': 'latest', 'concurrent': 'keep', 'removed': 'old'},
      {'unchanged': 'old', 'removed': 'old'},
      {'unchanged': 'generated', 'added': 'new'},
    );

    expect(merged, {
      'unchanged': 'generated',
      'concurrent': 'keep',
      'added': 'new',
    });
  });
}
