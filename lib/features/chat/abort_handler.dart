import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/generation_phase.dart';
import '../../core/models/chat_message.dart';
import '../../core/plugins/plugin_hooks.dart';
import '../../core/state/card_rewriter_providers.dart';
import '../extensions/services/extension_post_gen_service.dart';
import 'chat_provider.dart' show streamingStateProvider;
import 'state/generation_phase_provider.dart';
import 'state/post_cleaner_state_provider.dart'
    show PostCleanerState, cleanerCancelTokenProvider, postCleanerStateProvider;
import 'state/studio_cycle_state_provider.dart';
import 'chat_session_service.dart';
import 'chat_state.dart';
import 'services/abort_planner.dart';

typedef AbortSessionMutation =
    Future<ChatSession?> Function(
      String sessionId,
      ChatSession? Function(ChatSession latest) mutate,
    );

class AbortHandler {
  Ref _ref;
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

  /// The Ref of the provider build under way; the notifier outlives a
  /// rebuild, the Ref it was built on does not — on the stale one a stop
  /// found it unmounted and did nothing. Called from every build.
  void rebind(Ref ref) => _ref = ref;

  /// The state as it is now, while the chat is still on the session
  /// [snapshot] was taken of. Null once it moved on — the provider was rebuilt
  /// onto another session, the session was deleted — and what the stop saved
  /// belongs to a chat no longer on screen: painting it would bring that chat
  /// back. A rebuild no longer ends a stop under way ([rebind]), so the
  /// session is what says whose state this is.
  ChatState? _sameSession(ChatState snapshot) {
    final latest = _getState().value;
    if (latest == null || latest.session?.id != snapshot.session?.id) {
      return null;
    }
    return latest;
  }

  int nextGenId() => ++_activeGenId;

  /// The generation now running or last run, without starting a new one.
  ///
  /// An image redraw binds to it rather than taking a new id: a new id would
  /// tell the post-gen work still running for that generation (cleaner,
  /// ExtBlocks, image tags) that it was superseded, so it would stop early
  /// and never clear `isPostGenRunning`.
  int get currentGenId => _activeGenId;
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

  /// Completes once no stop is being made durable — immediately when none is.
  /// New runs await this so a send tapped right after Stop is queued behind
  /// the stop's write instead of racing it.
  Future<void> get settled {
    final active = _abortFuture;
    if (active == null) return Future<void>.value();
    // A stop that failed to save already reported it on the chat state; the
    // run waiting behind it goes ahead regardless.
    return active.catchError((Object _) {});
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
    final abortedGenId = _activeGenId++;
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
    final sessionId = _getState().value?.session?.id;
    if (sessionId != null) {
      _ref.read(automatedCardEvolutionServiceProvider).cancelSession(sessionId);
    }
    _ref.read(postCleanerStateProvider.notifier).state =
        const PostCleanerState.idle();
    final abortGenId = _activeGenId;

    final current = _getState().value;
    if (current != null && current.isGenerating) {
      _ref.read(pluginHookRegistryProvider).forChat(_charId)?.notify(
        'generation:cancelled',
        {'generationId': '$_charId:$abortedGenId'},
      );
    }
    if (current != null && (current.isGenerating || current.isPostGenRunning)) {
      final restorationSnapshot = _restorationMessage;
      // A stop cannot fail, so the UI does not wait for it: the run is shown
      // as stopped — partial reply in place, a regenerated variation put
      // back — on the tap. Only the write is left, and `isStopping` holds the
      // message-mutating actions off until it lands.
      final plan = AbortPlanner(
        mutateSession: _mutateSession,
        loadSession: _loadSession,
      ).plan(current, partialStreaming, restorationSnapshot);
      _setState(
        AsyncData(
          current.copyWith(
            session: plan?.optimistic ?? current.session,
            isGenerating: false,
            isGeneratingImage: false,
            isPostGenRunning: false,
            isSendPending: false,
            isStopping: true,
            regenTargetId: null,
            continuationTargetId: null,
          ),
        ),
      );
      clearStreaming();
      clearStudioCycle();
      setGenerationPhase(_ref, _charId, GenerationPhase.idle);
      try {
        final durableSession = plan == null ? null : await plan.persist();
        if (!_ref.mounted || _activeGenId != abortGenId) return;
        if (durableSession != null) {
          ChatSessionService.updateCache(durableSession);
        }
        final latest = _sameSession(current);
        if (latest != null) {
          _setState(
            AsyncData(
              latest.copyWith(
                session: durableSession ?? latest.session,
                isStopping: false,
              ),
            ),
          );
        }
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
        final latest = _sameSession(current);
        if (latest != null) {
          _setState(
            AsyncData(
              latest.copyWith(
                session: durableSession ?? latest.session,
                isStopping: false,
                error: 'Failed to save the aborted response: $error',
              ),
            ),
          );
        }
      } finally {
        // Whatever path left early, the stop is over: never leave the
        // mutating actions locked out behind it.
        if (_ref.mounted) {
          final latest = _getState().value;
          if (latest != null && latest.isStopping) {
            _setState(AsyncData(latest.copyWith(isStopping: false)));
          }
        }
      }
    } else {
      clearStreaming();
      clearStudioCycle();
      if (current != null && current.isGeneratingImage) {
        _setState(AsyncData(current.copyWith(isGeneratingImage: false)));
      }
    }
    _restorationMessage = null;
    // A run started meanwhile owns the phase now; the early returns above
    // already leave it alone, this guard covers the remaining paths.
    if (_ref.mounted && _activeGenId == abortGenId) {
      setGenerationPhase(_ref, _charId, GenerationPhase.idle);
    }
  }
}
