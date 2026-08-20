import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/prompt_build_providers.dart';
import '../../../core/llm/studio/studio_stream_interceptor.dart';
import '../../../core/llm/studio/studio_context_preparer.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../../core/state/studio_turn_config_resolver.dart';
import '../state/recovery_state_provider.dart';

/// Result of a recovery batch.
class RecoveryResult {
  final String status; // 'ok' | 'aborted' | 'error'
  final int trackersWritten;
  final int failedMessages;
  final String? error;

  const RecoveryResult({
    this.status = 'ok',
    this.trackersWritten = 0,
    this.failedMessages = 0,
    this.error,
  });
}

/// Re-runs the Studio tracker cycle for each assistant message in a session.
///
/// Used when tracker outputs (`studioOutputs`) were lost
/// due to the `writeAssistant` regression (fixed in the studioOutputs
/// restoration commit). The service walks the chat history message-by-message,
/// builds a partial prompt up to each assistant message, runs the tracker
/// cycle, and persists the briefs.
///
/// Progress is surfaced via [recoveryStateProvider] so the UI can show
/// "processing message N of M".
class TrackerMemoryRecoveryService {
  final Ref _ref;
  TrackerMemoryRecoveryService(this._ref);

  CancelToken? _cancelToken;

  /// Abort an in-flight recovery. No-op when not running.
  void cancel() {
    if (_cancelToken != null && !_cancelToken!.isCancelled) {
      _cancelToken!.cancel('User aborted recovery');
    }
  }

