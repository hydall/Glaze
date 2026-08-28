import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_bridge_controller.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_overlay_blur_region.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_message_sync.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_streaming_bridge_sync.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_webview_sync_dispatcher.dart';

void main() {
  group('ChatMessageSync', () {
    test(
      'appends persisted user message while virtual placeholder exists',
      () async {
        final bridge = _FakeBridge();
        final greeting = _assistant('a1');
        final user = _user('u1');

        await const ChatMessageSync().sync(
          bridge: bridge,
          oldMsgs: [greeting],
          newMsgs: [greeting, user],
          visibleStartIndex: 0,
          isGenerating: true,
          sessionSwitching: false,
        );

        expect(bridge.appendedMessages, [user]);
      },
    );

    test('does not complete until persisted user append completes', () async {
      final appendCompleter = Completer<void>();
      final bridge = _FakeBridge()..appendMessagesCompleter = appendCompleter;
      final greeting = _assistant('a1');
      final user = _user('u1');
      var completed = false;

      final sync = const ChatMessageSync()
          .sync(
            bridge: bridge,
            oldMsgs: [greeting],
            newMsgs: [greeting, user],
            visibleStartIndex: 0,
            isGenerating: true,
            sessionSwitching: false,
          )
          .then((_) => completed = true);

      await Future<void>.delayed(Duration.zero);
      expect(bridge.appendedMessages, [user]);
      expect(completed, isFalse);

      appendCompleter.complete();
      await sync;
      expect(completed, isTrue);
    });

    test('sends a time-only metadata update to the WebView', () async {
      final bridge = _FakeBridge();
      final oldMessage = _assistant('a1');
      final updated = oldMessage.copyWith(
        time: '12.05.2027 · RP_Day 2 · 14:15',
      );

      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: [oldMessage],
        newMsgs: [updated],
        visibleStartIndex: 0,
        isGenerating: false,
        sessionSwitching: false,
      );

      expect(bridge.updatedMessages, [updated]);
      expect(bridge.appendedMessages, isEmpty);
    });

    test('appends streaming placeholder after persisted user append', () async {
      final userAppend = Completer<void>();
      final calls = <String>[];

      final result = appendStreamingPlaceholderAfterMessageSync(
        messageSync: () async {
          calls.add('user:start');
          await userAppend.future;
          calls.add('user:done');
        }(),
        isCurrent: () => true,
        appendPlaceholder: () async {
          calls.add('placeholder');
        },
      );

      await Future<void>.delayed(Duration.zero);
      expect(calls, ['user:start']);

      userAppend.complete();
      expect(await result, isTrue);
      expect(calls, ['user:start', 'user:done', 'placeholder']);
    });

    test('skips streaming placeholder when generation becomes stale', () async {
      final userAppend = Completer<void>();
      var current = true;
      var placeholderCalls = 0;

      final result = appendStreamingPlaceholderAfterMessageSync(
        messageSync: userAppend.future,
        isCurrent: () => current,
        appendPlaceholder: () async => placeholderCalls++,
      );

      current = false;
      userAppend.complete();

      expect(await result, isFalse);
      expect(placeholderCalls, 0);
    });

    test(
      'reports stale when generation stops during placeholder append',
      () async {
        final placeholderAppend = Completer<void>();
        var current = true;

        final result = appendStreamingPlaceholderAfterMessageSync(
          messageSync: Future<void>.value(),
          isCurrent: () => current,
          appendPlaceholder: () => placeholderAppend.future,
        );

        await Future<void>.delayed(Duration.zero);
        current = false;
        placeholderAppend.complete();

        expect(await result, isFalse);
      },
    );
  });

  group('ChatWebViewSyncDispatcher', () {
    test('serializes persisted and streaming message mutations', () async {
      final state = ChatWebViewSyncState();
      final firstMutation = Completer<void>();
      final calls = <String>[];

      final first = state.enqueueMessageMutation(() async {
        calls.add('user:start');
        await firstMutation.future;
        calls.add('user:done');
      });
      final second = state.enqueueMessageMutation(() async {
        calls.add('assistant');
      });

      await Future<void>.delayed(Duration.zero);
      expect(calls, ['user:start']);

      firstMutation.complete();
      await Future.wait([first, second]);
      expect(calls, ['user:start', 'user:done', 'assistant']);
      expect(state.messageMutationPending, isNull);
    });

    test('continues message mutation queue after a failed operation', () async {
      final state = ChatWebViewSyncState();
      final calls = <String>[];

      final failed = state.enqueueMessageMutation(() async {
        calls.add('failed');
        throw StateError('bridge failed');
      });
      final recovered = state.enqueueMessageMutation(() async {
        calls.add('recovered');
      });

      await expectLater(failed, throwsStateError);
      await recovered;
      expect(calls, ['failed', 'recovered']);
      expect(state.messageMutationPending, isNull);
    });

    test(
      'does not skip just-sent user message after stale streaming flag',
      () async {
        final syncState = ChatWebViewSyncState()
          ..wasGenerating = false
          ..streamingSent = true;
        final dispatcher = ChatWebViewSyncDispatcher(state: syncState);

        final result = dispatcher.dispatch(
          bridge: _FakeBridge(),
          old: _fields(isGenerating: false, messages: [_assistant('a1')]),
          current: _fields(
            isGenerating: true,
            messages: [_assistant('a1'), _user('u1')],
          ),
          oldMessages: [_assistant('a1')],
          newMessages: [_assistant('a1'), _user('u1')],
          streamingId: '__streaming__',
          onSyncExtBlockPanels: () async {},
          appendMessage: (_) async {},
          buildStreamingPlaceholder: () => _assistant('__streaming__'),
        );

        expect(result.runMessageSync, isTrue);
        expect(result.appendPlaceholder, isTrue);
        expect(syncState.streamingSent, isFalse);
      },
    );

    test('pushes the search as soon as the query changes', () {
      final bridge = _FakeBridge();
      final dispatcher = ChatWebViewSyncDispatcher(
        state: ChatWebViewSyncState(),
      );

      final result = dispatcher.dispatch(
        bridge: bridge,
        old: _fields(isGenerating: false, messages: const []),
        current: _fields(
          isGenerating: false,
          messages: const [],
          searchQuery: 'foo',
          searchCurrentIndex: 0,
        ),
        oldMessages: const [],
        newMessages: const [],
        streamingId: '__streaming__',
        onSyncExtBlockPanels: () async {},
        appendMessage: (_) async {},
        buildStreamingPlaceholder: () => _assistant('__streaming__'),
      );

      expect(bridge.searchCalls, [('foo', 0, true)]);
      expect(result.rehighlightSearch, isFalse);
    });

    test('defers the highlight pass when the messages changed under a '
        'search', () {
      final bridge = _FakeBridge();
      final dispatcher = ChatWebViewSyncDispatcher(
        state: ChatWebViewSyncState(),
      );
      final edited = _assistant('a1').copyWith(content: 'edited');

      final result = dispatcher.dispatch(
        bridge: bridge,
        old: _fields(
          isGenerating: false,
          messages: [_assistant('a1')],
          searchQuery: 'foo',
          searchCurrentIndex: 0,
        ),
        current: _fields(
          isGenerating: false,
          messages: [edited],
          searchQuery: 'foo',
          searchCurrentIndex: 0,
          searchRevision: 1,
        ),
        oldMessages: [_assistant('a1')],
        newMessages: [edited],
        streamingId: '__streaming__',
        onSyncExtBlockPanels: () async {},
        appendMessage: (_) async {},
        buildStreamingPlaceholder: () => _assistant('__streaming__'),
      );

      // Highlighting now would number the matches over the pre-edit text: the
      // message sync that carries the new text is queued after this dispatch.
      expect(bridge.searchCalls, isEmpty);
      expect(result.rehighlightSearch, isTrue);
      expect(result.runMessageSync, isTrue);
    });

    test('re-numbers without scrolling on the deferred pass', () {
      final bridge = _FakeBridge();
      final dispatcher = ChatWebViewSyncDispatcher(
        state: ChatWebViewSyncState(),
      );

      dispatcher.applySearch(
        bridge: bridge,
        fields: _fields(
          isGenerating: false,
          messages: const [],
          searchQuery: 'foo',
          searchCurrentIndex: 2,
        ),
        scroll: false,
      );

      expect(bridge.searchCalls, [('foo', 2, false)]);
    });

    test('session switch invalidates a delayed streaming delta', () async {
      final bridge = _FakeBridge();
      final delayedAppend = Completer<void>();
      bridge.appendMessageCompleter = delayedAppend;
      final syncState = ChatWebViewSyncState()..wasGenerating = true;
      final dispatcher = ChatWebViewSyncDispatcher(state: syncState);
      final capturedEpoch = syncState.streamEpoch;

      final delayedDelta = pushStreamingMessageOwned(
        bridge: bridge,
        message: _assistant('__streaming__'),
        syncState: syncState,
        epoch: capturedEpoch,
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(bridge.appendedMessages, [_assistant('__streaming__')]);

      final result = dispatcher.dispatch(
        bridge: _FakeBridge(),
        old: _fields(isGenerating: true, messages: [_assistant('old')]),
        current: _fields(
          charId: 'c2',
          sessionId: 's2',
          isGenerating: false,
          messages: [_assistant('new')],
        ),
        oldMessages: [_assistant('old')],
        newMessages: [_assistant('new')],
        streamingId: '__streaming__',
        onSyncExtBlockPanels: () async {},
        appendMessage: (_) async {},
        buildStreamingPlaceholder: () => _assistant('__streaming__'),
      );

      expect(result.sessionSwitched, isTrue);
      delayedAppend.complete();
      await delayedDelta;
      expect(syncState.streamingSent, isFalse);
      expect(syncState.streamEpoch, isNot(capturedEpoch));
    });

    test(
      'refreshes last assistant controls on stream-to-post-gen transition',
      () {
        final bridge = _FakeBridge()..isGenerating = true;
        final message = _assistant('a1');
        final dispatcher = ChatWebViewSyncDispatcher(
          state: ChatWebViewSyncState()..wasGenerating = true,
        );

        dispatcher.dispatch(
          bridge: bridge,
          old: _fields(isGenerating: true, messages: [message]),
          current: _fields(
            isGenerating: false,
            isPostGenRunning: true,
            messages: [message],
          ),
          oldMessages: [message],
          newMessages: [message],
          streamingId: '__streaming__',
          onSyncExtBlockPanels: () async {},
          appendMessage: (_) async {},
          buildStreamingPlaceholder: () => _assistant('__streaming__'),
        );

        expect(bridge.isGenerating, isFalse);
        expect(bridge.isPostGenRunning, isTrue);
        expect(bridge.updatedMessages, [message]);
        expect(bridge.updatedIsLast, [true]);
        expect(bridge.lastMessageIds, ['a1']);
        expect(bridge.evalCalls.single, contains('setGenerating(false)'));
        expect(bridge.evalCalls.single, contains('setPostGenRunning(true)'));
        // The image stage flag goes through a setter, not a bare assignment:
        // it is what tells a pending block apart from a running one, and the
        // WebView has to restamp its placeholders when it flips (INV-IG1).
        expect(
          bridge.evalCalls.single,
          contains('setImageGenerating(false)'),
        );
      },
    );

    test('refreshes last assistant controls when post-gen settles', () {
      final bridge = _FakeBridge()..isPostGenRunning = true;
      final message = _assistant('a1');
      final dispatcher = ChatWebViewSyncDispatcher(
        state: ChatWebViewSyncState(),
      );

      dispatcher.dispatch(
        bridge: bridge,
        old: _fields(
          isGenerating: false,
          isPostGenRunning: true,
          messages: [message],
        ),
        current: _fields(isGenerating: false, messages: [message]),
        oldMessages: [message],
        newMessages: [message],
        streamingId: '__streaming__',
        onSyncExtBlockPanels: () async {},
        appendMessage: (_) async {},
        buildStreamingPlaceholder: () => _assistant('__streaming__'),
      );

      expect(bridge.isPostGenRunning, isFalse);
      expect(bridge.updatedMessages, [message]);
      expect(bridge.updatedIsLast, [true]);
      expect(bridge.lastMessageIds, ['a1']);
      expect(bridge.evalCalls.single, contains('setPostGenRunning(false)'));
    });

    test('does not flag a non-trailing assistant as last when a user message '
        'trails after a cancelled generation', () {
      // Reproduces the cancel+regen stuck-Regenerate-button bug: after Stop
      // trims the empty assistant placeholder, the trailing message is the
      // user turn. The falling edge must NOT stamp data-is-last on the
      // earlier char bubble (greeting), otherwise two sections carry the flag
      // and setLastMessage (single querySelector) can never clear the
      // user-message Regenerate button on the next generation.
      final bridge = _FakeBridge()..isGenerating = true;
      final greeting = _assistant('greeting');
      final user = _user('u1');
      final dispatcher = ChatWebViewSyncDispatcher(
        state: ChatWebViewSyncState()..wasGenerating = true,
      );

      dispatcher.dispatch(
        bridge: bridge,
        old: _fields(isGenerating: true, messages: [greeting, user]),
        current: _fields(isGenerating: false, messages: [greeting, user]),
        oldMessages: [greeting, user],
        newMessages: [greeting, user],
        streamingId: '__streaming__',
        onSyncExtBlockPanels: () async {},
        appendMessage: (_) async {},
        buildStreamingPlaceholder: () => _assistant('__streaming__'),
      );

      // The trailing message is the user turn → the last assistant bubble is
      // not last and must be refreshed with isLast=false.
      expect(bridge.updatedMessages, [greeting]);
      expect(bridge.updatedIsLast, [false]);
      // setLastMessage targets the trailing user message (which injects and
      // owns the sole data-is-last / Regenerate button).
      expect(bridge.lastMessageIds, ['u1']);
      expect(bridge.evalCalls.single, contains('setGenerating(false)'));
    });

    test('continuation flags its target instead of adding a placeholder', () {
      // A continuation extends an existing bubble; a typing placeholder would
      // show the reply as its own block that collapses into the original once
      // the merged message arrives.
      final bridge = _FakeBridge();
      final message = _assistant('a1');
      final syncState = ChatWebViewSyncState();
      final dispatcher = ChatWebViewSyncDispatcher(state: syncState);

      final result = dispatcher.dispatch(
        bridge: bridge,
        old: _fields(isGenerating: false, messages: [message]),
        current: _fields(
          isGenerating: true,
          messages: [message],
          continuationTargetId: 'a1',
        ),
        oldMessages: [message],
        newMessages: [message],
        streamingId: '__streaming__',
        onSyncExtBlockPanels: () async {},
        appendMessage: (_) async {},
        buildStreamingPlaceholder: () => _assistant('__streaming__'),
      );

      expect(result.appendPlaceholder, isFalse);
      expect(bridge.updatedMessages.last.id, 'a1');
      expect(bridge.updatedMessages.last.isTyping, isTrue);
      // Nothing virtual was appended, so the falling edge must not remove it.
      expect(syncState.regenStreamingSent, isTrue);
    });

    test('syncs overlay blur regions only when they change', () {
      final dispatcher = ChatWebViewSyncDispatcher(
        state: ChatWebViewSyncState(),
      );
      final bridge = _FakeBridge();
      List<ChatOverlayBlurRegion> regions() => [
        ChatOverlayBlurRegion(
          id: 'header',
          rect: const Rect.fromLTWH(16, 40, 300, 56),
          radius: 20,
        ),
      ];
      void dispatch(
        ChatWebViewWidgetFields old,
        ChatWebViewWidgetFields current,
      ) {
        dispatcher.dispatch(
          bridge: bridge,
          old: old,
          current: current,
          oldMessages: const [],
          newMessages: const [],
          streamingId: '__streaming__',
          onSyncExtBlockPanels: () async {},
          appendMessage: (_) async {},
          buildStreamingPlaceholder: () => _assistant('__streaming__'),
        );
      }

      // Equal-but-not-identical lists must NOT re-send.
      dispatch(
        _fields(isGenerating: false, messages: [], blurRegions: regions()),
        _fields(isGenerating: false, messages: [], blurRegions: regions()),
      );
      expect(bridge.overlayBlurCalls, isEmpty);

      // A moved region re-sends exactly once.
      final moved = [
        ChatOverlayBlurRegion(
          id: 'header',
          rect: const Rect.fromLTWH(16, 40, 300, 72),
          radius: 20,
        ),
      ];
      dispatch(
        _fields(isGenerating: false, messages: [], blurRegions: regions()),
        _fields(isGenerating: false, messages: [], blurRegions: moved),
      );
      expect(bridge.overlayBlurCalls, hasLength(1));
      expect(bridge.overlayBlurCalls.single, moved);
    });

    test('patches memory status without requesting message-list sync', () {
      final dispatcher = ChatWebViewSyncDispatcher(
        state: ChatWebViewSyncState(),
      );
      final bridge = _FakeBridge();
      final message = _assistant('a1');

      final result = dispatcher.dispatch(
        bridge: bridge,
        old: _fields(isGenerating: false, messages: [message]),
        current: _fields(
          isGenerating: false,
          messages: [message],
          memoryDrafts: const [
            _MemoryDraft(['a1']),
          ],
        ),
        oldMessages: [message],
        newMessages: [message],
        streamingId: '__streaming__',
        onSyncExtBlockPanels: () async {},
        appendMessage: (_) async {},
        buildStreamingPlaceholder: () => _assistant('__streaming__'),
      );

      expect(result.runMessageSync, isFalse);
      expect(bridge.memoryUpdates, hasLength(1));
      expect(bridge.memoryUpdates.single.$2, hasLength(1));
    });
  });
}

