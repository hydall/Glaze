import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/llm/tokenizer.dart';
import '../../core/models/chat_message.dart';
import '../../core/services/generation_notification_service.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../core/state/db_provider.dart';
import '../chat_history/chat_history_provider.dart';
import '../memory/state/memory_active_drafts_provider.dart';
import 'abort_handler.dart';
import 'chat_generation_service.dart';
import 'chat_session_service.dart';
import 'chat_state.dart';
import 'editing_message_provider.dart';
import 'generating_sessions_provider.dart';
import 'unread_sessions_provider.dart';
import 'image_recovery_service.dart';
import 'controllers/chat_message_ops_controller.dart';
import 'controllers/chat_swipe_controller.dart';
import 'controllers/chat_session_controller.dart';
import 'controllers/chat_draft_controller.dart';
import 'services/continuation_message_merger.dart';
import 'services/generation_pipeline.dart';
import 'services/impersonation_service.dart';
import 'utils/message_preview.dart';
import '../extensions/services/extension_post_gen_service.dart';

final chatProvider =
    AsyncNotifierProvider.family<ChatNotifier, ChatState, String>(
      ChatNotifier.new,
    );

final streamingStateProvider = StateProvider.family<StreamingState, String>(
  (ref, _) => const StreamingState(),
);

/// Transient state for an in-flight (or just-finished) impersonation. The
/// compose bar watches this: while [active] it mirrors [text] into the input
/// and locks editing; when it flips to inactive the streamed text is left in
/// the box for the user to edit and send. Mirrors Glaze's `isImpersonating` +
/// `inputValue` streaming.
class ImpersonationState {
  final bool active;
  final String text;
  const ImpersonationState({this.active = false, this.text = ''});
}

final impersonationStateProvider =
    StateProvider.family<ImpersonationState, String>(
      (ref, _) => const ImpersonationState(),
    );

/// One-shot signal that impersonation could not start because the effective
/// preset has no `impersonationPrompt`. The chat screen listens and surfaces a
/// prompt to configure it, then clears the flag.
final impersonationNeedsConfigProvider = StateProvider.family<bool, String>(
  (ref, _) => false,
);

class ChatNotifier extends AsyncNotifier<ChatState> {
  ChatNotifier(this.arg);

  final String arg;
  bool _buildComplete = false;

  void _persistSession(ChatSession session) {
    ref.read(chatRepoProvider).put(session).catchError((Object e) {
      debugPrint('[ChatNotifier] failed to persist session: $e');
    });
    ChatSessionService.updateCache(session);
  }

  /// Reflects the active session's generation state into
  /// [generatingSessionsProvider]. Called on every state transition; membership
  /// updates are idempotent so streaming chunks don't churn the registry.
  void _syncGeneratingRegistry(AsyncValue<ChatState> next) {
    final s = next.value;
    final sessionId = s?.session?.id;
    final generating = s != null && (s.isGenerating || s.isPostGenRunning);
    final registry = ref.read(generatingSessionsProvider.notifier);

    // A session switch mid-generation must not leave the previous session
    // stuck showing the indicator.
    final prevId = _registeredGeneratingSessionId;
    if (prevId != null && prevId != sessionId) {
      registry.unmark(prevId);
      _registeredGeneratingSessionId = null;
    }

    if (sessionId == null) return;
    if (generating) {
      registry.mark(sessionId);
      _registeredGeneratingSessionId = sessionId;
    } else {
      registry.unmark(sessionId);
      if (_registeredGeneratingSessionId == sessionId) {
        _registeredGeneratingSessionId = null;
      }
    }
  }

  /// The sessionId currently marked in [generatingSessionsProvider] by this
  /// notifier, so a session switch can clear the stale entry.
  String? _registeredGeneratingSessionId;

