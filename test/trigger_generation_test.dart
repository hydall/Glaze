import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/editing_message_provider.dart';
import 'package:glaze_flutter/features/extensions/models/trigger_mode.dart';
import 'package:glaze_flutter/features/extensions/models/trigger_result.dart';
import 'package:glaze_flutter/features/extensions/services/generation_dispatcher.dart';
import 'package:glaze_flutter/features/extensions/services/trigger_generation_handler.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

ChatMessage _msg(String id, String role, String content) =>
    ChatMessage(id: id, role: role, content: content, timestamp: 0);

/// A no-op mock that lets the test drive the chat state directly without
/// running the real generation pipeline. We deliberately do not stub
/// `continueMessage` / `regenerateLastAssistant` because the tests
/// exercise the dispatcher's validation paths before that, but the
/// `auto` happy-path test does call through to those methods — we record
/// the call and return immediately.
class _MockChatNotifier extends ChatNotifier {
  _MockChatNotifier(this._initial, String charId) : super(charId);
  final ChatState _initial;
  final List<String> calls = [];

  @override
  Future<ChatState> build() async {
    state = AsyncData(_initial);
    return _initial;
  }

  @override
  Future<void> continueMessage() async {
    calls.add('continue');
  }

  @override
  Future<void> regenerateLastAssistant({String? guidanceText}) async {
    calls.add('regenerate');
  }
}

class _GuardedChatNotifier extends ChatNotifier {
  _GuardedChatNotifier(this._initial, String charId) : super(charId);

  final ChatState _initial;

  @override
  Future<ChatState> build() async => _initial;
}

ProviderContainer _container({
  required String charId,
  required ChatState initial,
  List<Override> extra = const [],
}) {
  return ProviderContainer(
    overrides: [
      chatProvider.overrideWith2(
        (charId) => _MockChatNotifier(initial, charId),
      ),
      ...extra,
    ],
  );
}

