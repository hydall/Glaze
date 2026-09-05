import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/game_time.dart';
import '../../../core/llm/generation_phase.dart';
import '../../../core/llm/history_assembler.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../core/llm/prompt/exact_lorebook_manifest.dart';
import '../../../core/llm/studio/studio_stream_interceptor.dart';
import '../../../core/llm/studio/studio_history_limiter.dart';
import '../../../core/llm/studio/studio_context.dart';
import '../../../core/llm/studio/studio_context_preparer.dart';
import '../../../core/llm/prompt/prompt_payload.dart';
import '../../../core/llm/prompt/prompt_result.dart';
import '../../../core/llm/context_calculator.dart';
import '../../../core/llm/stream_accumulator.dart';
import '../../../core/llm/studio_regex_applicator.dart';
import '../../../core/llm/beauty_state_parser.dart';
import '../../../core/llm/idle_timeout_guard.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/utils/error_format.dart';
import '../../../core/utils/cast_helpers.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../core/state/studio_turn_config_resolver.dart';
import '../../../core/state/studio_regex_provider.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/services/model_usage_service.dart';
import '../../../core/services/preset_defaults.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../chat_provider.dart';
import '../chat_state.dart';
import '../providers/prompt_build_providers.dart';
import '../state/cached_token_breakdown.dart';
import '../state/generation_phase_provider.dart';
import '../state/memory_activity_provider.dart';
import '../state/studio_cycle_state_mapper.dart';
import '../state/studio_cycle_state_provider.dart';
import 'memory_agent_recorder.dart';
import 'saved_message_writer.dart';

class StreamGenerationService {
  static final Map<String, List<Map<String, dynamic>>> _lastRequestsBySession =
      <String, List<Map<String, dynamic>>>{};

  final Ref _ref;
  final String _charId;
  final int _genId;
  final bool Function() _isAborted;
  final SavedMessageWriter _writer = const SavedMessageWriter();
  late final MemoryAgentRecorder _recorder = MemoryAgentRecorder(_ref);

  StreamGenerationService({
    required this._ref,
    required this._charId,
    required this._genId,
    required this._isAborted,
  });

  /// Publishes the live generation phase for the typing bubble. Never let a
  /// UI-only signal disturb the run: a stale generation must not overwrite
  /// the phase a newer one is reporting.
  void _phase(GenerationPhase phase) {
    if (_isAborted()) return;
    setGenerationPhase(_ref, _charId, phase);
  }

