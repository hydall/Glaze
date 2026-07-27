import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/regen_resolver.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';

final _resolverProvider = Provider<RegenResolver>((ref) {
  late AsyncValue<ChatState> state = const AsyncData(ChatState());
  final abortHandler = AbortHandler(
    ref: ref,
    charId: 'c1',
    setState: (next) => state = next,
    getState: () => state,
    persistSession: (_) {},
  );
  return RegenResolver(
    StageContext(
      ref: ref,
      charId: 'c1',
      abortHandler: abortHandler,
      setState: (next) => state = next,
      getState: () => state,
    ),
  );
});

void main() {
  test('matching regenerate error settles the streaming flag', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      sessionVars: {},
      messages: [
        ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: 'Request failed',
          timestamp: 1,
          isError: true,
        ),
      ],
    );

    final outcome = container
        .read(_resolverProvider)
        .resolve(
          result: const ChatState(
            session: session,
            isGenerating: true,
            regenTargetId: 'm1',
          ),
          regenTargetId: 'm1',
          saveSession: null,
          session: session,
        );

    expect(outcome, isNotNull);
    expect(outcome!.state.isGenerating, isFalse);
    expect(outcome.state.regenTargetId, isNull);
  });

  test('rolling back a cancelled regen keeps the error variation errored', () {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    const errored = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'Request failed',
      timestamp: 1,
      isError: true,
      swipes: ['Request failed'],
      swipesMeta: [
        {'isError': true},
      ],
    );
    const session = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      sessionVars: {},
      messages: [errored],
    );

    final resolver = container.read(_resolverProvider);
    resolver.ctx.abortHandler.restorationMessage = errored;

    // The result carries no regenTargetId — the run was cancelled — so the
    // resolver takes the rollback branch and puts the snapshot back.
    final outcome = resolver.resolve(
      result: const ChatState(session: session),
      regenTargetId: 'm1',
      saveSession: session,
      session: session,
    );

    expect(outcome, isNotNull);
    final restored = outcome!.state.session!.messages.single;
    expect(restored.isError, isTrue);
    expect(restored.content, 'Request failed');
  });
}
