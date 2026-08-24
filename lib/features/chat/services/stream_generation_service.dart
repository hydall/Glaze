import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../../core/llm/beauty_state_parser.dart';
import '../../../core/llm/idle_timeout_guard.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/utils/error_format.dart';
import '../../../core/utils/cast_helpers.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../core/state/studio_turn_config_resolver.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/services/model_usage_service.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../chat_provider.dart';
import '../chat_state.dart';
import '../providers/prompt_build_providers.dart';
import '../state/cached_token_breakdown.dart';
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
    required ChatState currentState,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    final vsi = currentState.visibleStartIndex;
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

      final builder = _ref.read(promptPayloadBuilderProvider);
      final inputs = await builder.collectGenerationContext(
        charId: _charId,
        session: session,
        apiConfigOverride: turnConfig.activeApiConfig,
        guidanceText: guidanceText,
        includeEffectiveCanon: turnConfig.enabled,
        shouldAbort: _isAborted,
        cancelToken: cancelToken,
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
        final startGenTime = DateTime.now();
        DateTime? finalStartTime;
        bool studioFrameScheduled = false;
        var latestStudioText = '';
        String? latestStudioReasoning;
        void scheduleStudioStreamingUpdate() {
          if (studioFrameScheduled) return;
          studioFrameScheduled = true;
          SchedulerBinding.instance.scheduleFrameCallback((_) {
            studioFrameScheduled = false;
            if (_isAborted()) return;
            _ref
                .read(streamingStateProvider(_charId).notifier)
                .state = StreamingState(
              text: latestStudioText,
              reasoning: latestStudioReasoning,
            );
          });
        }

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
            latestStudioText = text;
            latestStudioReasoning = reasoning;
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
          studioResult.response,
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

      await transport.stream(
        request: ChatTransportRequest.fromApiConfig(
          apiConfig,
          messages: apiMessages,
          sessionId: session.id,
          previousMessages: previousApiMessages,
          charName: inputs.character.name,
          userName: inputs.persona?.name ?? 'User',
        ),
        cancelToken: cancelToken,
        onUpdate: (delta, reasoningDelta) {
          if (_isAborted()) return;
          if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
            idleGuard.cancel();
          }
          accumulator.consumeDelta(delta, reasoningDelta: reasoningDelta);
          if (!frameScheduled) {
            frameScheduled = true;
            SchedulerBinding.instance.scheduleFrameCallback((_) {
              frameScheduled = false;
              if (_isAborted()) return;
              _ref
                  .read(streamingStateProvider(_charId).notifier)
                  .state = StreamingState(
                text: accumulator.text.trimLeft(),
                reasoning: accumulator.reasoning.isNotEmpty
                    ? accumulator.reasoning
                    : null,
              );
            });
          }
        },
        onComplete: (text, reasoning, {rawResponseJson}) {
          if (_isAborted()) return;
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
          idleGuard.dispose();
          if (idleTimedOut) {
            final msg = 'error_first_chunk_timeout'.tr(
              namedArgs: {'seconds': '${idleTimeoutMs ~/ 1000}'},
            );
            if (regenTargetId != null && saveSession != null) {
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
}
