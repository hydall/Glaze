import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
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
    mutateSession: (_, _) async => null,
    loadSession: (_) async => null,
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

class _ResolverHarness {
  _ResolverHarness(Ref ref, ChatState initial) : state = AsyncData(initial) {
    final abortHandler = AbortHandler(
      ref: ref,
      charId: 'c1',
      setState: (next) {
        state = next;
        publications++;
      },
      getState: () => state,
      mutateSession: (_, _) async => null,
      loadSession: (_) async => null,
    );
    resolver = RegenResolver(
      StageContext(
        ref: ref,
        charId: 'c1',
        abortHandler: abortHandler,
        setState: (next) {
          state = next;
          publications++;
        },
        getState: () => state,
      ),
    );
  }

  late final RegenResolver resolver;
  AsyncValue<ChatState> state;
  int publications = 0;
}

final _harnessProvider = Provider.family<_ResolverHarness, ChatState>(
  _ResolverHarness.new,
);

class _ControlledChatRepo extends ChatRepo {
  _ControlledChatRepo(
    super.db,
    this.durableSession,
    this.gate, {
    this.fail = false,
  });

  ChatSession durableSession;
  final Completer<void> gate;
  final bool fail;

  @override
  Future<ChatSession?> mutateSession({
    required String sessionId,
    required ChatSession? Function(ChatSession session) mutate,
    int? updatedAt,
  }) async {
    await gate.future;
    if (fail) throw StateError('write failed');
    final updated = mutate(durableSession);
    if (updated != null) durableSession = updated;
    return updated;
  }

  @override
  Future<ChatSession?> getById(String sessionId) async => durableSession;
}

void main() {
  test('matching regenerate error settles the streaming flag', () async {
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

    final resolver = container.read(_resolverProvider)
      ..ctx.abortHandler.nextGenId();
    final outcome = await resolver.resolve(
      result: const ChatState(
        session: session,
        isGenerating: true,
        regenTargetId: 'm1',
      ),
      regenTargetId: 'm1',
      saveSession: null,
      session: session,
      genId: 1,
    );

    expect(outcome, isNotNull);
    expect(outcome!.state.isGenerating, isFalse);
    expect(outcome.state.regenTargetId, isNull);
  });

  test(
    'rolling back a cancelled regen keeps the error variation errored',
    () async {
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
      await container.read(chatRepoProvider).put(session);

      final resolver = container.read(_resolverProvider);
      final genId = resolver.ctx.abortHandler.nextGenId();
      resolver.ctx.abortHandler.restorationMessage = errored;

      // The result carries no regenTargetId — the run was cancelled — so the
      // resolver takes the rollback branch and puts the snapshot back.
      final outcome = await resolver.resolve(
        result: const ChatState(session: session),
        regenTargetId: 'm1',
        saveSession: session,
        session: session,
        genId: genId,
      );

      expect(outcome, isNotNull);
      final restored = outcome!.state.session!.messages.single;
      expect(restored.isError, isTrue);
      expect(restored.content, 'Request failed');
    },
  );

  test('rollback conflict publishes newer durable session unchanged', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    const original = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'original',
    );
    const generated = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'generated',
    );
    const newer = ChatMessage(id: 'm1', role: 'assistant', content: 'newer');
    const base = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      draft: 'old',
      sessionVars: {'base': 'value'},
      messages: [original],
    );
    const durable = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      draft: 'new draft',
      sessionVars: {'base': 'value', 'new': 'keep'},
      messages: [
        newer,
        ChatMessage(id: 'm2', role: 'user', content: 'tail'),
      ],
    );
    await container.read(chatRepoProvider).put(durable);

    final resolver = container.read(_resolverProvider);
    final genId = resolver.ctx.abortHandler.nextGenId();
    resolver.ctx.abortHandler.restorationMessage = original;
    final outcome = await resolver.resolve(
      result: const ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          messages: [generated],
        ),
      ),
      regenTargetId: 'm1',
      saveSession: base,
      session: base,
      genId: genId,
    );

    expect(outcome?.state.session?.draft, 'new draft');
    expect(outcome?.state.session?.sessionVars['new'], 'keep');
    expect(outcome?.state.session?.messages.map((message) => message.id), [
      'm1',
      'm2',
    ]);
    expect(outcome?.state.session?.messages.first.content, 'newer');
  });

  test(
    'rollback publishes only after persistence failure reload settles',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final gate = Completer<void>();
      const original = ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'original',
      );
      const generated = ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'generated',
      );
      const durable = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        draft: 'newer draft',
        messages: [generated],
      );
      final repo = _ControlledChatRepo(db, durable, gate, fail: true);
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          chatRepoProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      const initial = ChatState(session: durable, isGenerating: true);
      final harness = container.read(_harnessProvider(initial));
      final genId = harness.resolver.ctx.abortHandler.nextGenId();
      harness.resolver.ctx.abortHandler.restorationMessage = original;

      final pending = harness.resolver.resolve(
        result: initial,
        regenTargetId: 'm1',
        saveSession: const ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          messages: [original],
        ),
        session: durable,
        genId: genId,
      );
      await Future<void>.delayed(Duration.zero);

      expect(harness.publications, 0);
      expect(harness.state.requireValue.isGenerating, isTrue);

      gate.complete();
      final outcome = await pending;

      expect(outcome?.state.isGenerating, isFalse);
      expect(outcome?.state.session?.draft, 'newer draft');
      expect(outcome?.state.session?.messages.single.content, 'generated');
    },
  );

  test('stale rollback completion does not publish state', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final gate = Completer<void>();
    const original = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'original',
    );
    const generated = ChatMessage(
      id: 'm1',
      role: 'assistant',
      content: 'generated',
    );
    const durable = ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: [generated],
    );
    final repo = _ControlledChatRepo(db, durable, gate);
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        chatRepoProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    const initial = ChatState(session: durable, isGenerating: true);
    final harness = container.read(_harnessProvider(initial));
    final genId = harness.resolver.ctx.abortHandler.nextGenId();
    harness.resolver.ctx.abortHandler.restorationMessage = original;

    final pending = harness.resolver.resolve(
      result: initial,
      regenTargetId: 'm1',
      saveSession: const ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        messages: [original],
      ),
      session: durable,
      genId: genId,
    );
    await Future<void>.delayed(Duration.zero);
    harness.resolver.ctx.abortHandler.nextGenId();
    gate.complete();

    expect(await pending, isNull);
    expect(harness.publications, 0);
    expect(harness.state.requireValue.isGenerating, isTrue);
  });
}
