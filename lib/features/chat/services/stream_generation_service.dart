import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/generation_phase.dart';
import '../../../core/llm/converters/no_assistant.dart';
import '../../../core/llm/history_assembler.dart';
import '../../../core/llm/history_trim.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../core/llm/prompt/prompt_build_stale_exception.dart';
import '../../../core/llm/context_calculator.dart';
import '../../../core/llm/stream_accumulator.dart';
import '../../../core/llm/beauty_state_parser.dart';
import '../../../core/llm/idle_timeout_guard.dart';
import '../../../core/llm/output_limit.dart';
import '../../../core/llm/tools/llm_tool_call.dart';
import '../../../core/llm/transport/call_attempt_outcome.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/llm_call_event.dart';
import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/utils/error_format.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/api_config.dart';
import '../../../core/services/model_usage_service.dart';
import '../../../core/services/preset_defaults.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../settings/api_list_provider.dart';
import '../chat_provider.dart';
import '../chat_state.dart';
import '../providers/prompt_build_providers.dart';
import '../state/cached_token_breakdown.dart';
import '../state/generation_phase_provider.dart';
import '../state/memory_activity_provider.dart';
import 'memory_agent_recorder.dart';
import 'agents/agent_turn_service.dart';
import '../../../core/llm/agents/agent_turn_plan.dart';
import '../../../core/llm/prompt/runtime_prompt_block.dart';
import 'saved_message_writer.dart';
import '../../../core/plugins/plugin_hooks.dart';
import '../../model_tools/character_tool_sheet.dart';
import '../../model_tools/model_tool.dart';
import '../../model_tools/model_tool_runner.dart';

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

  Future<ChatSession> _applyPluginPrepare(
    ChatSession session, {
    required String source,
  }) async {
    final hooks = _ref.read(pluginHookRegistryProvider).forChat(_charId);
    if (hooks == null) return session;
    final index = session.messages.lastIndexWhere((m) => m.role == 'user');
    if (index < 0) return session;
    final original = session.messages[index];
    final String rewritten;
    try {
      rewritten = await hooks.prepareGeneration(
        original.content,
        source: source,
        generationId: '$_charId:$_genId',
      );
    } catch (e) {
      debugPrint('[StreamGen] plugin generation:prepare failed: $e');
      return session;
    }
    if (rewritten == original.content) return session;
    final messages = [...session.messages];
    messages[index] = original.copyWith(content: rewritten);
    return session.copyWith(messages: messages);
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
    String guidanceType = 'GENERATION',
    String? regenTargetId,
    String? continueTargetId,
    required ChatState currentState,
  }) async {
    final vsi = currentState.visibleStartIndex;
    // Everything captured from here on belongs to this turn (see
    // `bindTurnMessageId`).
    final turnStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    final cancelToken = CancelToken();
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
      if (_isAborted()) {
        return ChatState(
          session: saveSession ?? session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
      }

      _phase(GenerationPhase.preparing);
      // Plugins may rewrite the latest user text for this request only
      // (`generation:prepare`). The copy feeds the prompt; `session` itself —
      // which the error and cancel paths save — keeps the stored text.
      final promptSession = await _applyPluginPrepare(
        session,
        source: continueTargetId != null
            ? 'continuation'
            : regenTargetId != null
            ? 'regeneration'
            : 'reply',
      );
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
        session: promptSession,
        apiConfigOverride: _ref.read(activeApiConfigProvider),
        guidanceText: guidanceText,
        continueInstruction: continueTargetId == null
            ? null
            : kContinueInstruction,
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

      // Agents: one plan per turn. A continuation extends the reply it
      // continues and runs no agents.
      final agentService = _ref.read(agentTurnServiceProvider);
      final agentPlan = continueTargetId != null
          ? AgentTurnPlan.empty
          : await agentService.planFor(
              charId: _charId,
              session: session,
              history: inputs.history,
            );
      _ref.read(agentTurnRegistryProvider).put(_charId, _genId, agentPlan);
      final agentAnchorId = inputs.history.lastOrNull?.id ?? '';
      var agentBlocks = const <RuntimePromptBlock>[];
      if (agentPlan.preGenerationWaves.isNotEmpty ||
          agentPlan.parallel.isNotEmpty) {
        if (agentPlan.preGenerationWaves.isNotEmpty) {
          _phase(GenerationPhase.agents);
        }
        agentBlocks = await agentService.runBeforeReply(
          plan: agentPlan,
          inputs: inputs,
          sessionId: session.id,
          anchorMessageId: agentAnchorId,
          cancelToken: cancelToken,
          isAborted: _isAborted,
        );
        if (_isAborted()) {
          return ChatState(
            session: saveSession ?? session,
            isGenerating: false,
            visibleStartIndex: vsi,
          );
        }
      }
      _phase(GenerationPhase.prompt);
      final payload = (await builder.buildOrdinaryFromGenerationContext(
        inputs,
        shouldAbort: _isAborted,
      )).withExtraRuntimePromptBlocks(agentBlocks);
      // Parallel agents start beside the reply; Stop cancels them with it.
      agentService.startParallel(
        plan: agentPlan,
        inputs: inputs,
        sessionId: session.id,
        anchorMessageId: agentAnchorId,
        cancelToken: cancelToken,
      );
      final promptResult = await buildPromptInIsolate(payload);
      await builder.ensureMemoryEntriesCurrent(
        sessionId: session.id,
        selection: inputs.memorySelection,
        triggered: promptResult.triggeredMemories,
      );
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
      _persistHistoryAnchor(
        session: session,
        breakdown: promptResult.breakdown,
        history: inputs.history,
        historyTrimMode: apiConfig.historyTrimMode,
      );

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

      final noAssistant = NoAssistantOptions.of(
        preset,
        charName: inputs.character.name,
        userName: inputs.persona?.name ?? 'User',
      );
      final apiMessages = buildApiMessages(
        promptResult.messages,
        reasoningHistoryCount: apiConfig.reasoningHistoryCount,
        noAssistant: noAssistant,
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
      // Publishing is deferred to the next frame, and the pipeline clears the
      // streaming state as soon as this call returns. A frame callback that
      // lands after that clear resurrects the finished reply into the next
      // send's typing bubble, so closing the window flushes the text one last
      // time, synchronously, and drops anything scheduled behind it.
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

      // Phase reporting only ever moves forward (reasoning-only → visible
      // text): one report per transition, never a per-chunk re-derivation
      // over the accumulated text.
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

      await builder.ensureMemoryEntriesCurrent(
        sessionId: session.id,
        selection: inputs.memorySelection,
        triggered: promptResult.triggeredMemories,
      );
      if (_isAborted()) {
        throw const PromptBuildStaleException('Generation cancelled.');
      }

      // What every field of this is for is documented on the factory. The
      // turn's message id is bound over it once the write lands
      // (`bindTurnMessageId`), which is why an ordinary turn passes none.
      final captureContext = mainCaptureContext(
        sessionId: session.id,
        genId: _genId,
        startedAtMs: startGenTime.millisecondsSinceEpoch,
        messageId: regenTargetId ?? continueTargetId,
      );

      // Tools (`lib/features/model_tools/`) run between rounds of one reply: a
      // round that ends in calls is answered with their results and the
      // conversation goes out again, until the model answers in text. A
      // continuation extends a finished reply and never offers them.
      final toolset = continueTargetId == null
          ? ModelToolset.forConfig(apiConfig)
          : const ModelToolset([]);
      var requestMessages = apiMessages;
      var round = 1;
      late ChatTransportRequest request;
      while (true) {
        // Each round is one call of its own in the request inspector.
        final roundContext = captureContext.withAttempt(round);
        LlmToolTurn? toolTurn;
        var toolRoundText = '';
        // Whether this round streamed anything, rather than whether the reply
        // has text: an earlier tool round may already have filled it.
        var roundGotDeltas = false;
        // When this round's first chunk arrived, for the outcome log line: it
        // tells a server that never answered from one that stalled mid-reply.
        int? firstChunkMs;

        // Idle timeout: cancel the timer on the first chunk (text OR reasoning)
        // so a long (but progressing) generation is never cut off. Mirrors
        // AgentStreamRunner and AuxLlmClient patterns.
        final idleTimeoutMs = apiConfig.effectiveFirstChunkTimeoutMs;
        bool idleTimedOut = false;
        final idleGuard = IdleTimeoutGuard(idleTimeoutMs, () {
          idleTimedOut = true;
          cancelToken.cancel('First-chunk timeout after ${idleTimeoutMs}ms');
        });

        // One outcome per call. `onComplete` and `onError` are not exclusive on
        // every transport — an aborted stream can reach both — and the table is
        // keyed on `callId + attempt`, so a second write would collide with the
        // first rather than adding to it.
        var outcomeRecorded = false;
        void recordOutcome({String? responseText, Object? error}) {
          if (outcomeRecorded) return;
          outcomeRecorded = true;
          unawaited(
            LlmCallEventCapture.record(
              LlmCallEvent.transport(
                context: roundContext,
                attempt: describeCallAttempt(
                  attempt: round,
                  startedAtMs: startGenTime.millisecondsSinceEpoch,
                  elapsedMs: DateTime.now()
                      .difference(startGenTime)
                      .inMilliseconds,
                  error: error,
                ),
                responseText: responseText,
              ),
            ),
          );
        }

        request = ChatTransportRequest.fromApiConfig(
          apiConfig,
          messages: requestMessages,
          sessionId: session.id,
          receiveTimeoutMs: apiConfig.transportReceiveTimeoutMs,
          previousMessages: previousApiMessages,
          charName: inputs.character.name,
          userName: inputs.persona?.name ?? 'User',
          stop: noAssistant?.stop ?? const [],
          tools: toolset.isEmpty ? null : toolset.definitions,
          // The last allowed round still carries the definitions — Anthropic
          // rejects `tool_use` history without them — but may not call.
          toolChoice: toolset.isEmpty
              ? null
              : round < kMaxToolRounds
              ? 'auto'
              : 'none',
          captureContext: roundContext,
        );
        reportedPhase = GenerationPhase.waiting;
        _phase(GenerationPhase.waiting);
        await transport.stream(
          request: request,
          cancelToken: cancelToken,
          onUpdate: (delta, reasoningDelta) {
            if (_isAborted()) return;
            if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
              idleGuard.cancel();
              roundGotDeltas = true;
              firstChunkMs ??= DateTime.now()
                  .difference(startGenTime)
                  .inMilliseconds;
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
            final turn = toolset.isEmpty || round >= kMaxToolRounds
                ? null
                : parseToolTurn(rawResponseJson);
            if (turn != null) {
              // Not the end of the reply: publishing stays open for the next
              // round, and nothing is written yet.
              idleGuard.dispose();
              recordOutcome(responseText: rawResponseJson ?? text);
              if (!roundGotDeltas) {
                accumulator.consumeDelta(text, reasoningDelta: reasoning);
              }
              toolTurn = turn;
              toolRoundText = text;
              return;
            }
            closeStreamPublishing();
            idleGuard.dispose();
            // The raw body when the transport kept one: the Response tab
            // pretty-prints it and reads the assistant text back out of it, so
            // the payload is worth more there than the assembled text alone.
            recordOutcome(responseText: rawResponseJson ?? text);
            if (!apiConfig.stream &&
                !roundGotDeltas &&
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

            final beautyApplied = applyBeautyState(
              finalText,
              pendingSessionVars,
            );
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
            _log(
              'generation done char=$_charId session=${session.id} '
              'round=$round host=${_endpointHost(apiConfig.endpoint)} '
              'elapsedMs=$elapsed firstChunkMs=${firstChunkMs ?? '-'} '
              'chars=${finalText.length}',
            );
            // Read off what the model produced, before the reasoning markers
            // and beauty-state blocks were stripped: all of it counted against
            // the cap.
            final outputLimitHit = hitOutputTokenLimit(
              text: accumulator.text,
              reasoning: accumulator.reasoning.isNotEmpty
                  ? accumulator.reasoning
                  : reasoning,
              rawResponse: rawResponseJson,
              maxTokens: request.maxTokens,
            );
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
                  guidanceType: guidanceType,
                  memoryCoverage: coverage,
                  isAllReasoning: isAllReasoning,
                  triggeredLorebooks: triggeredLorebooks,
                  triggeredMemories: triggeredMemories,
                  regenTargetId: regenTargetId,
                  visibleStartIndex: vsi,
                  outputLimitHit: outputLimitHit,
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
            _log(
              'generation failed char=$_charId session=${session.id} '
              'round=$round host=${_endpointHost(apiConfig.endpoint)} '
              'elapsedMs=${DateTime.now().difference(startGenTime).inMilliseconds} '
              'firstChunkMs=${firstChunkMs ?? '-'} '
              'error=${idleTimedOut ? 'firstChunkTimeout(${idleTimeoutMs}ms)' : describeErrorForLog(error)}',
            );
            if (idleTimedOut) {
              final msg = 'error_first_chunk_timeout'.tr(
                namedArgs: {'seconds': '${idleTimeoutMs ~/ 1000}'},
              );
              // A first-chunk timeout reaches here as the cancel it was
              // implemented as. Record it as the timeout the reader saw, so the
              // inspector does not file it under "you stopped it".
              recordOutcome(
                error: TimeoutException(
                  msg,
                  Duration(milliseconds: idleTimeoutMs),
                ),
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
            recordOutcome(error: error);
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
        final turn = toolTurn;
        if (turn == null || _isAborted()) break;

        _phase(GenerationPhase.tools);
        final results = await toolset.run(
          turn,
          ModelToolContext(
            ref: _ref,
            charId: _charId,
            isAborted: _isAborted,
            confirm: showCharacterProposalSheet,
          ),
        );
        if (_isAborted()) break;
        _log(
          'tool round char=$_charId session=${session.id} round=$round '
          'calls=${turn.calls.map((c) => c.name).join(',')}',
        );
        // A trailing assistant prefill is folded into the round that answered
        // it; sending both would put two assistant turns back to back.
        final base =
            requestMessages.isNotEmpty &&
                requestMessages.last['role'] == 'assistant'
            ? requestMessages.sublist(0, requestMessages.length - 1)
            : requestMessages;
        requestMessages = [
          ...base,
          ...toolFollowUpMessages(
            assistantText: toolRoundText,
            turn: turn,
            results: results,
          ),
        ];
        if (accumulator.text.trim().isNotEmpty) {
          accumulator.consumeDelta('\n\n');
        }
        round++;
      }
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
      if (_isAborted()) {
        return ChatState(
          session: session,
          isGenerating: false,
          visibleStartIndex: vsi,
        );
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
    debugPrint('[StreamGen] $message');
  }

  /// Only the host: the path and query of a custom endpoint can carry a key.
  static String _endpointHost(String endpoint) {
    final host = Uri.tryParse(endpoint.trim())?.host ?? '';
    return host.isEmpty ? '?' : host;
  }

  /// Record one successful generation against [model] for the global "Top
  /// Models" statistics. Fire-and-forget: a stats-counter write must never
  /// block or fail the generation flow.
  void _recordModelUsage(String model) {
    unawaited(_ref.read(modelUsageServiceProvider).recordModelUse(model));
  }

  /// Stores the history anchor a stepped trim settled on, when it moved, and
  /// raises the amber "trimmed" toast for the block the move dropped.
  ///
  /// The reader's pin rides along: it stays while the trim held the pinned
  /// anchor, and goes once the trim had to step past it.
  ///
  /// Fire-and-forget and change-guarded: it must never delay a generation, and
  /// the anchor holds still for many turns, so the common case writes nothing.
  /// Failure is survivable — the next turn simply re-anchors.
  void _persistHistoryAnchor({
    required ChatSession session,
    required TokenBreakdown breakdown,
    required List<ChatMessage> history,
    required String historyTrimMode,
  }) {
    final normalizedCurrent = session.historyAnchorId;
    final currentPinned = session.historyAnchorPinned;
    final next = breakdown.historyAnchorId;
    final normalizedNext = (next == null || next.isEmpty) ? null : next;
    final nextPinned = normalizedNext != null && breakdown.historyAnchorPinned;
    if (normalizedCurrent == normalizedNext && currentPinned == nextPinned) {
      return;
    }
    unawaited(
      _ref
          .read(chatRepoProvider)
          .updateSessionVarsJson(session.id, (vars) {
            final updated = Map<String, dynamic>.from(vars);
            if (normalizedNext == null) {
              updated.remove(ChatSessionX.historyAnchorVarKey);
            } else {
              updated[ChatSessionX.historyAnchorVarKey] = normalizedNext;
            }
            if (nextPinned) {
              updated[ChatSessionX.historyAnchorPinnedVarKey] = '1';
            } else {
              updated.remove(ChatSessionX.historyAnchorPinnedVarKey);
            }
            return updated;
          })
          .catchError((Object e) {
            debugPrint('[history-anchor] persist failed: $e');
            return <String, dynamic>{};
          }),
    );

    // Only the stepped mode holds an anchor, so only a stepped trim is worth a
    // notice. `historyAnchorId` is already null under sliding.
    if (historyTrimMode == HistoryTrimMode.stepped && normalizedNext != null) {
      _toastHistoryTrim(history, normalizedCurrent, normalizedNext);
    }
  }

  /// Reports one stepped trim in an amber toast: how many messages it dropped
  /// and what they were worth in tokens.
  ///
  /// A missing previous anchor (the first stepped trim after switching modes)
  /// counts from the start of the history. A stored anchor the open chat no
  /// longer has (the message was deleted) reports nothing rather than a number
  /// read off the wrong list.
  void _toastHistoryTrim(
    List<ChatMessage> history,
    String? currentId,
    String newId,
  ) {
    final newIndex = history.indexWhere((m) => m.id == newId);
    if (newIndex < 0) return;
    final oldIndex = currentId == null
        ? 0
        : history.indexWhere((m) => m.id == currentId);
    if (currentId != null && oldIndex < 0) return;
    final from = oldIndex < 0 ? 0 : oldIndex;
    final dropped = newIndex - from;
    if (dropped <= 0) return;

    var droppedTokens = 0;
    for (var i = from; i < newIndex; i++) {
      droppedTokens += estimateTokens(history[i].content);
    }
    GlazeToast.warningWithoutContext(
      'history_trim_toast'.plural(
        dropped,
        namedArgs: {'tokens': '$droppedTokens'},
      ),
    );
  }
}