ChatMessage _assistant(String id) =>
    ChatMessage(id: id, role: 'assistant', content: 'assistant', timestamp: 1);

ChatMessage _user(String id) =>
    ChatMessage(id: id, role: 'user', content: 'user', timestamp: 1);

ChatWebViewWidgetFields _fields({
  required bool isGenerating,
  required List<ChatMessage> messages,
  String charId = 'c1',
  String? sessionId = 's1',
  bool isPostGenRunning = false,
  String? continuationTargetId,
  List<ChatOverlayBlurRegion> blurRegions = const [],
  List<dynamic> memoryDrafts = const [],
  String? searchQuery,
  int searchCurrentIndex = -1,
  int searchRevision = 0,
}) => ChatWebViewWidgetFields(
  continuationTargetId: continuationTargetId,
  blurRegions: blurRegions,
  charId: charId,
  charName: 'Character',
  charColor: null,
  personaName: null,
  charAvatarPath: null,
  personaAvatarPath: null,
  bgImagePath: null,
  bgBlur: 0,
  bgDim: 0,
  bgNoiseOpacity: 0,
  bgNoiseIntensity: 0,
  bottomInset: 0,
  topInset: 0,
  searchQuery: searchQuery,
  searchCurrentIndex: searchCurrentIndex,
  searchRevision: searchRevision,
  chatLayout: 'default',
  themeSyncKey: 'theme',
  elementOpacity: 1,
  elementBlur: 0,
  uiFontWeight: 400,
  userMessageFontWeight: 400,
  charMessageFontWeight: 400,
  userBubbleRadius: 18,
  charBubbleRadius: 18,
  showUserAvatar: true,
  showCharAvatar: true,
  showUserName: true,
  showCharName: true,
  chatFontName: null,
  chatFontDataUrl: null,
  chatFontSize: 16,
  chatLetterSpacing: 0,
  isSelectionMode: false,
  batterySaver: false,
  hideMessageId: false,
  hideGenerationTime: false,
  hideTokenCount: false,
  disableSwipeRegeneration: false,
  studioEnabled: false,
  memoryEntries: const [],
  memoryDrafts: memoryDrafts,
  sessionId: sessionId,
  isGenerating: isGenerating,
  isGeneratingImage: false,
  isPostGenRunning: isPostGenRunning,
  regenTargetId: null,
  greetingTotal: 0,
  messages: messages,
  buildThemeMap: () => const {},
);

