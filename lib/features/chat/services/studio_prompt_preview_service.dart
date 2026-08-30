import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/agent_runner.dart';
import '../../../core/llm/agent_stream_runner.dart';
import '../../../core/llm/controller_batcher.dart';
import '../../../core/llm/generation_context_inputs.dart';
import '../../../core/llm/studio/studio_context.dart';
import '../../../core/llm/studio/studio_context_preparer.dart';
import '../../../core/llm/studio/studio_history_limiter.dart';
import '../../../core/llm/studio/studio_stream_interceptor.dart';
import '../../../core/llm/studio_activation_gate.dart';
import '../../../core/llm/studio_brief_deduper.dart';
import '../../../core/llm/studio_brief_parser.dart';
import '../../../core/llm/studio_message_builder.dart';
import '../../../core/llm/studio_prompt_text.dart';
import '../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/llm_request_capture.dart';
import '../../../core/llm/transport/post_processing_chat_transport.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../../core/state/studio_regex_provider.dart';
import '../../../core/state/studio_turn_config_resolver.dart';
import '../chat_provider.dart';
import '../providers/prompt_build_providers.dart';
import '../../settings/api_list_provider.dart';

enum StudioPromptPreviewStage {
  controller,
  controllerBatch,
  finalWriter,
  postProcessor,
  cleanerAudit,
  cleanerRewrite,
  ledgerTurn,
  ledgerRepair,
  reconciliation,
  reconciliationRepair,
  collector,
  consolidation,
  cardWriter,
  cardWriterRepair,
  lorebookWriter,
}

enum StudioPromptPreviewUnavailableReason {
  studioInactive,
  noTransportRequest,
  controllerOutputsRequired,
  finalResponseRequired,
  auditOutputRequired,
  malformedOutputRequired,
  pureBuilderUnavailable,
  claimSafeSelectionRequired,
  upstreamOutputRequired,
  configurationUnavailable,
}

final class StudioPromptPreviewEntry {
  StudioPromptPreviewEntry({
    required this.id,
    required this.stage,
    required this.title,
    required this.isFuture,
    required List<Map<String, dynamic>> messages,
    required Map<String, String> metadata,
    Map<String, dynamic>? rawRequest,
    this.unavailableReason,
    this.agentId,
  }) : messages = List.unmodifiable(
         messages.map((message) => Map<String, dynamic>.unmodifiable(message)),
       ),
       metadata = Map.unmodifiable(metadata),
       rawRequest = rawRequest == null ? null : Map.unmodifiable(rawRequest);

  final String id;
  final StudioPromptPreviewStage stage;
  final String title;
  final bool isFuture;
  final String? agentId;
  final List<Map<String, dynamic>> messages;
  final Map<String, String> metadata;
  final Map<String, dynamic>? rawRequest;
  final StudioPromptPreviewUnavailableReason? unavailableReason;

  bool get isAvailable => unavailableReason == null;

  String get formattedRawRequest => rawRequest == null
      ? ''
      : const JsonEncoder.withIndent('  ').convert(rawRequest);
}

final class StudioPromptPreviewCatalog {
  StudioPromptPreviewCatalog({
    required this.sessionId,
    required this.presetId,
    required this.generatedAt,
    required List<StudioPromptPreviewEntry> entries,
  }) : entries = List.unmodifiable(entries);

  final String sessionId;
  final String presetId;
  final DateTime generatedAt;
  final List<StudioPromptPreviewEntry> entries;
}

typedef StudioPreviewSessionReader = ChatSession? Function();
typedef StudioPreviewTurnResolver =
    Future<StudioTurnConfigSnapshot> Function(String sessionId);
typedef StudioPreviewContextCollector =
    Future<GenerationContextInputs> Function(
      ChatSession session,
      StudioTurnConfigSnapshot turnConfig,
    );
typedef StudioPreviewAgentConfigResolver =
    Future<ResolvedAgentConfig> Function({
      required StudioAgent agent,
      required GenerationContextInputs inputs,
      required StudioTurnConfigSnapshot turnConfig,
      required bool isFinal,
      required String apiConfigId,
    });