void main() {
  late AppDatabase db;
  late CharacterRepo characterRepo;
  late ChatRepo chatRepo;

  setUp(() async {
    db = _testDb();
    characterRepo = CharacterRepo(db);
    chatRepo = ChatRepo(db);
    await characterRepo.put(Character(id: 'c1', name: 'Alice'));
    await chatRepo.put(
      const ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        sessionVars: {},
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('TriggerMode.parse', () {
    test('parses known mode names', () {
      expect(TriggerMode.parse('continue'), TriggerMode.continueGeneration);
      expect(TriggerMode.parse('regenerate'), TriggerMode.regenerate);
      expect(TriggerMode.parse('auto'), TriggerMode.auto);
      expect(TriggerMode.parse('AUTO'), TriggerMode.auto);
    });

    test('falls back to auto for unknown values', () {
      expect(TriggerMode.parse(null), TriggerMode.auto);
      expect(TriggerMode.parse(''), TriggerMode.auto);
      expect(TriggerMode.parse('something-else'), TriggerMode.auto);
    });
  });

  group('GenerationDispatcher', () {
    test('rejects with TriggerNoSession when chat state is loading', () async {
      final container = ProviderContainer(
        overrides: [
          chatProvider.overrideWith2(
            (charId) => _MockChatNotifier(const ChatState(), charId),
          ),
        ],
      );
      addTearDown(container.dispose);

      final dispatcher = container.read(generationDispatcherProvider);
      final result = await dispatcher.dispatch(charId: 'c1', rawMode: 'auto');

      expect(result, isA<TriggerNoSession>());
      expect(result.accepted, isFalse);
    });

    test('rejects with TriggerBusy when chat is already generating', () async {
      final state = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [_msg('m1', 'user', 'Hi')],
        ),
        isGenerating: true,
      );
      final container = _container(charId: 'c1', initial: state);
      addTearDown(container.dispose);

      final dispatcher = container.read(generationDispatcherProvider);
      final result = await dispatcher.dispatch(charId: 'c1');

      expect(result, isA<TriggerBusy>());
      expect((result as TriggerBusy).busyKind, 'chat');
    });

    test('rejects with TriggerBusy when a memory draft is active', () async {
      final state = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [_msg('m1', 'user', 'Hi')],
        ),
      );
      final container = _container(charId: 'c1', initial: state);
      addTearDown(container.dispose);
      container.read(memoryActiveDraftsProvider.notifier).markActive('s1');

      final dispatcher = container.read(generationDispatcherProvider);
      final result = await dispatcher.dispatch(charId: 'c1');

      expect(result, isA<TriggerBusy>());
      expect((result as TriggerBusy).busyKind, 'memory_draft');
    });

    test('rejects with TriggerBusy while a message is being edited', () async {
      final state = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [_msg('m1', 'user', 'Hi')],
        ),
      );
      final container = _container(charId: 'c1', initial: state);
      addTearDown(container.dispose);
      container.read(editingMessageIdProvider('c1').notifier).state = 'm1';

      final dispatcher = container.read(generationDispatcherProvider);
      final result = await dispatcher.dispatch(charId: 'c1');

      expect(result, isA<TriggerBusy>());
      expect((result as TriggerBusy).busyKind, 'message_edit');
      expect(dispatcher.peekResolvedMode(charId: 'c1'), isNull);
      final notifier =
          container.read(chatProvider('c1').notifier) as _MockChatNotifier;
      expect(notifier.calls, isEmpty);
    });

    test('auto-resolves to continue when last message is assistant', () async {
      final state = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [
            _msg('m1', 'user', 'Hi'),
            _msg('m2', 'assistant', 'Hello there'),
          ],
        ),
      );
      final container = _container(charId: 'c1', initial: state);
      addTearDown(container.dispose);

      final dispatcher = container.read(generationDispatcherProvider);
      final result = await dispatcher.dispatch(charId: 'c1');

      expect(result, isA<TriggerAccepted>());
      expect((result as TriggerAccepted).mode, TriggerMode.continueGeneration);
      final notifier =
          container.read(chatProvider('c1').notifier) as _MockChatNotifier;
      expect(notifier.calls, ['continue']);
    });

    test('auto-resolves to regenerate when last message is user', () async {
      final state = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [_msg('m1', 'user', 'Hi')],
        ),
      );
      final container = _container(charId: 'c1', initial: state);
      addTearDown(container.dispose);

      final dispatcher = container.read(generationDispatcherProvider);
      final result = await dispatcher.dispatch(charId: 'c1', rawMode: 'auto');

      expect(result, isA<TriggerAccepted>());
      expect((result as TriggerAccepted).mode, TriggerMode.regenerate);
      final notifier =
          container.read(chatProvider('c1').notifier) as _MockChatNotifier;
      expect(notifier.calls, ['regenerate']);
    });

    test('explicit continue mode delegates to continueMessage', () async {
      final state = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [
            _msg('m1', 'user', 'Hi'),
            _msg('m2', 'assistant', 'Hello there'),
          ],
        ),
      );
      final container = _container(charId: 'c1', initial: state);
      addTearDown(container.dispose);

      final dispatcher = container.read(generationDispatcherProvider);
      final result = await dispatcher.dispatch(
        charId: 'c1',
        rawMode: 'continue',
        reason: 'tick',
      );

      expect(result, isA<TriggerAccepted>());
      final accepted = result as TriggerAccepted;
      expect(accepted.mode, TriggerMode.continueGeneration);
      expect(accepted.reason, 'tick');
      final notifier =
          container.read(chatProvider('c1').notifier) as _MockChatNotifier;
      expect(notifier.calls, ['continue']);
    });

    test(
      'explicit regenerate mode delegates to regenerateLastAssistant',
      () async {
        final state = ChatState(
          session: ChatSession(
            id: 's1',
            characterId: 'c1',
            sessionIndex: 0,
            sessionVars: const {},
            messages: [_msg('m1', 'user', 'Hi')],
          ),
        );
        final container = _container(charId: 'c1', initial: state);
        addTearDown(container.dispose);

        final dispatcher = container.read(generationDispatcherProvider);
        final result = await dispatcher.dispatch(
          charId: 'c1',
          rawMode: 'regenerate',
        );

        expect(result, isA<TriggerAccepted>());
        final notifier =
            container.read(chatProvider('c1').notifier) as _MockChatNotifier;
        expect(notifier.calls, ['regenerate']);
      },
    );

    test('peekResolvedMode reflects busy / no-session conditions', () async {
      final emptyContainer = ProviderContainer(
        overrides: [
          chatProvider.overrideWith2(
            (charId) => _MockChatNotifier(const ChatState(), charId),
          ),
        ],
      );
      addTearDown(emptyContainer.dispose);
      expect(
        emptyContainer
            .read(generationDispatcherProvider)
            .peekResolvedMode(charId: 'c1', rawMode: 'auto'),
        isNull,
      );

      final busyState = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [_msg('m1', 'user', 'Hi')],
        ),
        isGenerating: true,
      );
      final busyContainer = _container(charId: 'c1', initial: busyState);
      addTearDown(busyContainer.dispose);
      expect(
        busyContainer
            .read(generationDispatcherProvider)
            .peekResolvedMode(charId: 'c1', rawMode: 'auto'),
        isNull,
      );
    });
  });

  test(
    'ChatNotifier blocks every generation entry point during editing',
    () async {
      final initial = ChatState(
        session: ChatSession(
          id: 's1',
          characterId: 'c1',
          sessionIndex: 0,
          sessionVars: const {},
          messages: [_msg('m1', 'user', 'Hi')],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          chatProvider.overrideWith2(
            (charId) => _GuardedChatNotifier(initial, charId),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatProvider('c1').future);
      container.read(editingMessageIdProvider('c1').notifier).state = 'm1';
      final notifier = container.read(chatProvider('c1').notifier);

      await notifier.sendMessage('Blocked');
      await notifier.regenerateLastAssistant();
      await notifier.continueMessage();

      expect(container.read(chatProvider('c1')).value, same(initial));
    },
  );

  group('TriggerGenerationHandler', () {
    test('returns no_session map when charId is null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final handler = TriggerGenerationHandler(
        dispatcher: container.read(generationDispatcherProvider),
      );

      final result = await handler.handle(charId: null, params: const {});

      expect(result['accepted'], isFalse);
      expect(result['reason'], 'no_session');
    });

    test('rejects non-string mode with ArgumentError', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final handler = TriggerGenerationHandler(
        dispatcher: container.read(generationDispatcherProvider),
      );

      expect(
        () => handler.handle(charId: 'c1', params: {'mode': 42}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-string reason with ArgumentError', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final handler = TriggerGenerationHandler(
        dispatcher: container.read(generationDispatcherProvider),
      );

      expect(
        () =>
            handler.handle(charId: 'c1', params: {'mode': 'auto', 'reason': 7}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
