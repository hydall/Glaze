import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/extensions/services/extension_post_gen_service.dart';

class _RecordingExtensionPostGenService extends ExtensionPostGenService {
  _RecordingExtensionPostGenService(super.ref);

  int cancelBlocksCalls = 0;

  @override
  void cancelBlocks() {
    cancelBlocksCalls++;
  }
}

class _AbortHarness {
  _AbortHarness(Ref ref, ChatState initialState, {this.mutationGate})
    : state = AsyncData(initialState),
      durableSession = initialState.session {
    handler = AbortHandler(
      ref: ref,
      charId: 'char-1',
      setState: (next) {
        state = next;
        final value = next.value;
        if (value != null) stateHistory.add(value);
      },
      getState: () => state,
      mutateSession: (sessionId, mutate) async {
        await mutationGate?.future;
        final current = durableSession;
        if (current == null || current.id != sessionId) return null;
        final updated = mutate(current);
        if (updated != null) {
          durableSession = updated;
          persistedSessions.add(updated);
        }
        return updated;
      },
      loadSession: (sessionId) async =>
          durableSession?.id == sessionId ? durableSession : null,
    );
  }

  late final AbortHandler handler;
  AsyncValue<ChatState> state;
  final List<ChatState> stateHistory = [];
  final List<ChatSession> persistedSessions = [];
  ChatSession? durableSession;
  final Completer<void>? mutationGate;
}

Provider<_AbortHarness> _abortHarnessProvider(
  ChatState initialState, {
  Completer<void>? mutationGate,
}) => Provider(
  (ref) => _AbortHarness(ref, initialState, mutationGate: mutationGate),
);

ChatSession _session(List<ChatMessage> messages) => ChatSession(
  id: 'session-1',
  characterId: 'char-1',
  sessionIndex: 0,
  messages: messages,
);