typedef StudioPreviewControllerGrouper =
    Future<ControllerGrouping> Function({
      required List<StudioAgent> agents,
      required GenerationContextInputs inputs,
      required StudioTurnConfigSnapshot turnConfig,
      required String apiConfigId,
    });
typedef StudioPreviewRequestConfigResolver =
    ResolvedAgentConfig Function({
      required StudioAgent agent,
      required ResolvedAgentConfig resolved,
      required bool isFinal,
      required StudioTurnConfigSnapshot turnConfig,
    });
typedef StudioPreviewMaxTokensResolver =
    int? Function({
      required StudioAgent agent,
      required bool isFinal,
      required StudioTurnConfigSnapshot turnConfig,
    });
typedef StudioPreviewTemperatureResolver =
    double? Function({
      required StudioAgent agent,
      required bool isFinal,
      required StudioTurnConfigSnapshot turnConfig,
    });
typedef StudioPreviewPostProcessor =
    ChatTransportRequest Function(ChatTransportRequest request);

/// Builds a read-only CURRENT/FUTURE catalog. It never executes a transport or
/// asks mutating pipeline services to select work, acquire leases, or persist.
final class StudioPromptPreviewService {
  const StudioPromptPreviewService({
    required this.readSession,
    required this.resolveTurnConfig,
    required this.collectContext,
    required this.resolveAgentConfig,
    required this.groupControllers,
    required this.controllerBatcher,
    required this.effectiveRequestConfig,
    required this.effectiveMaxTokens,
    required this.effectiveTemperature,
    this.postProcessRequest = _identityRequest,
    required this.messageBuilder,
    this.now,
  });

  final StudioPreviewSessionReader readSession;
  final StudioPreviewTurnResolver resolveTurnConfig;
  final StudioPreviewContextCollector collectContext;
  final StudioPreviewAgentConfigResolver resolveAgentConfig;
  final StudioPreviewControllerGrouper groupControllers;
  final ControllerBatcher controllerBatcher;
  final StudioPreviewRequestConfigResolver effectiveRequestConfig;
  final StudioPreviewMaxTokensResolver effectiveMaxTokens;
  final StudioPreviewTemperatureResolver effectiveTemperature;
  final StudioPreviewPostProcessor postProcessRequest;
  final StudioMessageBuilder messageBuilder;
  final DateTime Function()? now;