class _FakeBridge implements ChatBridgeController {
  @override
  bool isGenerating = false;

  @override
  bool isGeneratingImage = false;

  @override
  bool isPostGenRunning = false;

  final List<List<ChatOverlayBlurRegion>> overlayBlurCalls = [];
  final List<String> evalCalls = [];
  final List<(String, int, bool)> searchCalls = [];
  final List<ChatMessage> updatedMessages = [];
  final List<ChatMessage> appendedMessages = [];
  final List<bool> updatedIsLast = [];
  final List<String?> lastMessageIds = [];
  final List<(List<Map<String, dynamic>>, List<Map<String, dynamic>>, bool)>
  memoryUpdates = [];
  Completer<void>? appendMessagesCompleter;
  Completer<void>? appendMessageCompleter;

  @override
  Future<void> setOverlayBlurRegions(
    List<ChatOverlayBlurRegion> regions,
  ) async {
    overlayBlurCalls.add(regions);
  }

  @override
  Future<void> evalJs(String source) async {
    evalCalls.add(source);
  }

  @override
  Future<void> removeMessage(String _) async {}

  @override
  Future<void> setSearch({
    required String query,
    int activeIndex = -1,
    bool scroll = true,
  }) async {
    searchCalls.add((query, activeIndex, scroll));
  }

  @override
  Future<void> appendMessages(
    List<ChatMessage> messages, {
    int startIndex = 0,
  }) async {
    appendedMessages.addAll(messages);
    await appendMessagesCompleter?.future;
  }

  @override
  Future<void> appendMessage(ChatMessage message) async {
    appendedMessages.add(message);
    await appendMessageCompleter?.future;
  }

  @override
  Future<void> updateMessage(
    ChatMessage message, {
    bool isStreamingUpdate = false,
    bool isLast = false,
  }) async {
    updatedMessages.add(message);
    updatedIsLast.add(isLast);
  }

  @override
  Future<void> setLastMessage(String? messageId) async {
    lastMessageIds.add(messageId);
  }

  @override
  Future<void> updateMemoryBookData({
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> pendingDrafts,
    bool patchMessages = true,
  }) async {
    memoryUpdates.add((entries, pendingDrafts, patchMessages));
  }

  @override
  Future<void> setIdentity({
    String? charName,
    String? charColor,
    String? personaName,
    String? layout,
    String? charAvatarPath,
    String? personaAvatarPath,
    int? greetingTotal,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MemoryDraft {
  const _MemoryDraft(this.messageIds);

  final List<String> messageIds;
}
