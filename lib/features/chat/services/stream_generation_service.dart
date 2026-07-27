import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/history_assembler.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../../../core/llm/prompt_payload_builder.dart';
import '../../../core/llm/studio/studio_stream_interceptor.dart';
import '../../../core/llm/stream_accumulator.dart';
import '../../../core/llm/beauty_state_parser.dart';
import '../../../core/llm/idle_timeout_guard.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/utils/error_format.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/api_config.dart';
import '../../../core/services/model_usage_service.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../../core/state/pipeline_settings_provider.dart';
import '../chat_provider.dart';
import '../chat_state.dart';
import '../state/cached_token_breakdown.dart';
import '../state/memory_activity_provider.dart';
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
      final studioConfig = await studioService.getEnabledConfig(session.id);
      studioWasActive = studioConfig != null;
      if (_isAborted()) {
        return ChatState(
          session: saveSession ?? session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
      }

      final builder = _ref.read(promptPayloadBuilderProvider);
      final payload = await builder.buildFromSession(
        charId: _charId,
        session: session,
        guidanceText: guidanceText,
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
      final apiConfig = payload.apiConfig;

      final pipelineSettings = _ref.read(pipelineSettingsProvider);
      final studioFinalContextSize = studioConfig == null
          ? 0
          : pipelineSettings.studioAgent.studioFinalContextSize > 0
          ? pipelineSettings.studioAgent.studioFinalContextSize
          : studioConfig.maxFinalHistoryMessages;
      final studioFinalVisibleMessageIds = studioConfig == null
          ? const <String>{}
          : StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
              payload.history,
              studioFinalContextSize,
            );
      final finalPayload = studioConfig != null
          ? StudioStreamInterceptor.payloadWithSourceWindow(
              payload,
              studioFinalVisibleMessageIds,
            )
          : payload;

      final promptResult = await buildPromptInIsolate(finalPayload);
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
        includeLastReasoning: apiConfig.includeLastReasoning,
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
        final trackerContextSize =
            pipelineSettings.studioAgent.studioTrackerContextSize;
        final trackerVisibleMessageIds =
            StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
              payload.history,
              trackerContextSize,
            );
        final trackerPayload = StudioStreamInterceptor.payloadWithSourceWindow(
          payload,
          trackerVisibleMessageIds,
        );
        final trackerPromptResult =
            setEquals(trackerVisibleMessageIds, studioFinalVisibleMessageIds)
            ? promptResult
            : await buildPromptInIsolate(trackerPayload);
        if (_isAborted()) {
          return ChatState(
            session: saveSession ?? session,
            isGenerating: false,
            visibleStartIndex: vsi,
          );
        }
        _log(
          'studio intercept char=$_charId session=${session.id} '
          'agents=${studioConfig.agents.length}',
        );
        _ref
            .read(studioCycleStateProvider.notifier)
            .state = StudioCycleState.running(
          sessionId: session.id,
          totalAgents: studioConfig.agents.length,
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
          promptResult: trackerPromptResult,
          promptPayload: trackerPayload,
          finalPromptResult: promptResult,
          finalPromptPayload: finalPayload,
          apiConfig: apiConfig,
          sessionId: session.id,
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
            trackerModel: _resolvedTrackerModel(apiConfig),
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
            .state = StudioStreamInterceptor.studioFinalState(
          session.id,
          studioResult,
          StudioCyclePhase.done,
        );
        final beautyApplied = applyBeautyState(
          studioResult.response,
          pendingSessionVars,
        );
        final wrappedStudioText = wrapLumiaOocColors(beautyApplied.text);
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
            .copyWith(promptPayload: finalPayload);
        _recordModelUsage(apiConfig.model);
        final messageId = _lastAssistantId(finalState.session!, regenTargetId);
        _recorder.recordStudioTrackerOperation(
          sessionId: session.id,
          messageId: messageId,
          startGenTime: startGenTime,
          finalStartTime: finalStartTime,
          result: studioResult,
          trackerModel: _resolvedTrackerModel(apiConfig),
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
        request: ChatTransportRequest(
          endpoint: apiConfig.endpoint,
          apiKey: apiConfig.apiKey,
          model: apiConfig.model,
          messages: apiMessages,
          maxTokens: apiConfig.maxTokens,
          temperature: apiConfig.temperature,
          topP: apiConfig.topP,
          topK: apiConfig.topK,
          frequencyPenalty: apiConfig.frequencyPenalty,
          presencePenalty: apiConfig.presencePenalty,
          stream: apiConfig.stream,
          requestReasoning: apiConfig.requestReasoning,
          reasoningEffort: apiConfig.reasoningEffort,
          omitTemperature: apiConfig.omitTemperature,
          omitTopP: apiConfig.omitTopP,
          omitTopK: apiConfig.omitTopK,
          omitFrequencyPenalty: apiConfig.omitFrequencyPenalty,
          omitPresencePenalty: apiConfig.omitPresencePenalty,
          omitReasoning: apiConfig.omitReasoning,
          omitReasoningEffort: apiConfig.omitReasoningEffort,
          showNativeReasoning: apiConfig.showNativeReasoning,
          sessionId: session.id,
          previousMessages: previousApiMessages,
          cacheControlTtl: apiConfig.cacheControlTtl,
          cacheBreakpointMode: apiConfig.cacheBreakpointMode,
          sessionIdMode: apiConfig.sessionIdMode,
          extraRequestParameters: apiConfig.extraRequestParameters,
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
              .copyWith(promptPayload: payload);
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
    int finalContextSize,
  ) => StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
    history,
    finalContextSize,
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

  String _resolvedTrackerModel(ApiConfig apiConfig) {
    final override = _ref
        .read(pipelineSettingsProvider)
        .studioAgent
        .studioTrackerModelOverride;
    return override.isNotEmpty ? override : apiConfig.model;
  }
}