void _expectAllGenerationFlagsCleared(Iterable<ChatState> states) {
  expect(states, isNotEmpty);
  for (final state in states) {
    expect(state.isGenerating, isFalse);
    expect(state.isGeneratingImage, isFalse);
    expect(state.isPostGenRunning, isFalse);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Stop clears all generation flags after no-partial abort cleanup',
    () async {
      final initialState = ChatState(
        session: _session([
          const ChatMessage(id: 'user-1', role: 'user', content: 'Hello'),
        ]),
        isGeneratingImage: true,
        isPostGenRunning: true,
      );
      final harnessProvider = _abortHarnessProvider(initialState);
      final container = ProviderContainer(
        overrides: [
          extensionPostGenServiceProvider.overrideWith(
            (ref) => _RecordingExtensionPostGenService(ref),
          ),
        ],
      );
      addTearDown(container.dispose);
      final harness = container.read(harnessProvider);

      await harness.handler.abortGeneration();

      _expectAllGenerationFlagsCleared([harness.state.requireValue]);
      _expectAllGenerationFlagsCleared(harness.stateHistory);
      expect(harness.state.requireValue.session, same(initialState.session));
    },
  );

  test(
    'Stop keeps generation blocked until partial persistence settles',
    () async {
      final gate = Completer<void>();
      final initialState = ChatState(
        session: _session([
          const ChatMessage(id: 'user-1', role: 'user', content: 'Hello'),
        ]),
        isGenerating: true,
      );
      final harnessProvider = _abortHarnessProvider(
        initialState,
        mutationGate: gate,
      );
      final container = ProviderContainer(
        overrides: [
          extensionPostGenServiceProvider.overrideWith(
            (ref) => _RecordingExtensionPostGenService(ref),
          ),
        ],
      );
      addTearDown(container.dispose);
      final harness = container.read(harnessProvider);
      container.read(streamingStateProvider('char-1').notifier).state =
          const StreamingState(text: 'Partial');

      final abort = harness.handler.abortGeneration();
      await Future<void>.delayed(Duration.zero);

      expect(harness.state.requireValue.isGenerating, isTrue);
      expect(harness.persistedSessions, isEmpty);

      gate.complete();
      await abort;

      expect(harness.state.requireValue.isGenerating, isFalse);
      expect(harness.persistedSessions, hasLength(1));
      expect(harness.persistedSessions.single.messages.last.content, 'Partial');
    },
  );

  test(
    'partial regeneration starts a fresh untimed nested variation',
    () async {
      const restoration = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Original',
        swipes: ['Original'],
        swipesMeta: [
          {
            'time': '01.01.2026 · RP_Day 0 · 14:12',
            'agentSwipeId': 0,
            'agentSwipes': [
              {
                'content': 'Original',
                'kind': 'final',
                'time': '01.01.2026 · RP_Day 0 · 14:12',
              },
            ],
          },
        ],
        agentSwipes: [
          AgentSwipe(
            content: 'Original',
            time: '01.01.2026 · RP_Day 0 · 14:12',
          ),
        ],
        time: '01.01.2026 · RP_Day 0 · 14:12',
      );
      final initialState = ChatState(
        session: _session([restoration]),
        isGenerating: true,
        regenTargetId: restoration.id,
      );
      final harnessProvider = _abortHarnessProvider(initialState);
      final container = ProviderContainer(
        overrides: [
          extensionPostGenServiceProvider.overrideWith(
            (ref) => _RecordingExtensionPostGenService(ref),
          ),
        ],
      );
      addTearDown(container.dispose);
      final harness = container.read(harnessProvider);
      harness.handler.restorationMessage = restoration;
      container.read(streamingStateProvider('char-1').notifier).state =
          const StreamingState(text: 'Partial', reasoning: 'Reasoning');

      await harness.handler.abortGeneration();

      final message = harness.durableSession!.messages.single;
      expect(message.content, 'Partial');
      expect(message.time, isNull);
      expect(message.agentSwipeId, 0);
      expect(message.agentSwipes, hasLength(1));
      expect(message.agentSwipes.single.content, 'Partial');
      expect(message.agentSwipes.single.time, isNull);
      final stored = message.swipesMeta.last['agentSwipes'] as List<dynamic>;
      expect(
        AgentSwipe.fromJson(
          Map<String, dynamic>.from(stored.single as Map<dynamic, dynamic>),
        ).time,
        isNull,
      );
    },
  );

  test(
    'post-gen Stop restores the snapshot without re-enabling generation flags',
    () async {
      final initialState = ChatState(
        session: _session([
          const ChatMessage(id: 'user-1', role: 'user', content: 'Hello'),
        ]),
        isGeneratingImage: true,
        isPostGenRunning: true,
      );
      final harnessProvider = _abortHarnessProvider(initialState);
      final container = ProviderContainer(
        overrides: [
          extensionPostGenServiceProvider.overrideWith(
            (ref) => _RecordingExtensionPostGenService(ref),
          ),
        ],
      );
      addTearDown(container.dispose);
      final harness = container.read(harnessProvider);
      harness.handler.restorationMessage = const ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Restored response',
      );

      await harness.handler.abortGeneration();

      _expectAllGenerationFlagsCleared(harness.stateHistory);
      expect(
        harness.state.requireValue.session?.messages.map(
          (message) => message.id,
        ),
        ['user-1', 'assistant-1'],
      );
      expect(harness.persistedSessions, hasLength(1));
    },
  );

  test('main Stop cancels active extension post-generation blocks', () async {
    final harnessProvider = _abortHarnessProvider(
      const ChatState(isPostGenRunning: true),
    );
    final container = ProviderContainer(
      overrides: [
        extensionPostGenServiceProvider.overrideWith(
          (ref) => _RecordingExtensionPostGenService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    final harness = container.read(harnessProvider);
    final postGenService =
        container.read(extensionPostGenServiceProvider)
            as _RecordingExtensionPostGenService;

    await harness.handler.abortGeneration();

    expect(postGenService.cancelBlocksCalls, 1);
  });
}
