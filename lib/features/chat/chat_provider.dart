import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/llm/generation_phase.dart';
import '../../core/llm/tokenizer.dart';
import '../../core/models/chat_message.dart';
import '../../core/db/repositories/lorebook_use_manifest_repo.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/persona_resolution.dart';
import '../chat_history/chat_history_provider.dart';
import '../memory/state/memory_active_drafts_provider.dart';
import 'abort_handler.dart';
import 'chat_session_service.dart';
import 'chat_state.dart';
import 'editing_message_provider.dart';
import 'generating_sessions_provider.dart';
import 'image_recovery_service.dart';
import 'controllers/chat_message_ops_controller.dart';
import 'controllers/chat_swipe_controller.dart';
import 'controllers/chat_session_controller.dart';
import 'controllers/chat_draft_controller.dart';
import 'services/generation_pipeline.dart';
import 'services/impersonation_service.dart';
import 'state/chat_session_write_queue.dart';
import 'state/generation_phase_provider.dart';
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
  bool _sendInFlight = false;

  /// Bumped by every send that paints optimistically, so the sweep in that
  /// send's `finally` can tell its own [ChatState.isSendPending] from one a
  /// later send has since set.
  int _sendPendingSeq = 0;
  int _sessionChangesInFlight = 0;

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
    _sessionCtrl = _createSessionController(ref);
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
    mutateSession: (sessionId, mutate) => ref
        .read(chatRepoProvider)
        .mutateSession(
          sessionId: sessionId,
          mutate: mutate,
          updatedAt: currentTimestampSeconds(),
        ),
    loadSession: ref.read(chatRepoProvider).getById,
  );

  void setCancelToken(CancelToken token, {required int genId}) =>
      _abortHandler.setCancelToken(token, genId: genId);

  bool get isGeneratingImage => _abortHandler.isGeneratingImage;

  ChatSession _fixupSwipesWithImageResults(ChatSession session) =>
      ImageRecoveryService.fixupSwipesWithImageResults(session);

  void abortImageGeneration() => _abortHandler.abortImageGeneration();
  Future<void> abortGeneration() => _abortHandler.abortGeneration();
  void cancelImageGeneration() => _abortHandler.cancelImageGeneration();
  Future<void> retryImageGeneration() async =>
      _imageRecoverySvc.retryImageGeneration();
  Future<void> findImageOnDisk(
    String messageId,
    String instruction, {
    int? blockIndex,
  }) async => _imageRecoverySvc.findImageOnDisk(
    messageId,
    instruction,
    blockIndex: blockIndex,
  );
  Future<void> selectImageVariant(
    String messageId,
    int blockIndex,
    int variantIndex,
  ) async =>
      _imageRecoverySvc.selectImageVariant(messageId, blockIndex, variantIndex);
  final Set<String> _queuedImageRetries = <String>{};
  Future<void> retryImageGenerationForMessage(
    String messageId, {
    bool failedOnly = false,
    int? blockIndex,
  }) async {
    // Per-image retries of the same message are distinct jobs, so the guard
    // keys on the block too — only a repeated tap on one block is dropped.
    final queueKey = '$messageId#${blockIndex ?? 'all'}';
    if (!_queuedImageRetries.add(queueKey)) return;
    try {
      await _imageRecoverySvc.retryImageGenerationForMessage(
        messageId,
        failedOnly: failedOnly,
        blockIndex: blockIndex,
      );
    } finally {
      _queuedImageRetries.remove(queueKey);
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
  //
  // Message deletion, variation switches and edits all write the same session
  // row, and every one of them re-reads the durable row inside its own
  // transaction. One queue shared by all of them keeps those writes in UI
  // order — otherwise a swipe committed while a delete is still in flight
  // reads the pre-delete message list and writes it straight back, which is
  // how deleted messages reappeared on the next variation switch.
  final ChatSessionWriteQueue _sessionWrites = ChatSessionWriteQueue();

  late final _messageOpsCtrl = ChatMessageOpsController(
    ref: ref,
    charId: arg,
    setState: (s) {
      state = s;
    },
    getState: () => state,
    invalidateHistory: _invalidateHistory,
    writes: _sessionWrites,
  );

  late final _swipeCtrl = ChatSwipeController(
    ref: ref,
    charId: arg,
    setState: (s) {
      state = s;
    },
    getState: () => state,
    invalidateHistory: _invalidateHistory,
    writes: _sessionWrites,
  );

  late ChatSessionController _sessionCtrl;

  ChatSessionController _createSessionController(Ref buildRef) =>
      ChatSessionController(
        ref: buildRef,
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

  Future<void> setSwipe(int messageIndex, int swipeId) =>
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
      _runSessionChange(() => _sessionCtrl.switchSession(sessionIndex));

  Future<void> createNewSession() =>
      _runSessionChange(_sessionCtrl.createNewSession);

  Future<List<ChatSession>> getSessions() => _sessionCtrl.getSessions();

  Future<ChatSession?> branchSession(int index) async {
    _sessionChangesInFlight++;
    try {
      return await _sessionCtrl.branchSession(index);
    } finally {
      _sessionChangesInFlight--;
    }
  }

  Future<void> newSession() => _runSessionChange(_sessionCtrl.createNewSession);

  Future<void> _runSessionChange(Future<void> Function() operation) async {
    _sessionChangesInFlight++;
    try {
      await operation();
    } finally {
      _sessionChangesInFlight--;
    }
  }

  Future<void> saveDraft(String draftText) => _draftCtrl.saveDraft(draftText);

  /// Starts a send only when this notifier can take ownership immediately and
  /// resolves true after the user message is durably appended. UI callers keep
  /// the composer intact on a busy guard or persistence failure.
  Future<bool> trySendMessage(
    String text, {
    String? guidanceText,
    String? imageDataUrl,
  }) {
    if (!ref.mounted ||
        _sendInFlight ||
        _sessionChangesInFlight > 0 ||
        ref.read(editingMessageIdProvider(arg)) != null) {
      return Future.value(false);
    }
    final current = state.value;
    if (current == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning ||
        _isMemoryDraftActive(current)) {
      return Future.value(false);
    }

    final durableAcceptance = Completer<bool>();
    unawaited(
      _sendMessage(
        text,
        guidanceText: guidanceText,
        imageDataUrl: imageDataUrl,
        durableAcceptance: durableAcceptance,
      ).catchError((Object error, StackTrace stackTrace) {
        debugPrint('[ChatNotifier] accepted send failed: $error\n$stackTrace');
        if (!durableAcceptance.isCompleted) {
          durableAcceptance.complete(false);
        }
      }),
    );
    return durableAcceptance.future;
  }

  Future<void> sendMessage(
    String text, {
    String? guidanceText,
    String? imageDataUrl,
  }) => _sendMessage(
    text,
    guidanceText: guidanceText,
    imageDataUrl: imageDataUrl,
  );

  Future<void> _sendMessage(
    String text, {
    String? guidanceText,
    String? imageDataUrl,
    Completer<bool>? durableAcceptance,
  }) async {
    if (!ref.mounted) {
      durableAcceptance?.complete(false);
      return;
    }
    await _sessionWrites.settle();
    if (!ref.mounted) {
      durableAcceptance?.complete(false);
      return;
    }
    if (ref.read(editingMessageIdProvider(arg)) != null) {
      durableAcceptance?.complete(false);
      return;
    }
    if (_sendInFlight) {
      durableAcceptance?.complete(false);
      return;
    }
    if (ref.read(editingMessageIdProvider(arg)) != null) {
      durableAcceptance?.complete(false);
      return;
    }
    final current = state.value;
    if (current == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning) {
      durableAcceptance?.complete(false);
      return;
    }
    if (_isMemoryDraftActive(current)) {
      durableAcceptance?.complete(false);
      return;
    }
    _sendInFlight = true;
    // Claimed before the try so the `finally` sweep can see it. Bumped here
    // rather than at the optimistic paint: the claim order is the tap order.
    final sendPendingToken = ++_sendPendingSeq;

    try {
      // Stamp the message with the persona that sent it. The id is what the
      // chat resolves against later (a renamed persona keeps naming its old
      // messages correctly, a deleted one falls back to the letter avatar);
      // the name is the snapshot that survives the persona being deleted.
      final sendingPersona = ref.read(
        effectivePersonaForChatProvider((
          charId: arg,
          sessionId: current.session!.id,
        )),
      );
      final userMsg = ChatMessage(
        id: generateId(),
        role: 'user',
        content: text,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        tokens: estimateTokens(text),
        imagePath: imageDataUrl,
        personaId: sendingPersona?.id,
        personaName: sendingPersona?.name,
      );

      // Only the assistant *immediately* before the new message is accepted —
      // `ChatRepo.appendUserMessageAndAcceptCurrentVariation` enforces exactly
      // that and refuses the whole write otherwise. Scanning back past a
      // trailing user message (a send aborted before anything streamed leaves
      // one) named an older variation, so the append was silently dropped and
      // the message the user just sent disappeared.
      final trailing = current.messages.isEmpty ? null : current.messages.last;
      final acceptedAssistant = trailing?.role == 'assistant' ? trailing : null;
      final expectedAcceptedVariation = acceptedAssistant == null
          ? null
          : LorebookUseGenerationIdentity(
              sessionId: current.session!.id,
              messageId: acceptedAssistant.id,
              swipeId: acceptedAssistant.swipeId,
              agentSwipeId: acceptedAssistant.agentSwipeId,
            );

      // Show the user bubble immediately, but do not publish the generation
      // state (and therefore the assistant placeholder) until the user message
      // has been durably appended. This preserves the visual and durable causal
      // order even when a long chat takes time to encode and persist.
      //
      // `isSendPending` covers exactly that gap: the bubble is on screen, the
      // reply is on its way, and the WebView must not stamp a Regenerate
      // button under a message it is about to answer. Cleared atomically with
      // the `isGenerating` publish below, and swept in this method's `finally`
      // for the paths that return before ever reaching it.
      final optimisticSession = current.session!.copyWith(
        messages: [...current.messages, userMsg],
        draft: '',
        updatedAt: currentTimestampSeconds(),
      );
      // The typing bubble goes up with this paint, so name the phase now —
      // otherwise it shows the default "Generating…" for the whole durable
      // write, which is the claim this label exists to stop making.
      setGenerationPhase(ref, arg, GenerationPhase.preparing);
      // The bubble is painted from the streaming state, so it must be empty
      // before the bubble exists. `GenerationPipeline.run` clears it too, but
      // that is a whole durable append later — anything the previous run left
      // behind would be the reply the user just read, shown again under the
      // message they just sent until the first token replaces it.
      _abortHandler.clearStreaming();
      state = AsyncData(
        current.copyWith(session: optimisticSession, isSendPending: true),
      );
      await _yieldToFrame();
      if (!ref.mounted) return;

      final updatedSession = expectedAcceptedVariation == null
          ? await ref
                .read(chatRepoProvider)
                .appendUserMessageAndClearDraft(
                  sessionId: current.session!.id,
                  message: userMsg,
                  updatedAt: currentTimestampSeconds(),
                )
          : await ref
                .read(chatRepoProvider)
                .appendUserMessageAndAcceptCurrentVariation(
                  sessionId: current.session!.id,
                  message: userMsg,
                  expectedPrecedingAssistant: expectedAcceptedVariation,
                  updatedAt: currentTimestampSeconds(),
                );
      if (!ref.mounted) return;
      if (updatedSession == null) {
        // The session row is gone — roll the optimistic append back.
        state = AsyncData(current);
        return;
      }
      // The append is now durable, so later setup work must not keep the
      // composer blocked if a tracker or post-generation stage stalls.
      _sendInFlight = false;
      if (durableAcceptance != null && !durableAcceptance.isCompleted) {
        durableAcceptance.complete(true);
      }
      ChatSessionService.updateCache(updatedSession);
      _invalidateHistory();
      final afterWrite = state.value;
      // The session may have changed, or another operation (regenerate/continue)
      // may have started generating while the durable append was in flight —
      // bail out in either case.
      if (afterWrite == null ||
          afterWrite.isGenerating ||
          afterWrite.session?.id != updatedSession.id) {
        return;
      }
      state = AsyncData(
        afterWrite.copyWith(
          session: updatedSession,
          isGenerating: true,
          isSendPending: false,
          generationStartTime: DateTime.now(),
        ),
      );

      // Dispatch `afterUser` extension blocks. This is fire-and-forget — the
      // generation pipeline starts immediately, the post-gen service runs
      // the chain in the background and persists its own InfoBlocks.
      unawaited(_dispatchAfterUserBlocks(updatedSession));

      try {
        // Commit the exact visible green/blue swipe, never whichever Ledger
        // call happened to finish most recently.
        //
        // Deliberately after the `isGenerating` publish: these are three more
        // DB round-trips, and the typing bubble is injected off that flag, so
        // running them in front of it delayed the bubble by their full cost on
        // every send. They still run before `_runGeneration`, which is the
        // ordering that matters — prompt assembly reads the committed snapshot
        // and the activated facts. Inside this `try` so a failure settles the
        // generation state it now runs behind, instead of escaping with
        // `isGenerating` stuck true.
        await _commitAcceptedVariation(current.session!.id, acceptedAssistant);
        if (!ref.mounted) return;

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

        await _runGeneration(
          updatedSession,
          current,
          guidanceText: guidanceText,
        );
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
    } finally {
      if (durableAcceptance != null && !durableAcceptance.isCompleted) {
        durableAcceptance.complete(false);
      }
      _sendInFlight = false;
      _clearSendPending(sendPendingToken);
      // A send that never reached the pipeline (session gone, ownership lost,
      // a throw) owns the phase it set above and has to put it back. The
      // pipeline already resets it on the paths that did reach it, so this is
      // a no-op there; the guard keeps it from clobbering whichever run took
      // ownership instead.
      final settled = state.value;
      if (settled != null &&
          !settled.isGenerating &&
          !settled.isPostGenRunning) {
        setGenerationPhase(ref, arg, GenerationPhase.idle);
      }
    }
  }

  /// Drops [ChatState.isSendPending] if [token]'s send still owns it. The
  /// normal path clears the flag atomically with the `isGenerating` publish;
  /// this covers the returns that never get there (session gone, ownership
  /// lost, a throw) so the Regenerate button cannot stay withheld for the rest
  /// of the session. A newer send owns a newer token and is left alone.
  void _clearSendPending(int token) {
    if (token != _sendPendingSeq) return;
    if (!ref.mounted) return;
    final latest = state.value;
    if (latest == null || !latest.isSendPending) return;
    state = AsyncData(latest.copyWith(isSendPending: false));
  }

  /// Records that the assistant variation the user was looking at when they
  /// sent is the accepted one: commits its tracker snapshot and activates the
  /// knowledge facts anchored to it. No-op when the send had no preceding
  /// assistant message, or when that variation carries no snapshot.
  Future<void> _commitAcceptedVariation(
    String sessionId,
    ChatMessage? acceptedAssistant,
  ) async {
    if (acceptedAssistant == null) return;
    final snapshotRepo = ref.read(trackerSnapshotRepoProvider);
    final committedSnapshot = await snapshotRepo.getByAnchor(
      sessionId: sessionId,
      messageId: acceptedAssistant.id,
      swipeId: acceptedAssistant.swipeId,
      agentSwipeId: acceptedAssistant.agentSwipeId,
    );
    if (committedSnapshot == null) return;
    if (!ref.mounted) return;
    await snapshotRepo.commit(
      sessionId: committedSnapshot.sessionId,
      messageId: committedSnapshot.messageId,
      swipeId: committedSnapshot.swipeId,
      agentSwipeId: committedSnapshot.agentSwipeId,
    );
    if (!ref.mounted) return;
    await ref
        .read(characterKnowledgeFactRepoProvider)
        .activateAnchor(
          sessionId: sessionId,
          messageId: committedSnapshot.messageId,
          swipeId: committedSnapshot.swipeId,
          agentSwipeId: committedSnapshot.agentSwipeId,
        );
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
        persona: ref.read(
          effectivePersonaForChatProvider((charId: arg, sessionId: session.id)),
        ),
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
      await abortGeneration();
    }
    await _sessionWrites.settle();
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

    // The reply always lands as a *new* variation (`SavedMessageWriter`
    // appends it to `swipes[]`), so open that slot the moment the run starts
    // instead of when the text arrives: the counter steps N/N → N+1/N+1 on the
    // tap. This is UI-only — `saveSession` below is the untouched pre-regen
    // session, so nothing extra is persisted. Cancelling puts it back: the
    // abort path reloads the durable row when nothing streamed, and rebuilds
    // `swipes[]` from `restorationMessage` + the partial text when it did.
    final pendingSwipes = [
      ...(prevAssistant.swipes.isNotEmpty
          ? prevAssistant.swipes
          : [prevAssistant.content]),
      '',
    ];
    final pendingSwipesMeta = [
      ...?_previousSwipesMetaForRegen(prevAssistant),
      <String, dynamic>{},
    ];

    final clearedMsg = prevAssistant.copyWith(
      content: '',
      reasoning: null,
      isTyping: true,
      genTime: null,
      tokens: null,
      time: null,
      isError: false,
      swipes: pendingSwipes,
      swipeId: pendingSwipes.length - 1,
      swipesMeta: pendingSwipesMeta,
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
    await _sessionWrites.settle();
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
    final swipes = message.swipes.isNotEmpty
        ? message.swipes
        : [message.content];
    final meta = List<Map<String, dynamic>>.generate(
      swipes.length,
      (i) => i < message.swipesMeta.length
          ? Map<String, dynamic>.from(message.swipesMeta[i])
          : <String, dynamic>{},
    );
    if (message.swipeId >= 0 && message.swipeId < meta.length) {
      final active = meta[message.swipeId];
      final nested = message.agentSwipes
          .map((swipe) => swipe.toJson())
          .toList();
      if (message.agentSwipeId >= 0 &&
          message.agentSwipeId < nested.length &&
          nested[message.agentSwipeId]['time'] == null) {
        nested[message.agentSwipeId]['time'] = message.time;
      }
      meta[message.swipeId] = <String, dynamic>{
        ...active,
        if (!active.containsKey('genTime')) 'genTime': message.genTime,
        if (!active.containsKey('reasoning')) 'reasoning': message.reasoning,
        if (!active.containsKey('tokens')) 'tokens': message.tokens,
        if (!active.containsKey('time')) 'time': message.time,
        if (nested.isNotEmpty) 'agentSwipes': nested,
        if (nested.isNotEmpty) 'agentSwipeId': message.agentSwipeId,
      };
    }
    return meta;
  }

  /// Extend the trailing assistant message with a fresh generation, then fold
  /// the result back into that message. Runs the ordinary chat pipeline —
  /// same transport, same protocol, same post-generation stages as a send —
  /// with the continue instruction injected right after the reply being
  /// extended. See `docs/INVARIANTS.md` INV-CM1..INV-CM4.
  Future<void> continueMessage() async {
    if (!ref.mounted) return;
    if (ref.read(editingMessageIdProvider(arg)) != null) return;
    await _sessionWrites.settle();
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

    final promptSession = current.session!.copyWith(
      messages: current.messages,
      updatedAt: currentTimestampSeconds(),
    );
    await _runGeneration(promptSession, current, continueTargetId: lastMsg.id);
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
    String? continueTargetId,
  }) {
    final genId = _abortHandler.nextGenId();
    // The typing bubble is already on screen (isGenerating flipped true just
    // before this call), so name the phase it is actually in rather than
    // letting it claim the model is writing while the prompt is still being
    // assembled. Every later transition is published from the stage that
    // owns it; the pipeline resets to idle on the way out.
    setGenerationPhase(ref, arg, GenerationPhase.preparing);
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
      continueTargetId: continueTargetId,
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
