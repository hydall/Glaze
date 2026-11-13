import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

/// A chat is one JSON blob. A long one used to be decoded and encoded whole
/// on the UI isolate on every read and write, and the chat list re-scanned
/// every blob in the table after any write; the freezes that made are gone
/// without a change to what is stored or shown.
void main() {
  late AppDatabase db;
  late ChatRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ChatRepo(db);
  });

  tearDown(() => db.close());

  /// Long enough to be encoded in slices, with the nested fields a real
  /// roleplay carries.
  List<ChatMessage> longChat(int count) => [
    for (var i = 0; i < count; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message $i: "quoted", back\\slash, new\nline, émoji 🎭.',
        timestamp: 1000 + i,
        swipes: i.isOdd ? ['Swipe A $i', 'Swipe B $i'] : const [],
        swipeId: i.isOdd ? 1 : 0,
        swipesMeta: i.isOdd
            ? [
                {'tokens': 12, 'genTime': '1.2s'},
                {
                  'tokens': 13,
                  'triggeredMemories': [
                    {'id': 'mem$i', 'name': 'A fact about $i'},
                  ],
                },
              ]
            : const [],
        tokens: 10 + i,
        isHidden: i % 7 == 0,
      ),
  ];

  ChatSession session(List<ChatMessage> messages, {int index = 0}) =>
      ChatSession(
        id: 'char_$index',
        characterId: 'char',
        sessionIndex: index,
        updatedAt: 42 + index,
        sessionVars: const {'sessionName': 'Long'},
        messages: messages,
      );

  test(
    'a long chat survives the sliced write and the off-thread read',
    () async {
      final messages = longChat(130);
      await repo.put(session(messages));

      final back = await repo.getById('char_0');

      expect(back, isNotNull);
      expect(back!.messages.length, 130);
      expect(back.messages, messages);
      expect(back.sessionVars, {'sessionName': 'Long'});
      expect(back.updatedAt, 42);
    },
  );

  test('a message mutation returns what was written, without decoding it '
      'again', () async {
    await repo.put(session(longChat(60)));

    final updated = await repo.mutateMessage(
      sessionId: 'char_0',
      messageId: 'm3',
      updatedAt: 99,
      mutate: (m) => m.copyWith(content: 'Edited.'),
    );

    expect(updated, isNotNull);
    expect(updated!.updatedAt, 99);
    expect(updated.messages[3].content, 'Edited.');
    expect(updated.messages.length, 60);
    final stored = await repo.getById('char_0');
    expect(stored!.messages, updated.messages);
    expect(stored.updatedAt, 99);
  });

  test('the chat list is projected in SQL and follows writes', () async {
    await repo.put(session(longChat(5)));
    await repo.put(session(longChat(3), index: 1));

    final emitted = <List<SessionMetadata>>[];
    final sub = repo.watchAllSessionMetadata().listen(emitted.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(emitted, hasLength(1));
    // Newest first, as the list shows them.
    expect(emitted.single.map((m) => m.sessionId), ['char_1', 'char_0']);
    expect(emitted.single.last.messageCount, 5);
    expect(emitted.single.last.lastMessageContent, startsWith('Message 4:'));
    expect(emitted.single.last.lastMessageTimestamp, 1004);
    expect(emitted.single.last.originTimestamp, 1000);
    expect(emitted.single.last.sessionName, 'Long');

    await repo.mutateMessages(
      sessionId: 'char_0',
      updatedAt: 100,
      mutate: (messages) => [
        ...messages,
        const ChatMessage(
          id: 'new',
          role: 'user',
          content: 'One more',
          timestamp: 2000,
        ),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(emitted, hasLength(2));
    expect(emitted.last.first.sessionId, 'char_0');
    expect(emitted.last.first.messageCount, 6);
    expect(emitted.last.first.lastMessageContent, 'One more');
  });

  test(
    "a character's sessions are listed by index without their messages",
    () async {
      await repo.put(session(longChat(2), index: 2));
      await repo.put(session(longChat(4), index: 0));

      final meta = await repo.getMetadataByCharacterId('char');

      expect(meta.map((m) => m.sessionIndex), [0, 2]);
      expect(meta.first.messageCount, 4);
      expect(meta.first.lastMessageContent, startsWith('Message 3:'));
    },
  );

  test('a draft lands only while the message count still matches', () async {
    await repo.put(session(longChat(4)));

    expect(
      await repo.updateDraftIfMessageCount(
        sessionId: 'char_0',
        draft: 'typing…',
        expectedMessageCount: 4,
      ),
      'typing…',
    );
    expect((await repo.getById('char_0'))!.draft, 'typing…');
    expect(
      await repo.updateDraftIfMessageCount(
        sessionId: 'char_0',
        draft: 'stale',
        expectedMessageCount: 3,
      ),
      isNull,
    );
    expect((await repo.getById('char_0'))!.draft, 'typing…');
  });
}