  @override
  Future<ChatState> build() async {
    ref.keepAlive();
    // Mirror this character's generation state into the global registry so the
    // chat list can show a live "typing" indicator for the session without
    // building its full state. Generation outlives the chat screen
    // (`keepAlive`), so the entry persists until the reply actually finishes.
    listenSelf(
      (_, AsyncValue<ChatState> next) => _syncGeneratingRegistry(next),
    );
    _buildComplete = false;
    final existing = await _sessionSvc.findExistingSession(arg);
    if (!ref.mounted) return const ChatState();
    if (_buildComplete) {
      return state.value ?? ChatState(session: existing);
    }
    if (existing != null) {
      final fixed = _fixupSwipesWithImageResults(existing);
      if (!identical(fixed, existing)) {
        await ref.read(chatRepoProvider).put(fixed);
        ChatSessionService.updateCache(fixed);
        if (!ref.mounted) return const ChatState();
      }
      final start = fixed.messages.length > ChatState.initialPageSize
          ? fixed.messages.length - ChatState.initialPageSize
          : 0;
      final result = ChatState(session: fixed, visibleStartIndex: start);
      _buildComplete = true;
      return result;
    }
    final session = await _sessionSvc.createInitialSession(arg);
    if (!ref.mounted) return const ChatState();
    _buildComplete = true;
    return ChatState(session: session);
  }

  void loadOlderMessages() {
    final current = state.value;
    if (current == null || !current.hasMoreOlder || current.isLoadingOlder) {
      return;
    }

    final newStart = current.visibleStartIndex > ChatState.olderPageSize
        ? current.visibleStartIndex - ChatState.olderPageSize
        : 0;
    state = AsyncData(
      current.copyWith(visibleStartIndex: newStart, isLoadingOlder: false),
    );
  }

  late final AbortHandler _abortHandler = AbortHandler(
    ref: ref,
    charId: arg,
    setState: (s) {
      state = s;
    },
    getState: () => state,
    persistSession: _persistSession,
  );

  void setCancelToken(CancelToken token, {required int genId}) =>
      _abortHandler.setCancelToken(token, genId: genId);

  bool get isGeneratingImage => _abortHandler.isGeneratingImage;

  ChatSession _fixupSwipesWithImageResults(ChatSession session) =>
      ImageRecoveryService.fixupSwipesWithImageResults(session);

  void abortImageGeneration() => _abortHandler.abortImageGeneration();
  void abortGeneration() => _abortHandler.abortGeneration();
  void cancelImageGeneration() => _abortHandler.cancelImageGeneration();
  Future<void> retryImageGeneration() async =>
      _imageRecoverySvc.retryImageGeneration();
  Future<void> findImageOnDisk(String messageId, String instruction) async =>
      _imageRecoverySvc.findImageOnDisk(messageId, instruction);
  final Set<String> _queuedImageRetries = <String>{};
  Future<void> retryImageGenerationForMessage(String messageId) async {
    if (!_queuedImageRetries.add(messageId)) return;
    try {
      await _imageRecoverySvc.retryImageGenerationForMessage(messageId);
    } finally {
      _queuedImageRetries.remove(messageId);
    }
  }

  ChatSessionService get _sessionSvc => ChatSessionService(ref);
  ImageRecoveryService get _imageRecoverySvc => ImageRecoveryService(
    ref: ref,
    charId: arg,
    setImgGenCancelToken: (t) {
      _abortHandler.imgGenCancelToken = t;
    },
    getImgGenCancelToken: () => _abortHandler.imgGenCancelToken,
    startImageOperation: _abortHandler.nextGenId,
    isCurrentGeneration: _abortHandler.isCurrentGen,
    setState: (s) {
      state = s;
    },
    getState: () => state,
  );

  // Controllers
  late final _messageOpsCtrl = ChatMessageOpsController(
    ref: ref,
    charId: arg,
    setState: (s) {
      state = s;
    },
    getState: () => state,
    invalidateHistory: _invalidateHistory,
  );

  late final _swipeCtrl = ChatSwipeController(
    ref: ref,
    charId: arg,
    setState: (s) {
      state = s;
    },
    getState: () => state,
    invalidateHistory: _invalidateHistory,
  );

  late final _sessionCtrl = ChatSessionController(
    ref: ref,
    charId: arg,
    setState: (s) {
      state = s;
    },
    getState: () => state,
    invalidateHistory: _invalidateHistory,
    fixupSwipesWithImageResults: _fixupSwipesWithImageResults,
  );

  late final _draftCtrl = ChatDraftController(
    ref: ref,
    setState: (s) {
      state = s;
    },
    getState: () => state,
  );