  Future<StudioPromptPreviewCatalog> load() async {
    final session = readSession();
    if (session == null) throw StateError('Open a chat to preview Studio.');
    final turnConfig = await resolveTurnConfig(session.id);
    final config = turnConfig.config;
    final preset = turnConfig.preset;
    if (config == null || preset == null) {
      return StudioPromptPreviewCatalog(
        sessionId: session.id,
        presetId: '',
        generatedAt: (now ?? DateTime.now)(),
        entries: [
          _unavailable(
            id: 'studio.final',
            stage: StudioPromptPreviewStage.finalWriter,
            title: 'Main Writer',
            reason: StudioPromptPreviewUnavailableReason.studioInactive,
          ),
          _unavailable(
            id: 'studio.post_processing',
            stage: StudioPromptPreviewStage.postProcessor,
            title: 'Studio post-processor',
            reason: StudioPromptPreviewUnavailableReason.studioInactive,
          ),
          ..._standardUnavailableEntries(
            StudioPromptPreviewUnavailableReason.studioInactive,
          ),
        ],
      );
    }

    final inputs = await collectContext(session, turnConfig);
    _requireSessionCurrent(session);

    final settings = turnConfig.pipelineSettings.studioAgent;
    final finalContextSize = settings.studioFinalContextSize > 0
        ? settings.studioFinalContextSize
        : preset.maxFinalHistoryMessages;
    final finalVisibleIds =
        StudioStreamInterceptor.computeStudioFinalVisibleMessageIds(
          inputs.history,
          finalContextSize,
          reasoningHistoryCount: settings.studioFinalReasoningHistoryCount,
          excludeReasoningFromContextBudget:
              settings.studioFinalExcludeReasoningFromContextBudget,
          historyWindowStartMessageId:
              inputs.sessionVars[StudioHistoryLimiter.historyWindowStartVar],
        );
    final trackerVisibleIds =
        StudioStreamInterceptor.computeStudioVisibleMessageIds(
          inputs.history,
          settings.studioControllerContextSize,
        );
    final finalContext = _prepareContext(
      inputs,
      finalVisibleIds,
      turnConfig,
      preset,
      'studio-final',
    );
    final trackerContext =
        trackerVisibleIds.length == finalVisibleIds.length &&
            trackerVisibleIds.containsAll(finalVisibleIds)
        ? finalContext
        : _prepareContext(
            inputs,
            trackerVisibleIds,
            turnConfig,
            preset,
            'studio-tracker',
          );

    final agents = preset.agents.where((agent) => agent.enabled).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final split = StudioActivationGate.splitAgentsByPhase(agents);
    final entries = <StudioPromptPreviewEntry>[];
    final grouping = await groupControllers(
      agents: split.preGenTrackers,
      inputs: inputs,
      turnConfig: turnConfig,
      apiConfigId: preset.cheapApiConfigId,
    );
    final batchGroups = <ControllerBatchGroup>[
      for (final group in grouping.batchGroups)
        ...controllerBatcher.splitGroupForParallelJobs(group),
    ];
    for (var index = 0; index < batchGroups.length; index++) {
      final group = batchGroups[index];
      final sharedMessages = messageBuilder.buildSharedBatchMessages(
        context: trackerContext,
        batchContextSize: group.batchContextSize,
      );
      final perAgentTask = <String, String>{
        for (final agent in group.agents)
          agent.id: messageBuilder.buildPerAgentTaskText(
            agent: agent,
            config: config,
            studioPreset: preset,
            context: trackerContext,
          ),
      };
      final systemPrompt = controllerBatcher.buildBatchSystemPrompt(
        group: group,
        sharedMessages: sharedMessages,
        perAgentTaskText: perAgentTask,
        roleText: messageBuilder.batchRoleText(config, preset, trackerContext),
      );
      final messages = messageBuilder.applyRegexesForStages(
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {
            'role': 'user',
            'content':
                'Produce the required <result> blocks now, one per agent_task '
                'listed above, in order.',
          },
        ],
        stages: const {'pregen', 'specificAgent'},
        context: trackerContext,
      );
      entries.add(
        _available(
          id: 'controller-batch:${group.key}:$index',
          stage: StudioPromptPreviewStage.controllerBatch,
          title: group.agents.map((agent) => agent.name).join(', '),
          agent: group.agents.first,
          resolved: group.resolved,
          messages: messages,
          session: session,
          inputs: inputs,
          preset: preset,
          turnConfig: turnConfig,
          detail:
              'Current planned batch request. Production may omit controllers '
              'whose current brief cache entry is still valid.',
          maxTokensOverride: group.batchMaxTokens,
          temperatureOverride: group.batchTemperature,
        ),
      );
    }
    for (final agent in grouping.individualAgents) {
      final controllerConfig = await resolveAgentConfig(
        agent: agent,
        inputs: inputs,
        turnConfig: turnConfig,
        isFinal: false,
        apiConfigId: preset.cheapApiConfigId,
      );
      final messages = messageBuilder.buildAgentMessages(
        agent: agent,
        context: trackerContext,
        config: config,
        studioPreset: preset,
        priorBriefs: const [],
        isFinalResponse: false,
        trackerContextOverride: settings.studioControllerContextSize,
      );
      entries.add(
        _available(
          id: 'controller:${agent.id}',
          stage: StudioPromptPreviewStage.controller,
          title: agent.name,
          agent: agent,
          resolved: controllerConfig,
          messages: messages,
          session: session,
          inputs: inputs,
          preset: preset,
          turnConfig: turnConfig,
          detail:
              'Current planned individual request. Production may omit it '
              'when the current brief cache entry is still valid.',
          maxTokensOverride: effectiveMaxTokens(
            agent: agent,
            isFinal: false,
            turnConfig: turnConfig,
          ),
          temperatureOverride: effectiveTemperature(
            agent: agent,
            isFinal: false,
            turnConfig: turnConfig,
          ),
        ),
      );
    }

