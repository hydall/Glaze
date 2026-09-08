import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chat_message.dart';
import '../../core/services/generation_notification_service.dart';
import '../../core/utils/id_generator.dart';
import '../extensions/services/extension_post_gen_service.dart';
import 'chat_provider.dart' show streamingStateProvider;
import 'state/post_cleaner_state_provider.dart'
    show PostCleanerState, cleanerCancelTokenProvider, postCleanerStateProvider;
import 'state/studio_cycle_state_provider.dart';
import 'chat_session_service.dart';
import 'chat_state.dart';
import 'services/continuation_message_merger.dart';

typedef AbortSessionMutation =
    Future<ChatSession?> Function(
      String sessionId,
      ChatSession? Function(ChatSession latest) mutate,
    );

class AbortHandler {
  final Ref _ref;
  final String _charId;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;
  final AbortSessionMutation _mutateSession;
  final Future<ChatSession?> Function(String sessionId) _loadSession;

  CancelToken? _cancelToken;
  CancelToken? _imgGenCancelToken;
  ChatMessage? _restorationMessage;
  int _activeGenId = 0;
  Future<void>? _abortFuture;

  AbortHandler({
    required this._ref,
    required this._charId,
    required this._setState,
    required this._getState,
    required this._mutateSession,
    required this._loadSession,
  });

  int nextGenId() => ++_activeGenId;
  bool isCurrentGen(int genId) => _activeGenId == genId;

  // ignore: unnecessary_getters_setters
  ChatMessage? get restorationMessage => _restorationMessage;
  set restorationMessage(ChatMessage? msg) => _restorationMessage = msg;
  // ignore: unnecessary_getters_setters
  CancelToken? get imgGenCancelToken => _imgGenCancelToken;
  set imgGenCancelToken(CancelToken? t) => _imgGenCancelToken = t;

  bool get isGeneratingImage =>
      _imgGenCancelToken != null && !(_imgGenCancelToken!.isCancelled);

  void setCancelToken(CancelToken token, {required int genId}) {
    if (_activeGenId != genId) {
      token.cancel();
      return;
    }
    _cancelToken = token;
  }

  void abortImageGeneration() {
    if (!_ref.mounted) return;
    _imgGenCancelToken?.cancel();
  }

  void cancelImageGeneration() {
    if (!_ref.mounted) return;
    _imgGenCancelToken?.cancel();
  }

  void clearStreaming() {
    if (!_ref.mounted) return;
    _ref.read(streamingStateProvider(_charId).notifier).state =
        const StreamingState();
  }

  void clearStudioCycle() {
    if (!_ref.mounted) return;
    final cur = _ref.read(studioCycleStateProvider);
    if (cur.phase == StudioCyclePhase.running ||
        cur.phase == StudioCyclePhase.writingFinal) {
      _ref.read(studioCycleStateProvider.notifier).state =
          const StudioCycleState.idle();
    }
  }

  Future<void> abortGeneration() {
    final active = _abortFuture;
    if (active != null) return active;
    final future = _abortGeneration();
    _abortFuture = future;
    return future.whenComplete(() {
      if (identical(_abortFuture, future)) _abortFuture = null;
    });
  }