  Future<RecoveryResult> recover({
    required String sessionId,
    required String charId,
    bool recoverTrackers = true,
  }) async {
    final token = CancelToken();
    _cancelToken = token;

    final repo = _ref.read(chatRepoProvider);
    final session = await repo.getById(sessionId);
    if (session == null) {
      _ref.read(recoveryStateProvider.notifier).state = RecoveryState.error(
        sessionId: sessionId,
        error: 'session not found',
      );
      return const RecoveryResult(status: 'error', error: 'session not found');
    }

    // Collect assistant message indices (skip errors/typing/greeting).
    // Greeting = the first message in the session (index 0) when it is an
    // assistant message. Recovery must not re-run trackers/memory against it:
    // there is no user turn to derive state from, and runTrackerCycle would
    // fire the final generator (Gemini Pro) against an empty-user-turn context.
    final assistantIndices = <int>[];
    for (var i = 0; i < session.messages.length; i++) {
      if (i == 0 && session.messages[i].role == 'assistant') continue;
      final m = session.messages[i];
      if (m.role == 'assistant' && !m.isError && !m.isTyping) {
        assistantIndices.add(i);
      }
    }

    if (assistantIndices.isEmpty) {
      _ref.read(recoveryStateProvider.notifier).state = RecoveryState.done(
        sessionId: sessionId,
        totalMessages: 0,
        processedMessages: 0,
        trackersWritten: 0,
        failedMessages: 0,
      );
      return const RecoveryResult();
    }

    final turnConfig = recoverTrackers
        ? await _ref.read(studioTurnConfigResolverProvider).resolve(sessionId)
        : null;
    final studioConfig = turnConfig?.config;
    var trackersWritten = 0;
    var failed = 0;

    _ref.read(recoveryStateProvider.notifier).state = RecoveryState.running(
      sessionId: sessionId,
      totalMessages: assistantIndices.length,
      processedMessages: 0,
      currentMessageIndex: -1,
      trackersWritten: 0,
      failedMessages: 0,
    );

    for (var i = 0; i < assistantIndices.length; i++) {
      if (token.isCancelled) break;
      final msgIdx = assistantIndices[i];
      final target = session.messages[msgIdx];

      _ref.read(recoveryStateProvider.notifier).state = RecoveryState.running(
        sessionId: sessionId,
        totalMessages: assistantIndices.length,
        processedMessages: i,
        currentMessageIndex: msgIdx,
        currentMessageId: target.id,
        trackersWritten: trackersWritten,
        failedMessages: failed,
      );

      // A. Studio tracker cycle re-run.
      if (recoverTrackers && studioConfig != null) {
        try {
          final sliced = session.copyWith(
            messages: session.messages.sublist(0, msgIdx + 1),
          );
          final inputs = await _ref
              .read(promptPayloadBuilderProvider)
              .collectGenerationContext(
                charId: charId,
                session: sliced,
                apiConfigOverride: turnConfig?.activeApiConfig,
                includeEffectiveCanon: true,
                shouldAbort: () => token.isCancelled,
                cancelToken: token,
              );
          if (token.isCancelled) break;
          final contextSize =
              turnConfig
                  ?.pipelineSettings
                  .studioAgent
                  .studioControllerContextSize ??
              0;
          final visibleMessageIds =
              StudioStreamInterceptor.computeStudioVisibleMessageIds(
                inputs.history,
                contextSize,
              );
          final context = const StudioContextPreparer().prepare(
            inputs: inputs,
            visibleMessageIds: visibleMessageIds,
            ledgerPromptInjectionPolicy:
                turnConfig?.ledgerPromptInjectionPolicy ??
                inputs.ledgerPromptInjectionPolicy,
            consumerPath: 'studio-tracker-recovery',
          );
          final result = await _ref
              .read(memoryStudioServiceProvider)
              .runTrackersOnly(
                config: studioConfig,
                inputs: inputs,
                context: context,
                apiConfig: inputs.apiConfig,
                sessionId: sessionId,
                turnConfig: turnConfig,
                cancelToken: token,
              );
          if (result.status == 'ok' || result.status == 'agent_errors') {
            await _setStudioOutputs(
              sessionId,
              target.id,
              StudioStreamInterceptor.studioOutputsToJson(result.stageBriefs),
            );
            trackersWritten++;
          }
        } catch (e) {
          failed++;
          debugPrint('[Recovery] tracker $i (msg $msgIdx) failed: $e');
        }
      }

      if (token.isCancelled) break;

      // B. Post-turn graph/salience bookkeeping (non-fatal).
      try {
        await _ref.read(memoryPostTurnServiceProvider).runPostTurn(sessionId);
      } catch (_) {}

      // Update progress after each message.
      _ref.read(recoveryStateProvider.notifier).state = RecoveryState.running(
        sessionId: sessionId,
        totalMessages: assistantIndices.length,
        processedMessages: i + 1,
        currentMessageIndex: msgIdx,
        currentMessageId: target.id,
        trackersWritten: trackersWritten,
        failedMessages: failed,
      );
    }

    _cancelToken = null;

    final wasCancelled = token.isCancelled;
    final finalState = wasCancelled
        ? RecoveryState.error(
            sessionId: sessionId,
            error: 'aborted',
            totalMessages: assistantIndices.length,
            processedMessages: trackersWritten,
            trackersWritten: trackersWritten,
            failedMessages: failed,
          )
        : RecoveryState.done(
            sessionId: sessionId,
            totalMessages: assistantIndices.length,
            processedMessages: assistantIndices.length,
            trackersWritten: trackersWritten,
            failedMessages: failed,
          );
    _ref.read(recoveryStateProvider.notifier).state = finalState;

    return RecoveryResult(
      status: wasCancelled ? 'aborted' : 'ok',
      trackersWritten: trackersWritten,
      failedMessages: failed,
    );
  }

  /// Read-modify-write: update `studioOutputs` on an existing assistant
  /// message (top-level + the active agentSwipe) and persist the session.
  /// Mirrors `ChatMessageService._persist` pattern.
  Future<void> _setStudioOutputs(
    String sessionId,
    String messageId,
    List<Map<String, dynamic>> outputs,
  ) async {
    final repo = _ref.read(chatRepoProvider);
    final session = await repo.getById(sessionId);
    if (session == null) return;
    final idx = session.messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final msg = session.messages[idx];
    var updated = msg.copyWith(studioOutputs: outputs);
    // Also update the first 'final' agentSwipe (index 0) so the Agentic Ops
    // panel sees the briefs regardless of which blue swipe is active.
    if (msg.agentSwipes.isNotEmpty) {
      final swipes = List<AgentSwipe>.from(msg.agentSwipes);
      swipes[0] = swipes[0].copyWith(studioOutputs: outputs);
      updated = updated.copyWith(agentSwipes: swipes);
    }
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[idx] = updated;
    await repo.put(
      session.copyWith(
        messages: newMessages,
        updatedAt: _currentTimestampSeconds(),
      ),
    );
  }

  static int _currentTimestampSeconds() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

final trackerMemoryRecoveryServiceProvider =
    Provider<TrackerMemoryRecoveryService>((ref) {
      return TrackerMemoryRecoveryService(ref);
    });