  void _invalidateHistory() => ref.invalidate(chatHistoryProvider);

  // Delegate methods to controllers
  Future<void> editMessage(
    int index,
    String newContent, {
    String? tagStart,
    String? tagEnd,
  }) => _messageOpsCtrl.editMessage(
    index,
    newContent,
    tagStart: tagStart,
    tagEnd: tagEnd,
  );

  Future<void> moveMessage(int fromIndex, int toIndex) =>
      _messageOpsCtrl.moveMessage(fromIndex, toIndex);

  Future<void> deleteMessage(int index) => _messageOpsCtrl.deleteMessage(index);

  Future<void> deleteMessages(Set<int> indices) =>
      _messageOpsCtrl.deleteMessages(indices);

  Future<void> toggleMessageHidden(int index) =>
      _messageOpsCtrl.toggleMessageHidden(index);

  Future<void> toggleImageHidden(int index) =>
      _messageOpsCtrl.toggleImageHidden(index);

  Future<void> unhideAllMessages() => _messageOpsCtrl.unhideAllMessages();

  Future<void> hideTopMessages(int count) =>
      _messageOpsCtrl.hideTopMessages(count);

  Future<void> clearChat() => _messageOpsCtrl.clearChat();

  void setSwipe(int messageIndex, int swipeId) =>
      _swipeCtrl.setSwipe(messageIndex, swipeId);