  Future<void> _abortGeneration() async {
    if (!_ref.mounted) return;
    _activeGenId++;
    final StreamingState partialStreaming = _ref.read(
      streamingStateProvider(_charId),
    );
    _cancelToken?.cancel();
    _cancelToken = null;
    _imgGenCancelToken?.cancel();
    _imgGenCancelToken = null;
    // Cancel any in-flight post-gen work (cleaner, fact-checker, ledger).
    // The ledger shares the cleaner's CancelToken, so one cancel covers both.
    final cleanerToken = _ref.read(cleanerCancelTokenProvider);
    if (cleanerToken != null && !cleanerToken.isCancelled) {
      cleanerToken.cancel('User aborted post-gen');
    }
    _ref.read(cleanerCancelTokenProvider.notifier).state = null;
    _ref.read(extensionPostGenServiceProvider).cancelBlocks();
    _ref.read(postCleanerStateProvider.notifier).state =
        const PostCleanerState.idle();
    clearStreaming();
    clearStudioCycle();

    final current = _getState().value;
    if (current != null && (current.isGenerating || current.isPostGenRunning)) {
      final restorationSnapshot = _restorationMessage;
      final abortGenId = _activeGenId;
      try {
        final durableSession = await _finalizeAbortWithPartial(
          current,
          partialStreaming,
          restorationSnapshot,
        );
        if (!_ref.mounted || _activeGenId != abortGenId) return;
        if (durableSession != null) {
          ChatSessionService.updateCache(durableSession);
        }
        _setState(
          AsyncData(
            current.copyWith(
              session: durableSession ?? current.session,
              isGenerating: false,
              isGeneratingImage: false,
              isPostGenRunning: false,
              regenTargetId: null,
              continuationTargetId: null,
            ),
          ),
        );
      } catch (error) {
        if (!_ref.mounted || _activeGenId != abortGenId) return;
        final sessionId = current.session?.id;
        final durableSession = sessionId == null
            ? current.session
            : await _loadSession(sessionId);
        if (!_ref.mounted || _activeGenId != abortGenId) return;
        if (durableSession != null) {
          ChatSessionService.updateCache(durableSession);
        }
        _setState(
          AsyncData(
            current.copyWith(
              session: durableSession ?? current.session,
              isGenerating: false,
              isGeneratingImage: false,
              isPostGenRunning: false,
              regenTargetId: null,
              continuationTargetId: null,
              error: 'Failed to save the aborted response: $error',
            ),
          ),
        );
      }
    } else if (current != null && current.isGeneratingImage) {
      _setState(AsyncData(current.copyWith(isGeneratingImage: false)));
    }
    _restorationMessage = null;

    await GenerationNotificationService.instance.onGenerationAborted();
  }

  /// Stop pressed while `continueMessage()` was streaming. The partial text
  /// belongs to the message being continued — merge it in place (exactly what
  /// the completed run would have done) instead of appending a separate
  /// assistant bubble, which would contradict what the WebView already shows.
  Future<ChatSession?> _finalizeContinuationAbort(
    ChatState current,
    StreamingState partialStreaming,
    String continuationId,
  ) async {
    final messages = current.session?.messages ?? const <ChatMessage>[];
    final idx = messages.indexWhere((m) => m.id == continuationId);
    final partialText = partialStreaming.text.trim();
    final session = current.session;
    if (session == null) return null;
    if (idx < 0 || partialText.isEmpty) return _loadSession(session.id);

    final expected = messages[idx];
    return _mutateSession(session.id, (latest) {
      final latestIdx = latest.messages.indexWhere(
        (m) => m.id == continuationId,
      );
      if (latestIdx < 0 || latestIdx != latest.messages.length - 1) return null;
      final target = latest.messages[latestIdx];
      if (target.content != expected.content ||
          target.swipeId != expected.swipeId ||
          target.agentSwipeId != expected.agentSwipeId) {
        return null;
      }
      final merged = mergeContinuationMessage(
        target,
        ChatMessage(
          id: continuationId,
          role: 'assistant',
          content: partialText,
          reasoning: partialStreaming.reasoning,
        ),
      );
      final updatedMessages = [...latest.messages]..[latestIdx] = merged;
      return latest.copyWith(messages: updatedMessages);
    }).then((updated) async => updated ?? await _loadSession(session.id));
  }

