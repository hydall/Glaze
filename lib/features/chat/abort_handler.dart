import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chat_message.dart';
import '../../core/services/generation_notification_service.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../extensions/services/extension_post_gen_service.dart';
import 'chat_provider.dart' show streamingStateProvider;
import 'state/post_cleaner_state_provider.dart'
    show PostCleanerState, cleanerCancelTokenProvider, postCleanerStateProvider;
import 'state/studio_cycle_state_provider.dart';
import 'chat_session_service.dart';
import 'chat_state.dart';
import 'services/continuation_message_merger.dart';
import 'services/variation_error_state.dart';

class AbortHandler {
  final Ref _ref;
  final String _charId;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;
  final void Function(ChatSession) _persistSession;

  CancelToken? _cancelToken;
  CancelToken? _imgGenCancelToken;
  ChatMessage? _restorationMessage;
  int _activeGenId = 0;

  AbortHandler({
    required this._ref,
    required this._charId,
    required this._setState,
    required this._getState,
    required this._persistSession,
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

  void abortGeneration() {
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
      // Phase 1: unblock UI immediately. Clear both the streaming flag and
      // the post-gen flag so gates re-open and the Stop button reverts.
      _setState(
        AsyncData(
          current.copyWith(
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
          ),
        ),
      );

      // Phase 2: heavier restore/persist work is deferred to avoid first-abort jank.
      // Guard: if a new generation started (genId bumped again), skip restoration
      // to avoid overwriting the active regen state and duplicating messages.
      scheduleMicrotask(() {
        if (!_ref.mounted) return;
        if (_activeGenId != abortGenId) return;
        _finalizeAbortWithPartial(
          current,
          partialStreaming,
          restorationSnapshot,
        );
      });
    } else if (current != null && current.isGeneratingImage) {
      _setState(AsyncData(current.copyWith(isGeneratingImage: false)));
    }
    _restorationMessage = null;

    GenerationNotificationService.instance.onGenerationAborted();
  }

  /// Stop pressed while `continueMessage()` was streaming. The partial text
  /// belongs to the message being continued — merge it in place (exactly what
  /// the completed run would have done) instead of appending a separate
  /// assistant bubble, which would contradict what the WebView already shows.
  void _finalizeContinuationAbort(
    ChatState current,
    StreamingState partialStreaming,
    String continuationId,
  ) {
    final messages = current.session?.messages ?? const <ChatMessage>[];
    final idx = messages.indexWhere((m) => m.id == continuationId);
    final partialText = partialStreaming.text.trim();
    if (idx < 0 || partialText.isEmpty) {
      _setState(
        AsyncData(
          current.copyWith(
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
            continuationTargetId: null,
          ),
        ),
      );
      return;
    }

    final merged = mergeContinuationMessage(
      messages[idx],
      ChatMessage(
        id: continuationId,
        role: 'assistant',
        content: partialText,
        reasoning: partialStreaming.reasoning,
      ),
    );
    final updatedMessages = [...messages];
    updatedMessages[idx] = merged;
    final updatedSession = current.session?.copyWith(
      messages: updatedMessages,
      updatedAt: currentTimestampSeconds(),
    );
    if (updatedSession != null) {
      _persistSession(updatedSession);
      ChatSessionService.updateCache(updatedSession);
    }
    _setState(
      AsyncData(
        current.copyWith(
          session: updatedSession ?? current.session,
          isGenerating: false,
          isGeneratingImage: false,
          isPostGenRunning: false,
          continuationTargetId: null,
        ),
      ),
    );
  }

  void _finalizeAbortWithPartial(
    ChatState current,
    StreamingState partialStreaming,
    ChatMessage? restoration,
  ) {
    if (!_ref.mounted) return;
    if (!current.isGenerating) {
      // Current is the pre-abort snapshot; continue restoration logic below.
    }

    final continuationId = current.continuationTargetId;
    if (continuationId != null) {
      _finalizeContinuationAbort(current, partialStreaming, continuationId);
      return;
    }

    final regenId = current.regenTargetId;

    if (regenId != null && restoration != null) {
      final idx = current.messages.indexWhere((m) => m.id == regenId);
      if (idx >= 0) {
        final String partialText = partialStreaming.text;
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
        if (partialText.isNotEmpty) {
          keptSwipes.add(partialText);
          keptSwipesMeta.add(<String, dynamic>{});
        }
        final newSwipeId = keptSwipes.length - 1;
        final updated = current.messages[idx].copyWith(
          content: partialText.isNotEmpty ? partialText : restoration.content,
          swipeId: partialText.isNotEmpty ? newSwipeId : restoration.swipeId,
          swipes: keptSwipes,
          swipesMeta: keptSwipesMeta,
          reasoning: partialText.isNotEmpty
              ? partialStreaming.reasoning
              : restoration.reasoning,
          genTime: partialText.isNotEmpty ? null : restoration.genTime,
          tokens: partialText.isNotEmpty ? null : restoration.tokens,
          isTyping: false,
          // Partial text becomes a fresh (healthy) swipe; with nothing
          // streamed we put the pre-regen variation back untouched — an
          // errored one included, so cancelling a regen over an error does
          // not launder the error away.
          isError: partialText.isNotEmpty
              ? false
              : restoredVariationIsError(restoration, keptSwipesMeta),
          swipeDirection: partialText.isNotEmpty
              ? 'right'
              : restoration.swipeDirection,
        );
        final updatedMessages = [...current.messages];
        updatedMessages[idx] = updated;
        final updatedSession = current.session?.copyWith(
          messages: updatedMessages,
          updatedAt: currentTimestampSeconds(),
        );
        if (updatedSession != null) {
          _persistSession(updatedSession);
          ChatSessionService.updateCache(updatedSession);
        }
        _setState(
          AsyncData(
            ChatState(
              session: updatedSession ?? current.session,
              isGenerating: false,
              isGeneratingImage: false,
              isPostGenRunning: false,
              regenTargetId: null,
            ),
          ),
        );
      } else {
        _setState(
          AsyncData(
            ChatState(
              session: current.session,
              isGenerating: false,
              isGeneratingImage: false,
              isPostGenRunning: false,
              regenTargetId: null,
            ),
          ),
        );
      }
      return;
    }

    if (restoration != null) {
      final restoredMessages = <ChatMessage>[
        ...(current.session?.messages ?? const <ChatMessage>[]),
        restoration,
      ];
      final restoredSession = current.session?.copyWith(
        messages: restoredMessages,
        updatedAt: currentTimestampSeconds(),
      );
      if (restoredSession != null) {
        _persistSession(restoredSession);
        ChatSessionService.updateCache(restoredSession);
      }
      _setState(
        AsyncData(
          current.copyWith(
            session: restoredSession ?? current.session,
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
          ),
        ),
      );
      return;
    }

    final String partialText = partialStreaming.text;
    final String? partialReasoning = partialStreaming.reasoning;
    final bool hasPartial =
        partialText.isNotEmpty ||
        (partialReasoning != null && partialReasoning.isNotEmpty);

    final currentMessages = current.session?.messages ?? const <ChatMessage>[];
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
      final updatedMessages = [...baseMessages, partialMsg];
      final updatedSession = current.session?.copyWith(
        messages: updatedMessages,
        updatedAt: currentTimestampSeconds(),
      );
      if (updatedSession != null) {
        _persistSession(updatedSession);
        ChatSessionService.updateCache(updatedSession);
      }
      _setState(
        AsyncData(
          current.copyWith(
            session: updatedSession ?? current.session,
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
          ),
        ),
      );
    } else if (lastIsEmptyAssistant) {
      final trimmedMessages = currentMessages.sublist(
        0,
        currentMessages.length - 1,
      );
      final trimmedSession = current.session?.copyWith(
        messages: trimmedMessages,
        updatedAt: currentTimestampSeconds(),
      );
      if (trimmedSession != null) {
        _persistSession(trimmedSession);
        ChatSessionService.updateCache(trimmedSession);
      }
      _setState(
        AsyncData(
          current.copyWith(
            session: trimmedSession ?? current.session,
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
          ),
        ),
      );
    } else {
      _setState(
        AsyncData(
          current.copyWith(
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
          ),
        ),
      );
    }
  }
}
