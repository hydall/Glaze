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
}