  Future<void> changeSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) => _swipeCtrl.changeSwipe(messageIndex, dir, fromSwipe: fromSwipe);

  Future<void> changeAgentSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) => _swipeCtrl.changeAgentSwipe(messageIndex, dir, fromSwipe: fromSwipe);

  Future<void> deleteActiveSwipe(int messageIndex) =>
      _swipeCtrl.deleteActiveSwipe(messageIndex);

  Future<void> deleteActiveAgentSwipe(int messageIndex) =>
      _swipeCtrl.deleteActiveAgentSwipe(messageIndex);

  Future<void> setGreeting(int messageIndex, int direction) =>
      _swipeCtrl.setGreeting(messageIndex, direction);

  Future<void> switchSession(int sessionIndex) =>
      _sessionCtrl.switchSession(sessionIndex);

  Future<void> createNewSession() => _sessionCtrl.createNewSession();

  Future<List<ChatSession>> getSessions() => _sessionCtrl.getSessions();

  Future<void> branchSession(int index) => _sessionCtrl.branchSession(index);

  Future<void> newSession() => _sessionCtrl.createNewSession();

  Future<void> saveDraft(String draftText) => _draftCtrl.saveDraft(draftText);

  Future<void> sendMessage(
    String text, {
    String? guidanceText,
    String? imageDataUrl,
  }) async {
    if (!ref.mounted) return;
    if (ref.read(editingMessageIdProvider(arg)) != null) return;
    final current = state.value;
    if (current == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning) {
      return;
    }
    if (_isMemoryDraftActive(current)) return;

    final userMsg = ChatMessage(
      id: generateId(),
      role: 'user',
      content: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      tokens: estimateTokens(text),
      imagePath: imageDataUrl,
    );

    final acceptedAssistant = current.messages.reversed
        .where((message) => message.role == 'assistant')
        .firstOrNull;

    // Show the user bubble and the typing indicator on the same frame as the
    // tap. Persisting the session re-encodes the whole message list on the UI
    // isolate and the ledger commit adds more round trips, so publishing the
    // state only after those writes made both appear a beat late on long
    // chats. The writes below just reconcile this optimistic session with the
    // persisted one.
    final optimisticSession = current.session!.copyWith(
      messages: [...current.messages, userMsg],
      draft: '',
      updatedAt: currentTimestampSeconds(),
    );
    state = AsyncData(
      current.copyWith(
        session: optimisticSession,
        isGenerating: true,
        generationStartTime: DateTime.now(),
      ),
    );
    await _yieldToFrame();
    if (!ref.mounted) return;

    final updatedSession = await ref
        .read(chatRepoProvider)
        .appendUserMessageAndClearDraft(
          sessionId: current.session!.id,
          message: userMsg,
          updatedAt: currentTimestampSeconds(),
        );
    if (!ref.mounted) return;
    if (updatedSession == null) {
      // The session row is gone — roll the optimistic append back.
      state = AsyncData(current);
      return;
    }
    // Commit the exact visible green/blue swipe, never whichever Ledger call
    // happened to finish most recently.
    final snapshotRepo = ref.read(trackerSnapshotRepoProvider);
    final committedSnapshot = acceptedAssistant == null
        ? null
        : await snapshotRepo.getByAnchor(
            sessionId: current.session!.id,
            messageId: acceptedAssistant.id,
            swipeId: acceptedAssistant.swipeId,
            agentSwipeId: acceptedAssistant.agentSwipeId,
          );
    if (committedSnapshot != null) {
      await snapshotRepo.commit(
        sessionId: committedSnapshot.sessionId,
        messageId: committedSnapshot.messageId,
        swipeId: committedSnapshot.swipeId,
        agentSwipeId: committedSnapshot.agentSwipeId,
      );
      await ref
          .read(characterKnowledgeFactRepoProvider)
          .activateAnchor(
            sessionId: current.session!.id,
            messageId: committedSnapshot.messageId,
            swipeId: committedSnapshot.swipeId,
            agentSwipeId: committedSnapshot.agentSwipeId,
          );
    }
    if (!ref.mounted) return;
    ChatSessionService.updateCache(updatedSession);
    _invalidateHistory();
    final afterWrite = state.value;
    // Stop was pressed (or the session changed) while the writes were in
    // flight — the user message is persisted, but this generation is off.
    if (afterWrite == null ||
        !afterWrite.isGenerating ||
        afterWrite.session?.id != updatedSession.id) {
      return;
    }
    state = AsyncData(afterWrite.copyWith(session: updatedSession));

    // Dispatch `afterUser` extension blocks. This is fire-and-forget — the
    // generation pipeline starts immediately, the post-gen service runs
    // the chain in the background and persists its own InfoBlocks.
    unawaited(_dispatchAfterUserBlocks(updatedSession));

    try {
      final charRepo = ref.read(characterRepoProvider);
      final character = await charRepo.getById(arg);
      if (!ref.mounted) return;
      if (character != null) {
        final talkativeness = character.extensions['talkativeness'];
        if (talkativeness is num && talkativeness < 1.0) {
          final roll = DateTime.now().microsecond % 100 / 100.0;
          if (roll > talkativeness) {
            _abortHandler.clearStreaming();
            state = AsyncData(
              current.copyWith(session: updatedSession, isGenerating: false),
            );
            return;
          }
        }
      }

      await _runGeneration(updatedSession, current, guidanceText: guidanceText);
    } catch (e, st) {
      debugPrint('[ChatNotifier] send setup failed: $e\n$st');
      if (!ref.mounted) return;
      final latest = state.value;
      if (latest?.session?.id == updatedSession.id) {
        state = AsyncData(
          latest!.copyWith(
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
            error: e.toString(),
          ),
        );
      }
    }
  }

  /// Waits for the pending frame to be built before returning, so an
  /// optimistic state update is actually pushed to the WebView bridge before
  /// the caller starts heavy synchronous work (session JSON encode/decode) on
  /// the UI isolate. Without this the update is scheduled but the frame that
  /// carries it can be starved until the write finishes — exactly the delay
  /// the optimistic update exists to remove. The timeout keeps the send path
  /// alive if no frame is produced (e.g. the app is backgrounded).
  Future<void> _yieldToFrame() async {
    Future<void>? endOfFrame;
    try {
      endOfFrame = SchedulerBinding.instance.endOfFrame;
    } catch (e) {
      // No binding (headless / unit tests) — there is no frame to wait on.
      debugPrint('[ChatNotifier] frame yield skipped: $e');
    }
    if (endOfFrame == null) return;
    await endOfFrame.timeout(
      const Duration(milliseconds: 200),
      onTimeout: () {},
    );
  }

  Future<void> _dispatchAfterUserBlocks(ChatSession session) async {
    try {
      if (!ref.mounted) return;
      final charRepo = ref.read(characterRepoProvider);
      final character = await charRepo.getById(arg);
      if (!ref.mounted) return;
      if (character == null) return;
      final post = ref.read(extensionPostGenServiceProvider);
      await post.runAfterUserBlocks(
        charId: arg,
        session: session,
        character: character,
        persona: null,
      );
    } catch (e) {
      debugPrint('[ChatNotifier] afterUser dispatch failed: $e');
    }
  }

  Future<void> regenerateLastAssistant({String? guidanceText}) async {
    if (!ref.mounted) return;
    if (ref.read(editingMessageIdProvider(arg)) != null) return;
    if (state.value?.isGenerating == true ||
        state.value?.isPostGenRunning == true) {
      abortGeneration();
    }
    final current = state.value;
    if (current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning) {
      return;
    }
    if (_isMemoryDraftActive(current)) return;

    final lastIdx = current.messages.length - 1;
    if (lastIdx < 0) return;

    final lastMsg = current.messages[lastIdx];

    if (lastMsg.role == 'user') {
      state = AsyncData(
        current.copyWith(
          isGenerating: true,
          generationStartTime: DateTime.now(),
        ),
      );
      final promptSession = current.session!.copyWith(
        messages: current.messages,
        updatedAt: currentTimestampSeconds(),
      );
      await _runGeneration(
        promptSession,
        current,
        saveSession: current.session!,
        guidanceText: guidanceText,
      );
      return;
    }

    final prevAssistant = lastMsg;
    final regenTargetId = prevAssistant.id;
    _abortHandler.restorationMessage = prevAssistant;

    final clearedMsg = prevAssistant.copyWith(
      content: '',
      reasoning: null,
      isTyping: true,
      genTime: null,
      tokens: null,
      isError: false,
    );
    final clearedMessages = [...current.messages];
    clearedMessages[lastIdx] = clearedMsg;
    final clearedSession = current.session!.copyWith(
      messages: clearedMessages,
      updatedAt: currentTimestampSeconds(),
    );

    state = AsyncData(
      ChatState(
        session: clearedSession,
        isGenerating: true,
        generationStartTime: DateTime.now(),
        regenTargetId: regenTargetId,
        visibleStartIndex: current.visibleStartIndex,
      ),
    );

    final promptMessages = [...current.messages];
    promptMessages.removeAt(lastIdx);
    final promptSession = current.session!.copyWith(
      messages: promptMessages,
      updatedAt: currentTimestampSeconds(),
    );

    await _runGeneration(
      promptSession,
      current,
      saveSession: current.session!,
      guidanceText: guidanceText,
      regenTargetId: regenTargetId,
      previousSwipes: prevAssistant.swipes.isNotEmpty
          ? prevAssistant.swipes
          : [prevAssistant.content],
      previousSwipeId: prevAssistant.swipeId,
      previousReasoning: prevAssistant.reasoning,
      previousGenTime: prevAssistant.genTime,
      previousTokens: prevAssistant.tokens,
      previousSwipesMeta: _previousSwipesMetaForRegen(prevAssistant),
    );
  }

  /// Impersonation: generate the user's next message from the preset's
  /// `impersonationPrompt` and stream it into the compose box (never into the
  /// chat). Optional [guidanceText] steers it via the guided-impersonation
  /// wrapper. Mirrors hydall/Glaze `startImpersonation`.
  Future<void> impersonate({String? guidanceText}) async {
    if (!ref.mounted) return;
    if (ref.read(editingMessageIdProvider(arg)) != null) return;
    final current = state.value;
    if (current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning) {
      return;
    }
    if (_isMemoryDraftActive(current)) return;

    final session = current.session!;
    // Impersonation never restores a chat message on abort — clear any stale
    // restoration target left by a prior regenerate so Stop only drops the
    // streamed input text.
    _abortHandler.restorationMessage = null;
    final genId = _abortHandler.nextGenId();
    final service = ImpersonationService(
      ref: ref,
      charId: arg,
      isAborted: () => !_abortHandler.isCurrentGen(genId),
    );

    final impersonationPrompt = service.resolveImpersonationPrompt(session.id);
    if (impersonationPrompt == null) {
      ref.read(impersonationNeedsConfigProvider(arg).notifier).state = true;
      return;
    }

    ref.read(impersonationStateProvider(arg).notifier).state =
        const ImpersonationState(active: true, text: '');
    state = AsyncData(
      current.copyWith(isGenerating: true, generationStartTime: DateTime.now()),
    );

    try {
      await service.run(
        session: session,
        impersonationPrompt: impersonationPrompt,
        guidanceText: guidanceText,
        setCancelToken: (token) =>
            _abortHandler.setCancelToken(token, genId: genId),
        onDelta: (text) {
          if (!ref.mounted || !_abortHandler.isCurrentGen(genId)) return;
          ref.read(impersonationStateProvider(arg).notifier).state =
              ImpersonationState(active: true, text: text);
        },
      );
    } catch (e, st) {
      debugPrint('[ChatNotifier] impersonation failed: $e\n$st');
    } finally {
      if (ref.mounted) {
        // Settle the impersonation state (keep whatever text streamed so far so
        // the user can edit/send it) regardless of who won the genId race.
        final impersonation = ref.read(impersonationStateProvider(arg));
        if (impersonation.active) {
          ref.read(impersonationStateProvider(arg).notifier).state =
              ImpersonationState(active: false, text: impersonation.text);
        }
        // Only clear the generating flag if this run still owns the slot; an
        // abort/newer generation already reset it otherwise.
        if (_abortHandler.isCurrentGen(genId)) {
          final latest = state.value;
          if (latest != null && latest.isGenerating) {
            state = AsyncData(latest.copyWith(isGenerating: false));
          }
        }
      }
    }
  }

  List<Map<String, dynamic>>? _previousSwipesMetaForRegen(ChatMessage message) {
    if (message.swipesMeta.isNotEmpty) return message.swipesMeta;
    final swipes = message.swipes.isNotEmpty
        ? message.swipes
        : [message.content];
    return List<Map<String, dynamic>>.generate(
      swipes.length,
      (i) => i == message.swipeId
          ? <String, dynamic>{
              'genTime': message.genTime,
              'reasoning': message.reasoning,
              'tokens': message.tokens,
            }
          : <String, dynamic>{},
    );
  }

  Future<void> continueMessage() async {
    if (!ref.mounted) return;
    if (ref.read(editingMessageIdProvider(arg)) != null) return;
    final current = state.value;
    if (current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning) {
      return;
    }
    if (_isMemoryDraftActive(current)) return;

    final lastIdx = current.messages.length - 1;
    if (lastIdx < 0) return;
    final lastMsg = current.messages[lastIdx];
    if (lastMsg.role != 'assistant') {
      // Nothing to extend when the user spoke last — the useful action there
      // is a plain reply to that message. `regenerateLastAssistant` already
      // routes a trailing user message through the full generation pipeline
      // (post-gen stages included), so reuse it instead of continuing an
      // assistant message that is no longer at the end of the chat.
      if (lastMsg.role == 'user') await regenerateLastAssistant();
      return;
    }

    final genId = _abortHandler.nextGenId();
    _abortHandler.clearStreaming();
    // Continuation never rolls a message back on abort; drop any restoration
    // snapshot a previous regenerate left behind so Stop cannot re-append it.
    _abortHandler.restorationMessage = null;
    state = AsyncData(
      current.copyWith(
        isGenerating: true,
        generationStartTime: DateTime.now(),
        continuationTargetId: lastMsg.id,
      ),
    );

    final notifService = GenerationNotificationService.instance;
    var notificationStarted = false;
    try {
      final charRepo = ref.read(characterRepoProvider);
      final character = await charRepo.getById(arg);
      if (!ref.mounted || !_abortHandler.isCurrentGen(genId)) return;
      notificationStarted = true;
      await notifService.onGenerationStarted(character?.name ?? 'Unknown');
      if (!ref.mounted || !_abortHandler.isCurrentGen(genId)) return;

      final service = ref.read(chatGenerationServiceProvider);
      final result = await service.generate(
        session: current.session!,
        charId: arg,
        genId: genId,
        currentState: current,
        onStateUpdate: (s) {
          if (_abortHandler.isCurrentGen(genId)) state = AsyncData(s);
        },
        isAborted: () => !_abortHandler.isCurrentGen(genId),
      );

      if (!ref.mounted || !_abortHandler.isCurrentGen(genId)) return;

      var completedResult = result;
      final updatedMessages = mergeContinuationMessages(
        result.messages,
        lastMsg,
      );
      if (updatedMessages != null) {
        final finalSession = result.session!.copyWith(
          messages: updatedMessages,
          updatedAt: currentTimestampSeconds(),
        );
        await ref.read(chatRepoProvider).put(finalSession);
        if (!ref.mounted || !_abortHandler.isCurrentGen(genId)) return;
        ChatSessionService.updateCache(finalSession);
        _invalidateHistory();
        completedResult = result.copyWith(
          session: finalSession,
          isGenerating: false,
          isGeneratingImage: false,
          isPostGenRunning: false,
        );
        state = AsyncData(completedResult);
      } else {
        state = AsyncData(result);
      }

      final preview = buildMessagePreview(completedResult.messages);
      final finalSessionId = completedResult.session?.id;
      await notifService.onGenerationCompleted(
        character?.name ?? 'Unknown',
        arg,
        messagePreview: preview,
        sessionId: finalSessionId,
        msgId: completedResult.messages.isNotEmpty
            ? completedResult.messages.last.id
            : null,
        avatarPath: character?.avatarPath,
      );

      if (finalSessionId != null &&
          !notifService.isActiveSession(arg, finalSessionId)) {
        ref.read(unreadSessionsProvider.notifier).markUnread(finalSessionId);
      }
    } catch (e, st) {
      debugPrint('[ChatNotifier] continuation failed: $e\n$st');
      if (ref.mounted && _abortHandler.isCurrentGen(genId)) {
        _abortHandler.clearStreaming();
        final latest = state.value;
        if (latest?.session?.id == current.session!.id) {
          state = AsyncData(
            latest!.copyWith(
              isGenerating: false,
              isGeneratingImage: false,
              isPostGenRunning: false,
              continuationTargetId: null,
              error: e.toString(),
            ),
          );
        }
      }
      if (notificationStarted) await notifService.onGenerationAborted();
    }
  }

  bool _isMemoryDraftActive(ChatState current) {
    final sessionId = current.session?.id;
    if (sessionId == null) return false;
    return ref.read(memoryActiveDraftsProvider).contains(sessionId);
  }

  Future<void> _runGeneration(
    ChatSession session,
    ChatState current, {
    ChatSession? saveSession,
    String? guidanceText,
    List<String>? previousSwipes,
    int previousSwipeId = 0,
    String? previousReasoning,
    String? previousGenTime,
    int? previousTokens,
    List<Map<String, dynamic>>? previousSwipesMeta,
    String? regenTargetId,
  }) {
    final genId = _abortHandler.nextGenId();
    final pipeline = GenerationPipeline(
      ref: ref,
      charId: arg,
      abortHandler: _abortHandler,
      setState: (s) {
        state = s;
      },
      getState: () => state,
    );
    return pipeline.run(
      genId: genId,
      session: session,
      saveSession: saveSession,
      guidanceText: guidanceText,
      previousSwipes: previousSwipes,
      previousSwipeId: previousSwipeId,
      previousReasoning: previousReasoning,
      previousGenTime: previousGenTime,
      previousTokens: previousTokens,
      previousSwipesMeta: previousSwipesMeta,
      regenTargetId: regenTargetId,
    );
  }

  /// Re-run POST-cleaner on an existing assistant message. Triggers a new
  /// 'cleaned' blue sub-swipe appended to the target message, cleaning the
  /// final (agentSwipes[0]) text. See [GenerationPipeline.rerunCleaner].
  Future<void> rerunCleaner(String messageId) async {
    if (!ref.mounted) return;
    final current = state.value;
    if (current == null || current.isGenerating || current.isPostGenRunning) {
      return;
    }
    final sessionId = current.session?.id;
    if (sessionId == null) return;
    final pipeline = GenerationPipeline(
      ref: ref,
      charId: arg,
      abortHandler: _abortHandler,
      setState: (s) {
        state = s;
      },
      getState: () => state,
    );
    await pipeline.rerunCleaner(sessionId: sessionId, messageId: messageId);
  }
}