  Future<ChatState> run({
    required ChatSession session,
    ChatSession? saveSession,
    List<String>? previousSwipes,
    int previousSwipeId = 0,
    String? previousReasoning,
    String? previousGenTime,
    int? previousTokens,
    List<Map<String, dynamic>>? previousSwipesMeta,
    String? guidanceText,
    String? regenTargetId,
    String? continueTargetId,
    required ChatState currentState,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    final vsi = currentState.visibleStartIndex;
    // Everything captured from here on belongs to this turn (see
    // `bindTurnMessageId`).
    final turnStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    final cancelToken = CancelToken();
    var studioWasActive = false;
    _ref
        .read(chatProvider(_charId).notifier)
        .setCancelToken(cancelToken, genId: _genId);
    if (cancelToken.isCancelled) {
      return ChatState(
        session: saveSession ?? session,
        isGenerating: false,
        visibleStartIndex: vsi,
      );
    }
    try {
      final studioService = _ref.read(memoryStudioServiceProvider);
      final turnConfig =
          studioTurnConfig ??
          await _ref.read(studioTurnConfigResolverProvider).resolve(session.id);
      final studioConfig = turnConfig.config;
      final studioPreset = turnConfig.preset;
      studioWasActive = studioConfig != null;
      if (_isAborted()) {
        return ChatState(
          session: saveSession ?? session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
      }

      _phase(GenerationPhase.preparing);
      final builder = _ref.read(promptPayloadBuilderProvider);
      final inputs = await builder.collectGenerationContext(
        charId: _charId,
        session: session,
        apiConfigOverride: turnConfig.activeApiConfig,
        guidanceText: guidanceText,
        continueInstruction: continueTargetId == null
            ? null
            : kContinueInstruction,
        includeEffectiveCanon: turnConfig.enabled,
        excludeSnapshotMessageId: regenTargetId,
        shouldAbort: _isAborted,
        cancelToken: cancelToken,
        onPhase: _phase,
      );
      if (_isAborted()) {
        return ChatState(
          session: saveSession ?? session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
      }
      final apiConfig = inputs.apiConfig;

      final pipelineSettings = turnConfig.pipelineSettings;
      final studioFinalContextSize =
          studioConfig == null || studioPreset == null
          ? 0
          : pipelineSettings.studioAgent.studioFinalContextSize > 0
          ? pipelineSettings.studioAgent.studioFinalContextSize
          : studioPreset.maxFinalHistoryMessages;
      final studioFinalVisibleMessageIds = studioConfig == null
          ? const <String>{}
          : StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
              inputs.history,
              studioFinalContextSize,
              reasoningHistoryCount:
                  pipelineSettings.studioAgent.studioFinalReasoningHistoryCount,
              excludeReasoningFromContextBudget: pipelineSettings
                  .studioAgent
                  .studioFinalExcludeReasoningFromContextBudget,
              historyWindowStartMessageId: inputs
                  .sessionVars[StudioHistoryLimiter.historyWindowStartVar],
            );
      _phase(GenerationPhase.prompt);
      final payload = studioConfig == null
          ? await builder.buildOrdinaryFromGenerationContext(
              inputs,
              shouldAbort: _isAborted,
            )
          : PromptPayload.fromGenerationContext(
              inputs,
              preset: null,
              ledgerPromptInjectionPolicy:
                  turnConfig.ledgerPromptInjectionPolicy,
              consumerPath: 'studio-saved',
            );
      final finalPayload = studioConfig == null
          ? payload
          : PromptPayload.fromGenerationContext(
              inputs,
              preset: null,
              sourceWindowVisibleMessageIds: studioFinalVisibleMessageIds,
              ledgerPromptInjectionPolicy:
                  turnConfig.ledgerPromptInjectionPolicy,
              consumerPath: 'studio-final',
            );
      final finalStudioContext = studioConfig == null
          ? null
          : const StudioContextPreparer().prepare(
              inputs: inputs,
              visibleMessageIds: studioFinalVisibleMessageIds,
              ledgerPromptInjectionPolicy:
                  turnConfig.ledgerPromptInjectionPolicy,
              consumerPath: 'studio-final',
              reasoningTagStartOverride:
                  studioPreset?.runtime.reasoningTagStart,
              reasoningTagEndOverride: studioPreset?.runtime.reasoningTagEnd,
              studioPreset: studioPreset,
            );
      final promptResult = studioConfig == null
          ? await buildPromptInIsolate(finalPayload)
          : _studioCompatibilityResult(finalStudioContext!);
      if (_isAborted()) {
        return ChatState(
          session: saveSession ?? session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
      }
      _ref.read(cachedTokenBreakdownProvider(_charId).notifier).state =
          promptResult.breakdown;

      // A stepped trim anchors on the oldest message it kept. Persisting that
      // id is the whole mechanism: next turn reuses the same anchor, so the
      // request keeps the same prefix and the provider's cache hits instead of
      // being invalidated by a cut that moved one message along.
      _persistHistoryAnchor(session, promptResult.breakdown.historyAnchorId);

      _ref.read(lastVectorLoreTokensProvider(_charId).notifier).state =
          promptResult.breakdown.vectorLoreTokens;

      Map<String, String>? pendingSessionVars;
      if (promptResult.sessionVars.isNotEmpty ||
          promptResult.globalVars.isNotEmpty) {
        pendingSessionVars = promptResult.sessionVars;
        if (promptResult.globalVars.isNotEmpty) {
          updateGlobalVarsRef(_ref, promptResult.globalVars);
        }
      }

      if (_isAborted()) {
        return ChatState(
          session: saveSession ?? session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
      }
      final preset = payload.preset;
      const defaultTagStart = '<think>';
      const defaultTagEnd = '</think>';
      final reasoningTagStart = (preset?.reasoningStart?.isNotEmpty == true)
          ? preset!.reasoningStart!
          : (apiConfig.reasoningTagStart?.isNotEmpty == true)
          ? apiConfig.reasoningTagStart!
          : defaultTagStart;
      final reasoningTagEnd = (preset?.reasoningEnd?.isNotEmpty == true)
          ? preset!.reasoningEnd!
          : (apiConfig.reasoningTagEnd?.isNotEmpty == true)
          ? apiConfig.reasoningTagEnd!
          : defaultTagEnd;

      final hasInlineTags =
          reasoningTagStart.isNotEmpty && reasoningTagEnd.isNotEmpty;

      final apiMessages = buildApiMessages(
        promptResult.messages,
        reasoningHistoryCount: apiConfig.reasoningHistoryCount,
      );
      final previousApiMessages = _lastRequestsBySession[session.id];
      _rememberRequest(session.id, apiMessages);
      _log(
        'base prompt ready char=$_charId session=${session.id} '
        'messages=${apiMessages.length} model=${apiConfig.model} '
        'protocol=${apiConfig.protocol}',
      );

      final coverage = promptResult.memoryCoverage.isNotEmpty
          ? promptResult.memoryCoverage
          : payload.memoryCoverage;
      final memoryDiagnostics = coverage['diagnostics'];
      final triggeredLorebooks = promptResult.triggeredLorebooks;
      final triggeredMemories = promptResult.triggeredMemories;

      if (studioConfig != null) {
        List<Map<String, dynamic>>? studioFinalMessages;
        Set<String>? studioLorebookClassifications;
        final trackerContextSize =
            pipelineSettings.studioAgent.studioControllerContextSize;
        final trackerVisibleMessageIds =
            StudioStreamInterceptor.computeStudioVisibleMessageIds(
              inputs.history,
              trackerContextSize,
            );
        final trackerStudioContext =
            setEquals(trackerVisibleMessageIds, studioFinalVisibleMessageIds)
            ? finalStudioContext!
            : const StudioContextPreparer().prepare(
                inputs: inputs,
                visibleMessageIds: trackerVisibleMessageIds,
                ledgerPromptInjectionPolicy:
                    turnConfig.ledgerPromptInjectionPolicy,
                consumerPath: 'studio-tracker',
                reasoningTagStartOverride:
                    studioPreset?.runtime.reasoningTagStart,
                reasoningTagEndOverride: studioPreset?.runtime.reasoningTagEnd,
                studioPreset: studioPreset,
              );
        if (_isAborted()) {
          return ChatState(
            session: saveSession ?? session,
            isGenerating: false,
            visibleStartIndex: vsi,
          );
        }
        _log(
          'studio intercept char=$_charId session=${session.id} '
          'agents=${studioPreset!.agents.length}',
        );
        _ref
            .read(studioCycleStateProvider.notifier)
            .state = StudioCycleState.running(
          sessionId: session.id,
          totalAgents: studioPreset.agents.length,
        );
        _phase(GenerationPhase.agents);
        final startGenTime = DateTime.now();
        DateTime? finalStartTime;
        bool studioFrameScheduled = false;
        var latestStudioText = '';
        String? latestStudioReasoning;
        // Phase reporting only ever moves forward (reasoning-only → visible
        // text), so it is derived once per transition. The early return keeps
        // the trim off the hot path once the reply has started: re-deriving
        // per chunk would scan the whole accumulated text on every delta.
        var studioReportedPhase = GenerationPhase.waiting;
        void reportStudioStreamPhase(String visibleText) {
          if (studioReportedPhase == GenerationPhase.streaming) return;
          final next = visibleText.trimLeft().isEmpty
              ? GenerationPhase.reasoning
              : GenerationPhase.streaming;
          if (next == studioReportedPhase) return;
          studioReportedPhase = next;
          _phase(next);
        }

        // Publishing is deferred to the next frame, and the pipeline clears
        // the streaming state as soon as this call returns. A callback that
        // fires after that clear leaves the finished reply in a state that is
        // meant to be empty, and the next send paints it into the typing
        // bubble — the answer the user just read, shown again under the
        // message they just sent. Closing the window flushes the text one
        // last time, synchronously, and drops anything scheduled behind it.
        var studioPublishClosed = false;
        void scheduleStudioStreamingUpdate() {
          if (studioFrameScheduled || studioPublishClosed) return;
          studioFrameScheduled = true;
          SchedulerBinding.instance.scheduleFrameCallback((_) {
            studioFrameScheduled = false;
            if (studioPublishClosed || _isAborted()) return;
            _ref
                .read(streamingStateProvider(_charId).notifier)
                .state = StreamingState(
              text: latestStudioText,
              reasoning: latestStudioReasoning,
            );
          });
        }

        void closeStudioStreamPublishing() {
          if (studioPublishClosed) return;
          studioPublishClosed = true;
          if (!studioFrameScheduled || _isAborted()) return;
          studioFrameScheduled = false;
          _ref
              .read(streamingStateProvider(_charId).notifier)
              .state = StreamingState(
            text: latestStudioText,
            reasoning: latestStudioReasoning,
          );
        }

        final studioOutputRegexes = await _ref.read(studioRegexProvider.future);
        String transformStudioOutput(String text) =>
            applyStudioOutputRegexesToText(
              text: text,
              entries: studioOutputRegexes,
              macroContext: finalStudioContext!.macroContext,
            );

        final studioResult = await studioService.runTrackerCycle(
          config: studioConfig,
          inputs: inputs,
          trackerContext: trackerStudioContext,
          finalContext: finalStudioContext!,
          apiConfig: apiConfig,
          sessionId: session.id,
          turnConfig: turnConfig,
          cancelToken: cancelToken,
          onFinalStart: () {
            if (_isAborted()) return;
            _phase(GenerationPhase.waiting);
            final cur = _ref.read(studioCycleStateProvider);
            if (cur.phase == StudioCyclePhase.running) {
              finalStartTime ??= DateTime.now();
              _ref
                  .read(studioCycleStateProvider.notifier)
                  .state = StudioCycleState.writingFinal(
                sessionId: session.id,
                totalAgents: cur.totalAgents,
                completedAgents: cur.completedAgents,
                failedAgents: cur.failedAgents,
                failedAgentNames: cur.failedAgentNames,
              );
            }
          },
          onFinalResponseUpdate: (text, reasoning) {
            if (_isAborted()) return;
            final transformedText = transformStudioOutput(text);
            latestStudioText = transformedText;
            latestStudioReasoning = reasoning;
            reportStudioStreamPhase(transformedText);
            // Phase transition is handled by onFinalStart above; here we only
            // push the streaming text to the UI. Guard against the rare case
            // where onFinalStart was not wired (e.g. older callers) so the
            // indicator still flips once tokens arrive.
            final cur = _ref.read(studioCycleStateProvider);
            if (cur.phase == StudioCyclePhase.running) {
              _ref
                  .read(studioCycleStateProvider.notifier)
                  .state = StudioCycleState.writingFinal(
                sessionId: session.id,
                totalAgents: cur.totalAgents,
                completedAgents: cur.completedAgents,
                failedAgents: cur.failedAgents,
                failedAgentNames: cur.failedAgentNames,
              );
            }
            scheduleStudioStreamingUpdate();
          },
          onFinalMessagesBuilt: (messages) {
            studioFinalMessages = messages;
          },
          onFinalLorebookClassificationsBuilt: (classifications) {
            studioLorebookClassifications = classifications;
          },
        );
        closeStudioStreamPublishing();
        if (_isAborted() || studioResult.status == 'aborted') {
          _ref.read(studioCycleStateProvider.notifier).state =
              const StudioCycleState.idle();
          return ChatState(
            session: saveSession ?? session,
            isGenerating: false,
            visibleStartIndex: vsi,
          );
        }
        if (studioResult.status != 'ok' || studioResult.response.isEmpty) {
          final message =
              studioResult.error ?? 'Studio failed: ${studioResult.status}';
          _log(
            'studio failed char=$_charId session=${session.id} '
            'status=${studioResult.status} error=$message',
          );
          _recorder.recordStudioTrackerOperation(
            sessionId: session.id,
            startGenTime: startGenTime,
            result: studioResult,
            trackerModel: _resolvedTrackerModel(apiConfig, pipelineSettings),
            finalModel: apiConfig.model,
          );
          _ref.read(studioCycleStateProvider.notifier).state =
              StudioCycleState.error(sessionId: session.id);
          if (continueTargetId != null) {
            return _continueFailure(message, session, vsi);
          }
          if (regenTargetId != null && saveSession != null) {
            return _writer.writeRegenError(
              errorText: message,
              saveSession: saveSession,
              regenTargetId: regenTargetId,
              visibleStartIndex: vsi,
            );
          }
          return _writer.writeError(
            errorText: message,
            currentSession: session,
            visibleStartIndex: vsi,
          );
        }

        final elapsed = DateTime.now().difference(startGenTime).inMilliseconds;
        _log(
          'studio write assistant char=$_charId session=${session.id} '
          'elapsedMs=$elapsed chars=${studioResult.response.length} '
          'briefs=${studioResult.stageBriefs.length}',
        );
        _ref
            .read(studioCycleStateProvider.notifier)
            .state = StudioCycleStateMapper.studioFinalState(
          session.id,
          studioResult,
          StudioCyclePhase.done,
        );
        final beautyApplied = applyBeautyState(
          transformStudioOutput(studioResult.response),
          pendingSessionVars,
        );
        final wrappedStudioText = wrapLumiaOocColors(beautyApplied.text);
        final studioPromptResult = _studioCompatibilityResult(
          finalStudioContext,
          exactLorebookManifest: _finalizeStudioLorebookManifest(
            finalStudioContext,
            studioLorebookClassifications,
            studioFinalMessages,
          ),
        );
        // Use the same clock projection that built the prompt. During regen it
        // excludes the target message's own snapshot.
        final openingClock = GameTimeState(
          time: inputs.gameTime,
          date: inputs.gameDate,
          day: int.tryParse(inputs.gameDay ?? ''),
        ).format();
        final finalState = _writer
            .writeAssistant(
              text: wrappedStudioText,
              reasoning: studioResult.reasoning.isNotEmpty
                  ? studioResult.reasoning
                  : null,
              currentSession: saveSession ?? session,
              isAborted: _isAborted,
              pendingSessionVars: beautyApplied.vars,
              genTime: '${(elapsed / 1000).toStringAsFixed(1)}s',
              tokens: estimateTokens(studioResult.response),
              time: openingClock,
              rawResponse:
                  studioResult.rawResponseJson ?? studioResult.response,
              previousSwipes: previousSwipes,
              previousSwipeId: previousSwipeId,
              previousReasoning: previousReasoning,
              previousGenTime: previousGenTime,
              previousTokens: previousTokens,
              previousSwipesMeta: previousSwipesMeta,
              guidanceText: guidanceText,
              memoryCoverage: coverage,
              isAllReasoning: false,
              triggeredLorebooks: triggeredLorebooks,
              triggeredMemories: triggeredMemories,
              regenTargetId: regenTargetId,
              visibleStartIndex: vsi,
              studioOutputs: StudioStreamInterceptor.studioOutputsToJson(
                studioResult.stageBriefs,
              ),
            )
            .copyWith(
              promptPayload: finalPayload,
              mainModelContextSnapshot: studioFinalMessages == null
                  ? null
                  : MainModelContextSnapshot(
                      providerMessages: studioFinalMessages!,
                      promptResult: studioPromptResult,
                      promptPayload: finalPayload,
                      isStudioFinalWriter: true,
                    ),
            );
        _recordModelUsage(apiConfig.model);
        final messageId = _lastAssistantId(finalState.session!, regenTargetId);
        _bindTurnCaptures(session.id, messageId, turnStartedAtMs);
        _recorder.recordStudioTrackerOperation(
          sessionId: session.id,
          messageId: messageId,
          startGenTime: startGenTime,
          finalStartTime: finalStartTime,
          result: studioResult,
          trackerModel: _resolvedTrackerModel(apiConfig, pipelineSettings),
          finalModel: apiConfig.model,
        );
        if (memoryDiagnostics is Map<String, dynamic> &&
            finalState.session != null) {
          final memoryMessageId = _lastAssistantId(
            finalState.session!,
            regenTargetId,
          );
          _ref
              .read(lastMemoryActivityProvider(_charId).notifier)
              .state = MemoryActivityState(
            sessionId: finalState.session!.id,
            messageId: memoryMessageId,
            diagnostics: Map<String, dynamic>.from(memoryDiagnostics),
            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
          );
          _recorder.recordMemoryAgentOperation(
            finalState.session!.id,
            memoryMessageId,
            memoryDiagnostics,
          );
        } else {
          _ref.read(lastMemoryActivityProvider(_charId).notifier).state = null;
        }
        if (finalState.session != null) {
          unawaited(
            _ref
                .read(memoryPostTurnServiceProvider)
                .runPostTurn(finalState.session!.id),
          );
        }
        return finalState;
      }

      _log('studio not active char=$_charId session=${session.id}');

      final accumulator = StreamAccumulator(
        tagStart: reasoningTagStart,
        tagEnd: reasoningTagEnd,
        hasInlineTags: hasInlineTags,
        headerModel: 'reasoning_model'.tr(),
        headerInline: 'reasoning_inline'.tr(),
      );

      final startGenTime = DateTime.now();
      final transport = pickChatTransport(apiConfig.protocol);
      ChatState? finalState;

      bool frameScheduled = false;
      // See the Studio branch above for why the deferred publish has to be
      // closed: a frame callback that lands after the pipeline cleared the
      // streaming state resurrects the finished reply into the next send's
      // typing bubble.
      var streamPublishClosed = false;
      void publishStreamedText() {
        _ref
            .read(streamingStateProvider(_charId).notifier)
            .state = StreamingState(
          text: accumulator.text.trimLeft(),
          reasoning: accumulator.reasoning.isNotEmpty
              ? accumulator.reasoning
              : null,
        );
      }

      void closeStreamPublishing() {
        if (streamPublishClosed) return;
        streamPublishClosed = true;
        if (!frameScheduled || _isAborted()) return;
        frameScheduled = false;
        publishStreamedText();
      }

      // See the Studio branch above: one report per transition, never a
      // per-chunk re-derivation over the accumulated text.
      var reportedPhase = GenerationPhase.waiting;
      void reportStreamPhase() {
        if (reportedPhase == GenerationPhase.streaming) return;
        // Cheap while the reply is still empty, and never reached once the
        // first visible character has landed.
        final next = accumulator.text.trimLeft().isEmpty
            ? GenerationPhase.reasoning
            : GenerationPhase.streaming;
        if (next == reportedPhase) return;
        reportedPhase = next;
        _phase(next);
      }

      // Idle timeout: cancel the timer on the first chunk (text OR reasoning)
      // so a long (but progressing) generation is never cut off. Mirrors
      // AgentStreamRunner and AuxLlmClient patterns.
      final idleTimeoutMs = apiConfig.firstChunkTimeoutMs > 0
          ? apiConfig.firstChunkTimeoutMs
          : 60000;
      bool idleTimedOut = false;
      final idleGuard = IdleTimeoutGuard(idleTimeoutMs, () {
        idleTimedOut = true;
        cancelToken.cancel('First-chunk timeout after ${idleTimeoutMs}ms');
      });

      _phase(GenerationPhase.waiting);
      await transport.stream(
        request: ChatTransportRequest.fromApiConfig(
          apiConfig,
          messages: apiMessages,
          sessionId: session.id,
          previousMessages: previousApiMessages,
          charName: inputs.character.name,
          userName: inputs.persona?.name ?? 'User',
          // Without this the main request — the one that writes the reply —
          // was the only call in the app captured with no session and no
          // stage, so it landed in the session-less bucket and no per-chat
          // view could ever show it. The assistant message does not exist
          // yet, so the turn is identified by the generation id and bound to
          // its message id once the write lands (`bindTurnMessageId`).
          captureContext: LlmCaptureContext(
            stage: 'main',
            sessionId: session.id,
            messageId: regenTargetId ?? continueTargetId,
            pipelineRunId: turnRunId(session.id, _genId),
          ),
        ),
        cancelToken: cancelToken,
        onUpdate: (delta, reasoningDelta) {
          if (_isAborted()) return;
          if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
            idleGuard.cancel();
          }
          accumulator.consumeDelta(delta, reasoningDelta: reasoningDelta);
          // Reasoning-only output keeps the typing bubble on screen (the
          // visible text is still empty), so name that phase for what it is.
          reportStreamPhase();
          if (!frameScheduled && !streamPublishClosed) {
            frameScheduled = true;
            SchedulerBinding.instance.scheduleFrameCallback((_) {
              frameScheduled = false;
              if (streamPublishClosed || _isAborted()) return;
              publishStreamedText();
            });
          }
        },
        onComplete: (text, reasoning, {rawResponseJson}) {
          if (_isAborted()) return;
          closeStreamPublishing();
          idleGuard.dispose();
          if (!apiConfig.stream &&
              accumulator.text.isEmpty &&
              accumulator.reasoning.isEmpty &&
              (text.isNotEmpty ||
                  (reasoning != null && reasoning.isNotEmpty))) {
            accumulator.consumeDelta(text, reasoningDelta: reasoning);
          }
          var finalText = accumulator.text.trimLeft();
          var finalReasoning = accumulator.reasoning.isNotEmpty
              ? accumulator.reasoning
              : reasoning;

          finalText = _writer.sanitizeReasoningMarkers(
            finalText,
            reasoningTagStart,
            reasoningTagEnd,
          );
          if (finalReasoning != null && finalReasoning.isNotEmpty) {
            finalReasoning = _writer.sanitizeReasoningMarkers(
              finalReasoning,
              reasoningTagStart,
              reasoningTagEnd,
            );
          }

          final beautyApplied = applyBeautyState(finalText, pendingSessionVars);
          finalText = wrapLumiaOocColors(beautyApplied.text);
          pendingSessionVars = beautyApplied.vars;

          final isAllReasoning =
              finalText.isEmpty &&
              finalReasoning != null &&
              finalReasoning.isNotEmpty;
          final elapsed = DateTime.now()
              .difference(startGenTime)
              .inMilliseconds;
          final timeStr = '${(elapsed / 1000).toStringAsFixed(1)}s';
          final tokenCount = estimateTokens(finalText);
          finalState = _writer
              .writeAssistant(
                text: finalText,
                reasoning: finalReasoning,
                currentSession: saveSession ?? session,
                isAborted: _isAborted,
                pendingSessionVars: pendingSessionVars,
                genTime: timeStr,
                tokens: tokenCount,
                rawResponse: rawResponseJson ?? text,
                previousSwipes: previousSwipes,
                previousSwipeId: previousSwipeId,
                previousReasoning: previousReasoning,
                previousGenTime: previousGenTime,
                previousTokens: previousTokens,
                previousSwipesMeta: previousSwipesMeta,
                guidanceText: guidanceText,
                memoryCoverage: coverage,
                isAllReasoning: isAllReasoning,
                triggeredLorebooks: triggeredLorebooks,
                triggeredMemories: triggeredMemories,
                regenTargetId: regenTargetId,
                visibleStartIndex: vsi,
              )
              .copyWith(
                promptPayload: payload,
                mainModelContextSnapshot: MainModelContextSnapshot(
                  providerMessages: apiMessages,
                  promptResult: promptResult,
                  promptPayload: payload,
                  isStudioFinalWriter: false,
                ),
              );
          _recordModelUsage(apiConfig.model);
          _bindTurnCaptures(
            session.id,
            finalState?.session == null
                ? null
                : _lastAssistantId(finalState!.session!, regenTargetId),
            turnStartedAtMs,
          );
          if (memoryDiagnostics is Map<String, dynamic> &&
              finalState?.session != null) {
            final messageId = _lastAssistantId(
              finalState!.session!,
              regenTargetId,
            );
            _ref
                .read(lastMemoryActivityProvider(_charId).notifier)
                .state = MemoryActivityState(
              sessionId: finalState!.session!.id,
              messageId: messageId,
              diagnostics: Map<String, dynamic>.from(memoryDiagnostics),
              updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            );
            _recorder.recordMemoryAgentOperation(
              finalState!.session!.id,
              messageId,
              memoryDiagnostics,
            );
          } else {
            _ref.read(lastMemoryActivityProvider(_charId).notifier).state =
                null;
          }
          // Post-turn memory pipeline (Phase G4): fire-and-forget.
          // Does NOT block generation or user interaction.
          if (finalState?.session != null) {
            unawaited(
              _ref
                  .read(memoryPostTurnServiceProvider)
                  .runPostTurn(finalState!.session!.id),
            );
          }
        },
        onError: (error) {
          closeStreamPublishing();
          idleGuard.dispose();
          if (idleTimedOut) {
            final msg = 'error_first_chunk_timeout'.tr(
              namedArgs: {'seconds': '${idleTimeoutMs ~/ 1000}'},
            );
            if (continueTargetId != null) {
              finalState = _continueFailure(msg, session, vsi);
            } else if (regenTargetId != null && saveSession != null) {
              finalState = _writer.writeRegenError(
                errorText: msg,
                saveSession: saveSession,
                regenTargetId: regenTargetId,
                visibleStartIndex: vsi,
              );
            } else {
              finalState = _writer.writeError(
                errorText: msg,
                currentSession: session,
                visibleStartIndex: vsi,
              );
            }
            return;
          }
          final isCancelled =
              (error is DioException &&
                  error.type == DioExceptionType.cancel) ||
              cancelToken.isCancelled ||
              _isAborted();
          if (isCancelled) {
            finalState = ChatState(
              session: session,
              isGenerating: false,
              visibleStartIndex: vsi,
            );
          } else if (continueTargetId != null) {
            finalState = _continueFailure(formatError(error), session, vsi);
          } else if (regenTargetId != null && saveSession != null) {
            finalState = _writer.writeRegenError(
              errorText: formatError(error),
              saveSession: saveSession,
              regenTargetId: regenTargetId,
              visibleStartIndex: vsi,
            );
          } else {
            finalState = _writer.writeError(
              errorText: formatError(error),
              currentSession: session,
              visibleStartIndex: vsi,
            );
          }
        },
      );
      // Neither callback is guaranteed on every transport path; the window
      // must be shut before the pipeline clears the streaming state.
      closeStreamPublishing();

      return finalState ??
          ChatState(
            session: session,
            isGenerating: false,
            visibleStartIndex: vsi,
          );
    } catch (e) {
      // When the final generator throws (e.g. HTTP 400), the exception
      // propagates through runTrackerCycle without resetting the Studio
      // cycle state — which was set to writingFinal by onFinalStart. Without
      // this reset the StudioStatusCard stays visible forever with a spinner.
      if (_isAborted()) {
        return ChatState(
          session: session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
      }
      if (studioWasActive) {
        _ref.read(studioCycleStateProvider.notifier).state =
            StudioCycleState.error(sessionId: session.id);
      }
      if (continueTargetId != null) {
        return _continueFailure(formatError(e), session, vsi);
      }
      if (regenTargetId != null && saveSession != null) {
        return _writer.writeRegenError(
          errorText: formatError(e),
          saveSession: saveSession,
          regenTargetId: regenTargetId,
          visibleStartIndex: vsi,
        );
      }
      return _writer.writeError(
        errorText: formatError(e),
        currentSession: session,
        visibleStartIndex: vsi,
      );
    }
  }

  /// Continue mode failure: settle the run without touching the session.
  /// A failed continuation must leave the message it was extending exactly as
  /// the user saw it — no error swipe, no appended error bubble — so the only
  /// surface is the `Continue Failed` toast driven off [ChatState.error].
  /// See `docs/INVARIANTS.md` INV-CM4.
  ChatState _continueFailure(String errorText, ChatSession session, int vsi) {
    return ChatState(
      session: session,
      isGenerating: false,
      error: errorText,
      visibleStartIndex: vsi,
    );
  }

  PromptResult _studioCompatibilityResult(
    StudioContext context, {
    ExactLorebookManifest? exactLorebookManifest,
  }) {
    final messages = <PromptMessage>[
      ...context.staticContext,
      ...context.dynamicContext,
      ...context.history,
    ];
    return PromptResult(
      messages: messages,
      breakdown: TokenBreakdown(
        sourceTokens: const {},
        staticTotal: 0,
        historyBudget: 0,
        historyTokens: 0,
        totalTokens: 0,
        cutoffIndex: 0,
        trimmedHistory: context.history,
        vectorLoreTokens: context.diagnostics.vectorLoreTokens,
        visibleMessageIds: context.diagnostics.visibleMessageIds,
      ),
      sessionVars: context.sessionVars,
      globalVars: context.globalVars,
      triggeredLorebooks: context.diagnostics.triggeredLorebooks,
      triggeredMemories: context.diagnostics.triggeredMemories,
      memoryCoverage: context.diagnostics.memoryCoverage,
      exactLorebookManifest: exactLorebookManifest,
    );
  }

  ExactLorebookManifest? _finalizeStudioLorebookManifest(
    StudioContext context,
    Set<String>? classifications,
    List<Map<String, dynamic>>? providerMessages,
  ) {
    final manifest = context.diagnostics.exactLorebookManifest;
    if (manifest == null ||
        classifications == null ||
        providerMessages == null) {
      return null;
    }
    return manifest
        .confirmedForClassifications(classifications)
        .withProviderMessagesHash(computeHash(jsonEncode(providerMessages)));
  }

  static void _rememberRequest(
    String sessionId,
    List<Map<String, dynamic>> messages,
  ) {
    _lastRequestsBySession[sessionId] = messages
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
    if (_lastRequestsBySession.length > 64) {
      _lastRequestsBySession.remove(_lastRequestsBySession.keys.first);
    }
  }

  /// Facade for test compatibility — tests call
  /// StreamGenerationService.computeStudioFinalVisibleMessageIds.
  @visibleForTesting
  static Set<String> computeStudioFinalVisibleMessageIds(
    List<ChatMessage> history,
    int finalContextSize, {
    int reasoningHistoryCount = 0,
    bool excludeReasoningFromContextBudget = false,
    String? historyWindowStartMessageId,
  }) => StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
    history,
    finalContextSize,
    reasoningHistoryCount: reasoningHistoryCount,
    excludeReasoningFromContextBudget: excludeReasoningFromContextBudget,
    historyWindowStartMessageId: historyWindowStartMessageId,
  );

  /// Ties this turn's generation-phase captures to the message they produced.
  /// Fire-and-forget: a diagnostics link must never delay or fail a turn.
  void _bindTurnCaptures(String sessionId, String? messageId, int sinceMs) {
    if (messageId == null || messageId.isEmpty) return;
    unawaited(
      _ref
          .read(llmRequestCaptureRepoProvider)
          .bindTurnMessageId(
            sessionId: sessionId,
            messageId: messageId,
            sinceMs: sinceMs,
          ),
    );
  }

  static String? _lastAssistantId(ChatSession session, String? regenTargetId) {
    if (regenTargetId != null &&
        session.messages.any((m) => m.id == regenTargetId)) {
      return regenTargetId;
    }
    for (final message in session.messages.reversed) {
      if (message.role == 'assistant') return message.id;
    }
    return null;
  }

  static void _log(String message) {
    debugPrint('[StudioGen] $message');
  }

  /// Record one successful generation against [model] for the global "Top
  /// Models" statistics. Fire-and-forget: a stats-counter write must never
  /// block or fail the generation flow.
  void _recordModelUsage(String model) {
    unawaited(_ref.read(modelUsageServiceProvider).recordModelUse(model));
  }

  String _resolvedTrackerModel(
    ApiConfig apiConfig,
    PipelineSettings pipelineSettings,
  ) {
    final override = pipelineSettings.studioAgent.studioControllerModelOverride;
    return override.isNotEmpty ? override : apiConfig.model;
  }

  /// Stores the history anchor a stepped trim settled on, when it moved.
  ///
  /// Fire-and-forget and change-guarded: it must never delay a generation, and
  /// the anchor holds still for many turns, so the common case writes nothing.
  /// Failure is survivable — the next turn simply re-anchors.
  void _persistHistoryAnchor(ChatSession session, String? anchorId) {
    final current = session.sessionVars[ChatSessionX.historyAnchorVarKey];
    final next = (anchorId == null || anchorId.isEmpty) ? null : anchorId;
    if (current == next) return;
    unawaited(
      _ref
          .read(chatRepoProvider)
          .updateSessionVarsJson(session.id, (vars) {
            final updated = Map<String, dynamic>.from(vars);
            if (next == null) {
              updated.remove(ChatSessionX.historyAnchorVarKey);
            } else {
              updated[ChatSessionX.historyAnchorVarKey] = next;
            }
            return updated;
          })
          .catchError((Object e) {
            debugPrint('[history-anchor] persist failed: $e');
            return <String, dynamic>{};
          }),
    );
  }
}
