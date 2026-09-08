import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  late AppDatabase db;
  late ChatRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ChatRepo(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('delayed draft save cannot erase just-sent user message', () async {
    const session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'hello',
          timestamp: 1,
        ),
      ],
      draft: 'typed text',
    );
    await repo.put(session);

    final sent = await repo.appendUserMessageAndClearDraft(
      sessionId: 's1',
      message: const ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'typed text',
        timestamp: 2,
      ),
      updatedAt: 10,
    );

    expect(sent, isNotNull);
    expect(sent!.messages.map((m) => m.id), ['a1', 'u1']);
    expect(sent.draft, '');

    final staleDraftWrite = await repo.updateDraftIfMessageCount(
      sessionId: 's1',
      draft: 'typed text',
      expectedMessageCount: 1,
    );

    expect(staleDraftWrite, isNull);
    final persisted = await repo.getById('s1');
    expect(persisted, isNotNull);
    expect(persisted!.messages.map((m) => m.id), ['a1', 'u1']);
    expect(persisted.messages.last.content, 'typed text');
    expect(persisted.draft, '');
  });
}