  Future<ChatSession?> _finalizeAbortWithPartial(
    ChatState current,
    StreamingState partialStreaming,
    ChatMessage? restoration,
  ) async {
    final session = current.session;
    if (session == null) return null;

    final continuationId = current.continuationTargetId;
    if (continuationId != null) {
      return _finalizeContinuationAbort(
        current,
        partialStreaming,
        continuationId,
      );
    }

    final regenId = current.regenTargetId;

    if (regenId != null && restoration != null) {
      final String partialText = partialStreaming.text;
      if (partialText.isEmpty) return _loadSession(session.id);
      final updatedSession = await _mutateSession(session.id, (latest) {
        final idx = latest.messages.indexWhere((m) => m.id == regenId);
        if (idx < 0) return null;
        final target = latest.messages[idx];
        if (target.content != restoration.content ||
            target.swipeId != restoration.swipeId ||
            target.agentSwipeId != restoration.agentSwipeId) {
          return null;
        }
        final keptSwipes = List<String>.from(
          restoration.swipes.isNotEmpty
              ? restoration.swipes
              : [restoration.content],
        );
        final keptSwipesMeta = List<Map<String, dynamic>>.from(
          restoration.swipesMeta.isNotEmpty
              ? restoration.swipesMeta
              : [
                  <String, dynamic>{
                    'genTime': restoration.genTime,
                    'reasoning': restoration.reasoning,
                    'tokens': restoration.tokens,
                  },
                ],
        );
        keptSwipes.add(partialText);
        keptSwipesMeta.add(<String, dynamic>{});
        final newSwipeId = keptSwipes.length - 1;
        final updated = target.copyWith(
          content: partialText,
          swipeId: newSwipeId,
          swipes: keptSwipes,
          swipesMeta: keptSwipesMeta,
          reasoning: partialStreaming.reasoning,
          genTime: null,
          tokens: null,
          isTyping: false,
          // Partial text becomes a fresh (healthy) swipe; with nothing
          // streamed we put the pre-regen variation back untouched — an
          // errored one included, so cancelling a regen over an error does
          // not launder the error away.
          isError: false,
          swipeDirection: 'right',
        );
        final updatedMessages = [...latest.messages];
        updatedMessages[idx] = updated;
        return latest.copyWith(messages: updatedMessages);
      });
      return updatedSession ?? _loadSession(session.id);
    }

    if (restoration != null) {
      final updatedSession = await _mutateSession(session.id, (latest) {
        if (latest.messages.any((message) => message.id == restoration.id)) {
          return latest;
        }
        final expectedTailId = session.messages.isEmpty
            ? null
            : session.messages.last.id;
        final latestTailId = latest.messages.isEmpty
            ? null
            : latest.messages.last.id;
        if (latestTailId != expectedTailId) return null;
        return latest.copyWith(messages: [...latest.messages, restoration]);
      });
      return updatedSession ?? _loadSession(session.id);
    }

    final String partialText = partialStreaming.text;
    final String? partialReasoning = partialStreaming.reasoning;
    final bool hasPartial =
        partialText.isNotEmpty ||
        (partialReasoning != null && partialReasoning.isNotEmpty);

    final currentMessages = session.messages;
    final lastMsg = currentMessages.isNotEmpty ? currentMessages.last : null;
    final bool lastIsEmptyAssistant =
        lastMsg != null &&
        lastMsg.role == 'assistant' &&
        lastMsg.content.isEmpty &&
        (lastMsg.reasoning == null || lastMsg.reasoning!.isEmpty);

    if (hasPartial) {
      final partialMsg = ChatMessage(
        id: generateId(),
        role: 'assistant',
        content: partialText,
        reasoning: partialReasoning,
        isTyping: false,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        swipes: [partialText],
        swipeId: 0,
        swipesMeta: [<String, dynamic>{}],
      );
      final baseMessages = lastIsEmptyAssistant
          ? currentMessages.sublist(0, currentMessages.length - 1)
          : currentMessages;
      final expectedTailId = baseMessages.isEmpty ? null : baseMessages.last.id;
      final updatedSession = await _mutateSession(session.id, (latest) {
        final latestTailId = latest.messages.isEmpty
            ? null
            : latest.messages.last.id;
        if (latestTailId != expectedTailId) return null;
        return latest.copyWith(messages: [...latest.messages, partialMsg]);
      });
      return updatedSession ?? _loadSession(session.id);
    }

    return _loadSession(session.id);
  }
}