    final finalAgent = split.finalAgent;
    if (finalAgent == null) {
      entries.add(
        _unavailable(
          id: 'studio.final',
          stage: StudioPromptPreviewStage.finalWriter,
          title: 'Main Writer',
          reason: StudioPromptPreviewUnavailableReason.configurationUnavailable,
        ),
      );
    } else if (split.preGenTrackers.isNotEmpty) {
      entries.add(
        _unavailable(
          id: 'studio.final',
          stage: StudioPromptPreviewStage.finalWriter,
          title: finalAgent.name,
          reason:
              StudioPromptPreviewUnavailableReason.controllerOutputsRequired,
          agentId: finalAgent.id,
        ),
      );
    } else {
      final resolved = await resolveAgentConfig(
        agent: finalAgent,
        inputs: inputs,
        turnConfig: turnConfig,
        isFinal: true,
        apiConfigId: preset.expensiveApiConfigId,
      );
      final messages = messageBuilder.buildAgentMessages(
        agent: finalAgent,
        context: finalContext,
        config: config,
        studioPreset: preset,
        priorBriefs: const [],
        isFinalResponse: true,
        finalContextOverride: finalContextSize,
        reasoningHistoryCount: settings.studioFinalReasoningHistoryCount,
        excludeReasoningFromContextBudget:
            settings.studioFinalExcludeReasoningFromContextBudget,
      );
      entries.add(
        _available(
          id: 'studio.final',
          stage: StudioPromptPreviewStage.finalWriter,
          title: finalAgent.name,
          agent: finalAgent,
          resolved: resolved,
          messages: messages,
          session: session,
          inputs: inputs,
          preset: preset,
          turnConfig: turnConfig,
          detail:
              'Current final-writer request; no controller output is '
              'required by this preset.',
          maxTokensOverride: effectiveMaxTokens(
            agent: finalAgent,
            isFinal: true,
            turnConfig: turnConfig,
          ),
          temperatureOverride: effectiveTemperature(
            agent: finalAgent,
            isFinal: true,
            turnConfig: turnConfig,
          ),
        ),
      );
    }

