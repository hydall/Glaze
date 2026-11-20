import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/agents/agent_batch.dart';
import '../../../../core/llm/agents/agent_call_runner.dart';
import '../../../../core/llm/aux_llm_client.dart';
import '../../../../core/llm/agents/agent_prompt_builder.dart';
import '../../../../core/llm/agents/agent_turn_plan.dart';
import '../../../../core/llm/concurrency_limiter.dart';
import '../../../../core/llm/generation_context_inputs.dart';
import '../../../../core/llm/macro_engine.dart';
import '../../../../core/llm/post_gen_engine_config.dart';
import '../../../../core/llm/prompt/runtime_prompt_block.dart';
import '../../../../core/models/agent_binding.dart';
import '../../../../core/models/agent_definition.dart';
import '../../../../core/models/agent_run.dart';
import '../../../../core/models/api_config.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/pipeline_settings.dart';
import '../../../../core/models/preset.dart';
import '../../../../core/state/agent_providers.dart';
import '../../../../core/state/db_provider.dart';
import '../../../settings/api_list_provider.dart';

/// Runs the agents of one turn around the ordinary reply.
///
/// * [planFor] resolves which agents run (library + bindings + the chat's own
///   off switch + cadence) — once per turn.
/// * [runBeforeReply] runs the pre-generation agents in waves and returns the
///   runtime prompt blocks their results become; parallel agents' answers from
///   earlier turns are added here too.
/// * [startParallel] runs the parallel agents beside the main stream.
/// * [engineConfigFor] turns the post agents into the [PostGenEngineConfig]
///   Post Clean and the Tracker run on.
class AgentTurnService {
  final Ref _ref;
  final AgentCallRunner _runner;

  AgentTurnService(this._ref, {this._runner = const AgentCallRunner()});

  /// The plan for the reply after [history] in [session].
  Future<AgentTurnPlan> planFor({
    required String charId,
    required ChatSession session,
    required List<ChatMessage> history,
  }) async {
    if (agentsOffInSession(session.sessionVars)) return AgentTurnPlan.empty;
    try {
      final library = await _ref.read(agentLibraryProvider.future);
      if (library.isEmpty) return AgentTurnPlan.empty;
      final bindings = await _ref.read(agentBindingRepoProvider).getAll();
      final enabled = agentsEnabledFor(
        library,
        bindings,
        charId: charId,
        sessionId: session.id,
      );
      return AgentTurnPlan.build(enabled: enabled, history: history);
    } catch (error) {
      debugPrint('[Agents] plan failed, running without agents: $error');
      return AgentTurnPlan.empty;
    }
  }

  /// Runs the pre-generation agents and returns the blocks to add to the main
  /// prompt. [anchorMessageId] is the last message before the reply; runs are
  /// recorded against it, and parallel answers recorded against it (on a
  /// regeneration they came after the reply being replaced) are not reused.
  Future<List<RuntimePromptBlock>> runBeforeReply({
    required AgentTurnPlan plan,
    required GenerationContextInputs inputs,
    required String sessionId,
    required String anchorMessageId,
    required CancelToken cancelToken,
    required bool Function() isAborted,
  }) async {
    final outputs = <String, String>{};
    final blocks = <RuntimePromptBlock>[];

    if (plan.parallel.isNotEmpty) {
      final previous = await _ref
          .read(agentRunRepoProvider)
          .latestOutputs(
            sessionId,
            plan.parallel.map((agent) => agent.id),
            excludingMessageId: anchorMessageId,
          );
      for (final agent in plan.parallel) {
        final text = previous[agent.id];
        if (text == null || text.trim().isEmpty) continue;
        outputs[agent.id] = text;
        blocks.addAll(injectionBlocksFor(agent, text));
      }
    }

    for (final wave in plan.preGenerationWaves) {
      if (isAborted()) return blocks;
      final results = await _runAgents(
        wave,
        inputs: inputs,
        sessionId: sessionId,
        messageId: anchorMessageId,
        outputs: outputs,
        cancelToken: cancelToken,
      );
      for (final result in results) {
        if (!result.ok) continue;
        outputs[result.agent.id] = result.output;
        blocks.addAll(injectionBlocksFor(result.agent, result.output));
      }
    }
    return blocks;
  }

