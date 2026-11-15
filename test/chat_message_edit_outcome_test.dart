import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_message_ops_controller.dart';
import 'package:glaze_flutter/features/chat/state/chat_session_write_queue.dart';

/// Saving an edit says what became of it. A refusal that returned quietly
/// closed the editor over the old text, and the reader could not tell a lost
/// edit from a saved one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const session = ChatSession(
    id: 'session',
    characterId: 'char',
    sessionIndex: 0,
    messages: [
      ChatMessage(id: 'm1', role: 'user', content: 'Hello'),
      ChatMessage(
        id: 'm2',
        role: 'assistant',
        content: 'Reply',
        reasoning: 'Thought',
      ),
    ],
  );

  late AppDatabase db;
  late ProviderContainer container;
  late AsyncValue<ChatState> state;
  late List<ChatSession> published;
  late Provider<ChatMessageOpsController> controllerProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    await container.read(chatRepoProvider).put(session);
    state = const AsyncData(ChatState(session: session));
    published = [];
    controllerProvider = Provider(
      (ref) => ChatMessageOpsController(
        ref: ref,
        charId: 'char',
        setState: (next) {
          state = next;
          final session = next.value?.session;
          if (session != null) published.add(session);
        },
        getState: () => state,
        invalidateHistory: () {},
        writes: ChatSessionWriteQueue(),
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  ChatMessageOpsController controller() => container.read(controllerProvider);

  Future<ChatSession> stored() async =>
      (await container.read(chatRepoProvider).getById('session'))!;

  test('a saved edit lands in the chat and says so', () async {
    final outcome = await controller().editMessage(0, 'Hello there');

    expect(outcome, MessageEditOutcome.saved);
    expect((await stored()).messages.first.content, 'Hello there');
    expect(published.last.messages.first.content, 'Hello there');
  });

  test('think tags set the reasoning apart from the text', () async {
    final outcome = await controller().editMessage(
      1,
      '<think>\nNew thought\n</think>\nNew reply',
      tagStart: '<think>',
      tagEnd: '</think>',
    );

    expect(outcome, MessageEditOutcome.saved);
    final message = (await stored()).messages[1];
    expect(message.content, 'New reply');
    expect(message.reasoning, 'New thought');
  });

  test('the text the message already has is nothing to save', () async {
    final outcome = await controller().editMessage(0, 'Hello');

    expect(outcome, MessageEditOutcome.unchanged);
    expect(published, isEmpty);
  });

  test('an edit is refused, and says busy, while the chat works', () async {
    for (final busy in [
      const ChatState(session: session, isGenerating: true),
      const ChatState(session: session, isGeneratingImage: true),
      const ChatState(session: session, isPostGenRunning: true),
    ]) {
      state = AsyncData(busy);

      final outcome = await controller().editMessage(0, 'Hello there');

      expect(outcome, MessageEditOutcome.busy);
    }
    expect((await stored()).messages.first.content, 'Hello');
    expect(published, isEmpty);
  });

  test('a message past the end of the chat is gone', () async {
    expect(
      await controller().editMessage(5, 'Hello there'),
      MessageEditOutcome.gone,
    );
  });

  test('a message deleted under the editor is gone', () async {
    await container
        .read(chatRepoProvider)
        .mutateMessages(
          sessionId: 'session',
          updatedAt: 10,
          mutate: (messages) => messages..removeAt(0),
        );

    final outcome = await controller().editMessage(0, 'Hello there');

    expect(outcome, MessageEditOutcome.gone);
    expect((await stored()).messages.map((m) => m.id), ['m2']);
    expect(published, isEmpty);
  });
}