    for (final agent in split.postGenTrackers) {
      entries.add(
        _unavailable(
          id: 'post:${agent.id}',
          stage: StudioPromptPreviewStage.postProcessor,
          title: agent.name,
          reason: StudioPromptPreviewUnavailableReason.finalResponseRequired,
          agentId: agent.id,
        ),
      );
    }
    entries.addAll(_standardUnavailableEntries(null));
    await _requireCurrent(session, turnConfig);
    return StudioPromptPreviewCatalog(
      sessionId: session.id,
      presetId: preset.id,
      generatedAt: (now ?? DateTime.now)(),
      entries: entries,
    );
  }

  StudioContext _prepareContext(
    GenerationContextInputs inputs,
    Set<String> visibleIds,
    StudioTurnConfigSnapshot turnConfig,
    StudioPreset preset,
    String consumerPath,
  ) => const StudioContextPreparer().prepare(
    inputs: inputs,
    visibleMessageIds: visibleIds,
    ledgerPromptInjectionPolicy: turnConfig.ledgerPromptInjectionPolicy,
    consumerPath: consumerPath,
    reasoningTagStartOverride: preset.runtime.reasoningTagStart,
    reasoningTagEndOverride: preset.runtime.reasoningTagEnd,
    studioPreset: preset,
  );

  Future<void> _requireCurrent(
    ChatSession sourceSession,
    StudioTurnConfigSnapshot sourceConfig,
  ) async {
    _requireSessionCurrent(sourceSession);
    final sourcePreset = sourceConfig.preset;
    final currentConfig = await resolveTurnConfig(sourceSession.id);
    if (sourcePreset == null ||
        sourceConfig.config?.sessionId != sourceSession.id ||
        currentConfig.preset != sourcePreset ||
        currentConfig.pipelineSettings != sourceConfig.pipelineSettings ||
        currentConfig.activeApiConfig != sourceConfig.activeApiConfig) {
      throw StateError('Studio configuration changed while building preview.');
    }
  }

  void _requireSessionCurrent(ChatSession sourceSession) {
    if (readSession() != sourceSession) {
      throw StateError('Chat changed while building the Studio preview.');
    }
  }

  StudioPromptPreviewEntry _available({
    required String id,
    required StudioPromptPreviewStage stage,
    required String title,
    required StudioAgent agent,
    required ResolvedAgentConfig resolved,
    required List<Map<String, dynamic>> messages,
    required ChatSession session,
    required GenerationContextInputs inputs,
    required StudioPreset preset,
    required StudioTurnConfigSnapshot turnConfig,
    required String detail,
    int? maxTokensOverride,
    double? temperatureOverride,
  }) {
    final request = AgentStreamRunner.buildRequest(
      agent: agent,
      messages: messages,
      resolved: effectiveRequestConfig(
        agent: agent,
        resolved: resolved,
        isFinal: stage == StudioPromptPreviewStage.finalWriter,
        turnConfig: turnConfig,
      ),
      sessionId: session.id,
      isFinalResponse: stage == StudioPromptPreviewStage.finalWriter,
      maxTokensOverride: maxTokensOverride,
      temperatureOverride: temperatureOverride,
      charName: inputs.character.name,
      userName: inputs.persona?.name,
    );
    final processedRequest = postProcessRequest(request);
    final sanitized = LlmRequestCapture.sanitizeRequest(processedRequest);
    final sanitizedMessages = sanitized.request['messages'] as List<dynamic>;
    final typedMessages = sanitizedMessages
        .map(
          (item) => Map<String, dynamic>.unmodifiable(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    final raw = <String, dynamic>{
      'format': 'sanitized_pre_protocol_request',
      ...sanitized.request,
    };
    return StudioPromptPreviewEntry(
      id: id,
      stage: stage,
      title: title,
      agentId: agent.id,
      isFuture: false,
      messages: typedMessages,
      rawRequest: raw,
      metadata: {
        'stage': stage.name,
        'agentId': agent.id,
        'agentName': agent.name,
        'model': resolved.model,
        'protocol': resolved.protocol,
        'sessionId': session.id,
        'characterId': inputs.character.id,
        'presetId': preset.id,
        'source': 'current read-only snapshot',
        'fidelity': detail,
        'rawFormat':
            'Exact sanitized provider-neutral AgentStreamRunner request after '
            'prompt post-processing and before protocol encoding.',
        'retrieval':
            'Network-backed embedding, vector, and raw-message recall are '
            'omitted so preview performs no provider calls.',
      },
    );
  }

  static StudioPromptPreviewEntry _unavailable({
    required String id,
    required StudioPromptPreviewStage stage,
    required String title,
    required StudioPromptPreviewUnavailableReason reason,
    String? agentId,
    bool isFuture = true,
  }) => StudioPromptPreviewEntry(
    id: id,
    stage: stage,
    title: title,
    agentId: agentId,
    isFuture: isFuture,
    messages: const [],
    metadata: {'stage': stage.name, 'source': isFuture ? 'future' : 'current'},
    unavailableReason: reason,
  );

  static List<StudioPromptPreviewEntry> _standardUnavailableEntries(
    StudioPromptPreviewUnavailableReason? allReason,
  ) => [
    _unavailable(
      id: 'cleaner.audit',
      stage: StudioPromptPreviewStage.cleanerAudit,
      title: 'Cleaner audit',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.finalResponseRequired,
    ),
    _unavailable(
      id: 'cleaner.rewrite',
      stage: StudioPromptPreviewStage.cleanerRewrite,
      title: 'Cleaner rewrite',
      reason:
          allReason ?? StudioPromptPreviewUnavailableReason.auditOutputRequired,
    ),
    _unavailable(
      id: 'ledger.turn',
      stage: StudioPromptPreviewStage.ledgerTurn,
      title: 'Ledger turn',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.finalResponseRequired,
    ),
    _unavailable(
      id: 'ledger.turn_repair',
      stage: StudioPromptPreviewStage.ledgerRepair,
      title: 'Ledger repair',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.malformedOutputRequired,
    ),
    _unavailable(
      id: 'ledger.reconciliation',
      stage: StudioPromptPreviewStage.reconciliation,
      title: 'Reconciliation',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.pureBuilderUnavailable,
    ),
    _unavailable(
      id: 'ledger.reconciliation_repair',
      stage: StudioPromptPreviewStage.reconciliationRepair,
      title: 'Reconciliation repair',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.malformedOutputRequired,
    ),
    _unavailable(
      id: 'card.collector',
      stage: StudioPromptPreviewStage.collector,
      title: 'Collector',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.claimSafeSelectionRequired,
    ),
    _unavailable(
      id: 'card.history_consolidation',
      stage: StudioPromptPreviewStage.consolidation,
      title: 'History consolidation',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.upstreamOutputRequired,
    ),
    _unavailable(
      id: 'card.writer',
      stage: StudioPromptPreviewStage.cardWriter,
      title: 'Card writer',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.claimSafeSelectionRequired,
    ),
    _unavailable(
      id: 'card.writer_repair',
      stage: StudioPromptPreviewStage.cardWriterRepair,
      title: 'Card writer repair',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.malformedOutputRequired,
    ),
    _unavailable(
      id: 'card.lorebook_writer',
      stage: StudioPromptPreviewStage.lorebookWriter,
      title: 'Lorebook writer',
      reason:
          allReason ??
          StudioPromptPreviewUnavailableReason.upstreamOutputRequired,
    ),
  ];

  static ChatTransportRequest _identityRequest(ChatTransportRequest request) =>
      request;
}

final studioPromptPreviewServiceProvider =
    Provider.family<StudioPromptPreviewService, String>((ref, charId) {
      final parser = StudioBriefParser((_) {});
      return StudioPromptPreviewService(
        readSession: () => ref.read(chatProvider(charId)).value?.session,
        resolveTurnConfig: ref.read(studioTurnConfigResolverProvider).resolve,
        collectContext: (session, turnConfig) => ref
            .read(promptPayloadBuilderProvider)
            .collectGenerationContext(
              charId: charId,
              session: session,
              apiConfigOverride: turnConfig.activeApiConfig,
              includeEffectiveCanon: true,
              readOnlyEffectiveCanon: true,
              skipVectorSearch: true,
              allowRemoteRetrieval: false,
            ),
        resolveAgentConfig:
            ({
              required agent,
              required inputs,
              required turnConfig,
              required isFinal,
              required apiConfigId,
            }) => ref
                .read(agentRunnerProvider)
                .resolveAgentConfig(
                  agent,
                  inputs.apiConfig,
                  inputs.sessionId ?? '',
                  isFinalResponse: isFinal,
                  apiConfigId: apiConfigId,
                  turnConfig: turnConfig,
                ),
        groupControllers:
            ({
              required agents,
              required inputs,
              required turnConfig,
              required apiConfigId,
            }) => ref
                .read(controllerBatcherProvider)
                .groupAgents(
                  agents: agents,
                  apiConfig: inputs.apiConfig,
                  sessionId: inputs.sessionId ?? '',
                  apiConfigId: apiConfigId,
                  turnConfig: turnConfig,
                ),
        controllerBatcher: ref.read(controllerBatcherProvider),
        effectiveRequestConfig:
            ({
              required agent,
              required resolved,
              required isFinal,
              required turnConfig,
            }) => ref
                .read(agentRunnerProvider)
                .effectiveRequestConfig(agent, resolved, isFinal, turnConfig),
        effectiveMaxTokens:
            ({required agent, required isFinal, required turnConfig}) => ref
                .read(agentRunnerProvider)
                .effectiveMaxTokens(agent, isFinal, turnConfig),
        effectiveTemperature:
            ({required agent, required isFinal, required turnConfig}) => ref
                .read(agentRunnerProvider)
                .effectiveTemperature(agent, isFinal, turnConfig),
        postProcessRequest: PostProcessingChatTransport.applyTo,
        messageBuilder: StudioMessageBuilder(
          const StudioPromptText(),
          StudioBriefDeduper(parser),
          readStudioRegexes: () =>
              ref.read(studioRegexProvider).value ?? const [],
        ),
      );
    });

final studioPromptPreviewCatalogProvider =
    FutureProvider.family<StudioPromptPreviewCatalog, String>((
      ref,
      charId,
    ) async {
      ref.watch(chatProvider(charId));
      ref.watch(pipelineSettingsProvider);
      ref.watch(studioFeatureEnabledProvider);
      ref.watch(activeStudioPresetProvider);
      ref.watch(apiListProvider);
      ref.watch(activeApiConfigProvider);
      await ref.watch(studioRegexProvider.future);
      return ref.watch(studioPromptPreviewServiceProvider(charId)).load();
    });