  /// Runs the parallel agents beside the reply. Their answers are recorded
  /// and reach the main prompt on the next turn. Stop cancels them through
  /// [cancelToken].
  void startParallel({
    required AgentTurnPlan plan,
    required GenerationContextInputs inputs,
    required String sessionId,
    required String anchorMessageId,
    required CancelToken cancelToken,
  }) {
    if (plan.parallel.isEmpty) return;
    unawaited(
      _runAgents(
        plan.parallel,
        inputs: inputs,
        sessionId: sessionId,
        messageId: anchorMessageId,
        outputs: const {},
        cancelToken: cancelToken,
      ).catchError((Object error) {
        debugPrint('[Agents] parallel run failed: $error');
        return <AgentCallResult>[];
      }),
    );
  }

  Future<List<AgentCallResult>> _runAgents(
    List<AgentDefinition> agents, {
    required GenerationContextInputs inputs,
    required String sessionId,
    required String messageId,
    required Map<String, String> outputs,
    required CancelToken cancelToken,
  }) async {
    final pipeline = _ref.read(pipelineSettingsProvider);
    final apiConfigs = await _apiConfigs();
    final macroContext = macroContextFor(inputs, outputs);
    final limit = pipeline.agents.maxConcurrent < 1
        ? 1
        : pipeline.agents.maxConcurrent;
    AuxApiConfig configFor(AgentDefinition agent) => resolveAgentApiConfig(
      agent: agent,
      apiConfigs: apiConfigs,
      chatConfig: inputs.apiConfig,
      settings: pipeline.agents,
    );

    Future<AgentCallResult> runAlone(AgentDefinition agent) async {
      final AgentCallResult result;
      try {
        result = await _runner.run(
          agent: agent,
          messages: const AgentPromptBuilder().build(
            agent: agent,
            macroContext: macroContext,
            history: inputs.history,
          ),
          config: configFor(agent),
          fallbackTemperature: inputs.apiConfig.temperature,
          cancelToken: cancelToken,
          sessionId: sessionId,
          messageId: messageId,
        );
      } catch (error) {
        return _record(
          AgentCallResult(agent: agent, ok: false, error: '$error'),
          sessionId: sessionId,
          messageId: messageId,
        );
      }
      if (cancelToken.isCancelled) return result;
      return _record(result, sessionId: sessionId, messageId: messageId);
    }

    // Agents on the same connection and model share one request; a lone agent,
    // or one whose answer the batch lost, runs on its own.
    final groups = groupForBatching(agents, (agent) {
      try {
        final config = configFor(agent);
        return '${config.protocol}|${config.endpoint}|${config.model}';
      } catch (_) {
        return 'unresolved:${agent.id}';
      }
    });
    final perGroup =
        await ConcurrencyLimiter.settle<
          List<AgentDefinition>,
          List<AgentCallResult>
        >(
          items: groups,
          limit: limit,
          run: (group) async {
            if (group.length == 1) return [await runAlone(group.single)];
            Map<String, AgentCallResult> batched;
            try {
              batched = await _runner.runBatch(
                agents: group,
                messages: buildBatchMessages(
                  agents: group,
                  macroContext: macroContext,
                  history: inputs.history,
                ),
                config: configFor(group.first),
                fallbackTemperature: inputs.apiConfig.temperature,
                cancelToken: cancelToken,
                sessionId: sessionId,
                messageId: messageId,
              );
            } catch (_) {
              batched = const {};
            }
            final results = <AgentCallResult>[];
            for (final agent in group) {
              if (cancelToken.isCancelled) break;
              final answer = batched[agent.id];
              results.add(
                answer == null
                    ? await runAlone(agent)
                    : await _record(
                        answer,
                        sessionId: sessionId,
                        messageId: messageId,
                      ),
              );
            }
            return results;
          },
        );
    final byId = {
      for (final results in perGroup)
        for (final result in results) result.agent.id: result,
    };
    return [
      for (final agent in agents)
        if (byId[agent.id] != null) byId[agent.id]!,
    ];
  }

