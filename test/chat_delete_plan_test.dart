import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);

ChatSession _session(int messageCount) => ChatSession(
  id: 's1',
  characterId: 'c1',
  sessionIndex: 0,
  messages: [
    for (var i = 0; i < messageCount; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'message $i',
      ),
  ],
);

void main() {
  test('planDeleteMessages shortens the session without a write', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final session = _session(5);
    await container.read(chatRepoProvider).put(session);

    final plan = container
        .read(_messageServiceProvider)
        .planDeleteMessages(session, {1, 3});

    expect(plan, isNotNull);
    expect(plan!.session.messages.map((m) => m.id), ['m0', 'm2', 'm4']);
    expect(plan.session.deletedMessageCount, 2);
    expect(plan.deletedIndices, unorderedEquals([1, 3]));
    expect(plan.earliestDeletedIndex, 1);
    // Everything from the earliest deletion on is causally invalidated.
    expect(
      plan.invalidatedMessageIds,
      unorderedEquals(['m1', 'm2', 'm3', 'm4']),
    );

    // Planning is pure: the row on disk is untouched until the commit runs.
    final persisted = await container.read(chatRepoProvider).getById('s1');
    expect(persisted?.messages.map((m) => m.id), [
      'm0',
      'm1',
      'm2',
      'm3',
      'm4',
    ]);
  });

  test('planDeleteMessages returns null when nothing is in range', () {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final service = container.read(_messageServiceProvider);
    expect(service.planDeleteMessages(_session(3), const <int>{}), isNull);
    expect(service.planDeleteMessages(_session(3), const {7, -1}), isNull);
  });

  test('commitDeleteMessages persists exactly the planned session', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final session = _session(5);
    await container.read(chatRepoProvider).put(session);

    final service = container.read(_messageServiceProvider);
    final plan = service.planDeleteMessages(session, {1, 3})!;
    final committed = await service.commitDeleteMessages(session, plan);

    expect(identical(committed, plan.session), isTrue);
    final persisted = await container.read(chatRepoProvider).getById('s1');
    expect(persisted?.messages.map((m) => m.id), ['m0', 'm2', 'm4']);
    expect(persisted?.deletedMessageCount, 2);
  });
}
