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

  tearDown(() => db.close());

  test(
    'all-session metadata is projected without changing its values',
    () async {
      await repo.put(
        const ChatSession(
          id: 'session',
          characterId: 'character',
          sessionIndex: 3,
          updatedAt: 42,
          sessionVars: {'sessionName': 'Branch', 'branchedAt': '3000'},
          messages: [
            ChatMessage(
              id: 'first',
              role: 'user',
              content: 'First',
              timestamp: 1000,
            ),
            ChatMessage(
              id: 'last',
              role: 'assistant',
              content: 'Last',
              timestamp: 2000,
            ),
          ],
        ),
      );

      final metadata = (await repo.getAllSessionMetadata()).single;

      expect(metadata.sessionId, 'session');
      expect(metadata.characterId, 'character');
      expect(metadata.sessionIndex, 3);
      expect(metadata.updatedAt, 42);
      expect(metadata.messageCount, 2);
      expect(metadata.lastMessageContent, 'Last');
      expect(metadata.lastMessageTimestamp, 2000);
      expect(metadata.sessionName, 'Branch');
      expect(metadata.originTimestamp, 3000);
      expect(metadata.originKind, 'branched');
    },
  );

  // The chat-list row truncates from the front, so a message a Continue run
  // extended would keep previewing the opening the user already read
  // (INV-CM7). Both projections have to slice at the boundary — the
  // json_extract one behind getAllSessionMetadata and the string-scanning one
  // behind getMetadataByCharacterId — or the list goes stale on exactly the
  // messages that just changed.
  group('a continued message previews its continuation', () {
    const continued = ChatSession(
      id: 'session',
      characterId: 'character',
      sessionIndex: 0,
      updatedAt: 42,
      messages: [
        ChatMessage(id: 'u', role: 'user', content: 'Go on', timestamp: 1000),
        ChatMessage(
          id: 'a',
          role: 'assistant',
          content: 'The opening line.\n\nThe continuation.',
          continuationOffset: 19,
          timestamp: 2000,
        ),
      ],
    );

    test('in the json_extract projection', () async {
      await repo.put(continued);
      final metadata = (await repo.getAllSessionMetadata()).single;
      expect(metadata.lastMessageContent, 'The continuation.');
    });

    test('in the string-scanning projection', () async {
      await repo.put(continued);
      final metadata = await repo.getMetadataByCharacterId('character');
      expect(metadata.single.lastMessageContent, 'The continuation.');
    });

    test('a message that was never continued is previewed whole', () async {
      await repo.put(
        const ChatSession(
          id: 'plain',
          characterId: 'character',
          sessionIndex: 1,
          updatedAt: 42,
          messages: [
            ChatMessage(
              id: 'a',
              role: 'assistant',
              content: 'The opening line.\n\nThe continuation.',
              timestamp: 2000,
            ),
          ],
        ),
      );

      final metadata = (await repo.getAllSessionMetadata()).single;
      expect(
        metadata.lastMessageContent,
        'The opening line.\n\nThe continuation.',
      );
    });
  });
}