  Future<AgentCallResult> _record(
    AgentCallResult result, {
    required String sessionId,
    required String messageId,
  }) async {
    try {
      await _ref
          .read(agentRunRepoProvider)
          .insert(
            AgentRun(
              sessionId: sessionId,
              messageId: messageId,
              agentId: result.agent.id,
              agentName: result.agent.displayName,
              phase: result.agent.phase,
              resultType: result.agent.resultType,
              ok: result.ok,
              error: result.error,
              output: result.output,
              promptJson: result.promptJson,
              promptTokens: result.promptTokens,
              completionTokens: result.completionTokens,
              durationMs: result.durationMs,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
    } catch (error) {
      debugPrint('[Agents] run log write failed: $error');
    }
    return result;
  }

  Future<List<ApiConfig>> _apiConfigs() async {
    try {
      await _ref.read(apiListProvider.future);
    } catch (_) {}
    return _ref.read(apiListProvider).value ?? const <ApiConfig>[];
  }

  /// The settings Post Clean and the Tracker run on this turn, or null when
  /// neither runs.
  Future<PostGenEngineConfig?> engineConfigFor(AgentTurnPlan plan) async {
    final rewrite = plan.firstOfType(AgentResultType.textRewrite);
    final tracker = plan.firstOfType(AgentResultType.ledgerUpdate);
    final cardRewriter = plan.firstOfType(AgentResultType.cardUpdateProposal);
    if (rewrite == null && tracker == null) return null;
    return buildEngineConfig(
      rewrite: rewrite,
      tracker: tracker,
      cardRewriter: cardRewriter,
      pipelineSettings: _ref.read(pipelineSettingsProvider),
      apiConfigs: await _apiConfigs(),
      activeApiConfig: _ref.read(activeApiConfigProvider),
    );
  }
}

/// Folds the post agents into the engine config: Post Clean (or a user agent
/// on its engine) drives the cleaner, the Tracker the Ledger, and Card
/// Rewriter's presence switches its lane on.
PostGenEngineConfig buildEngineConfig({
  required AgentDefinition? rewrite,
  required AgentDefinition? tracker,
  required AgentDefinition? cardRewriter,
  required PipelineSettings pipelineSettings,
  required List<ApiConfig> apiConfigs,
  required ApiConfig? activeApiConfig,
}) {
  var pipeline = pipelineSettings.copyWith(
    cardRewriter: pipelineSettings.cardRewriter.copyWith(
      enabled: cardRewriter != null,
    ),
  );
  if (rewrite != null) {
    pipeline = pipeline.copyWith(
      cleaner: pipeline.cleaner.copyWith(
        postCleanerEnabled: true,
        postCleanerModel: _modelFor(rewrite, pipeline),
        postCleanerTemperature:
            rewrite.params.temperature ??
            pipeline.cleaner.postCleanerTemperature,
        postCleanerMaxTokens:
            rewrite.params.maxTokens ?? pipeline.cleaner.postCleanerMaxTokens,
        postCleanerTimeoutMs:
            rewrite.params.timeoutMs ?? pipeline.cleaner.postCleanerTimeoutMs,
      ),
    );
  }
  if (tracker != null) {
    pipeline = pipeline.copyWith(
      ledger: pipeline.ledger.copyWith(
        studioLedgerModel: _modelFor(tracker, pipeline),
        studioLedgerTemperature:
            tracker.params.temperature ??
            pipeline.ledger.studioLedgerTemperature,
        studioLedgerMaxTokens:
            tracker.params.maxTokens ?? pipeline.ledger.studioLedgerMaxTokens,
        studioLedgerTimeoutMs:
            tracker.params.timeoutMs ?? pipeline.ledger.studioLedgerTimeoutMs,
      ),
    );
  }
  final broadcast = rewrite?.settings['broadcastBlocks'];
  return PostGenEngineConfig(
    pipelineSettings: pipeline,
    apiConfigs: apiConfigs,
    activeApiConfig: activeApiConfig,
    cleanerEnabled: rewrite != null,
    ledgerEnabled: tracker != null,
    cleanerBlocks: rewrite?.activeBlocks ?? const <PresetBlock>[],
    ledgerBlocks: tracker?.activeBlocks ?? const <PresetBlock>[],
    broadcastBlocks: broadcast is List
        ? [for (final item in broadcast) '$item']
        : const <String>[],
    cleanerApiConfigId: rewrite == null
        ? ''
        : _connectionIdFor(rewrite, pipeline),
    // The Tracker on the chat's own connection must not fall back to the
    // cleaner's: name the active connection explicitly then.
    ledgerApiConfigId: tracker == null
        ? ''
        : (_connectionIdFor(tracker, pipeline).isNotEmpty
              ? _connectionIdFor(tracker, pipeline)
              : (activeApiConfig?.id ?? '')),
  );
}

String _connectionIdFor(AgentDefinition agent, PipelineSettings pipeline) =>
    switch (agent.connection.mode) {
      AgentConnectionMode.helper => pipeline.agents.helperApiConfigId,
      AgentConnectionMode.config => agent.connection.apiConfigId,
      _ => '',
    };

String _modelFor(AgentDefinition agent, PipelineSettings pipeline) {
  if (agent.connection.model.isNotEmpty) return agent.connection.model;
  if (agent.connection.mode == AgentConnectionMode.helper) {
    return pipeline.agents.helperModel;
  }
  return '';
}

/// The runtime prompt blocks a `context_injection` [output] becomes: always
/// the `{{agent::id}}` value, plus a placed block unless the agent is
/// macro-only.
List<RuntimePromptBlock> injectionBlocksFor(
  AgentDefinition agent,
  String output,
) {
  if (agent.resultType != AgentResultType.contextInjection) return const [];
  final text = output.trim();
  if (text.isEmpty) return const [];
  final macro = RuntimePromptBlock(
    id: agentMacroKey(agent.id),
    content: text,
    depth: 0,
    role: 'system',
    placement: RuntimePromptPlacement.macro,
  );
  final placement = switch (agent.injection.placement) {
    AgentPlacement.beforeMain => RuntimePromptPlacement.beforeMain,
    AgentPlacement.afterMain => RuntimePromptPlacement.afterMain,
    AgentPlacement.macroOnly => null,
    _ => RuntimePromptPlacement.depth,
  };
  if (placement == null) return [macro];
  return [
    macro,
    RuntimePromptBlock(
      id: 'agent_inject:${agent.id}',
      content: '<${_tagName(agent)}>\n$text\n</${_tagName(agent)}>',
      depth: agent.injection.depth < 0 ? 0 : agent.injection.depth,
      role: agent.injection.role,
      placement: placement,
    ),
  ];
}

String _tagName(AgentDefinition agent) {
  final slug = agent.displayName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'agent_note' : slug;
}

/// The macro context an agent's prompt resolves against: the character,
/// persona and chat of the turn, plus the results already produced
/// (`{{agent::id}}`).
MacroContext macroContextFor(
  GenerationContextInputs inputs,
  Map<String, String> outputs,
) => MacroContext(
  charName: inputs.character.name,
  charDescription: inputs.character.description,
  charScenario: inputs.character.scenario,
  charPersonality: inputs.character.personality,
  charMesExample: inputs.character.mesExample,
  userName: inputs.persona?.name ?? 'User',
  personaPrompt: inputs.persona?.prompt,
  sessionVars: inputs.sessionVars,
  globalVars: inputs.globalVars,
  charId: inputs.character.id,
  sessionId: inputs.sessionId ?? '',
  summaryContent: inputs.summaryContent,
  memoryContent: inputs.memoryContent,
  macroName: inputs.character.macroName,
  arcContent: inputs.arcContent,
  entitiesContent: inputs.entitiesContent,
  studioSessionState: inputs.studioSessionStateContent,
  gameTime: inputs.gameTime,
  gameDate: inputs.gameDate,
  gameDay: inputs.gameDay,
  extBlocks: {
    for (final entry in outputs.entries) agentMacroKey(entry.key): entry.value,
  },
);

final agentTurnServiceProvider = Provider<AgentTurnService>(
  (ref) => AgentTurnService(ref),
);

/// The plan of the turn in flight, per chat, so the post-generation stage runs
/// exactly the agents the turn started with.
class AgentTurnRegistry {
  final Map<String, (int, AgentTurnPlan)> _plans = {};

  void put(String charId, int genId, AgentTurnPlan plan) =>
      _plans[charId] = (genId, plan);

  /// The plan recorded for [genId], or [AgentTurnPlan.empty].
  AgentTurnPlan take(String charId, int genId) {
    final entry = _plans[charId];
    if (entry == null || entry.$1 != genId) return AgentTurnPlan.empty;
    _plans.remove(charId);
    return entry.$2;
  }
}

final agentTurnRegistryProvider = Provider<AgentTurnRegistry>(
  (ref) => AgentTurnRegistry(),
);
