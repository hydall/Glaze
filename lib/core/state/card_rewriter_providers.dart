import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_db.dart'
    show CardEvolutionDebugRunRow, RewriteJobRow, SessionLorebookEvolutionRow;
import '../../features/settings/api_list_provider.dart';
import '../llm/card_rewrite_slot_resolver.dart';
import '../llm/aux_llm_client.dart';
import '../llm/post_gen_engine_config.dart';
import '../models/api_config.dart';
import '../models/card_rewriter_settings.dart';
import '../services/card_rewriter/automated_card_evolution_service.dart';
import 'db_provider.dart';
import 'agent_providers.dart';
import '../llm/agents/builtin_agents.dart';
import '../models/agent_definition.dart';

/// The Card Rewriter settings the lane runs on.
///
/// Every reader — the services below, the Agent Ops management tab, the
/// post-generation status card — goes through this one place. Whether the
/// lane runs in a turn is decided by the built-in Card Rewriter agent (the
/// Tracker stage checks the turn's plan), so the lane itself is always
/// enabled here; its connection and model come from that agent.
final cardRewriterSettingsProvider = Provider<CardRewriterSettings>((ref) {
  final pipeline = ref.watch(pipelineSettingsProvider);
  final agent = ref
      .watch(agentLibraryProvider)
      .value
      ?.where((a) => a.id == BuiltinAgentIds.cardRewriter)
      .firstOrNull;
  var settings = pipeline.cardRewriter.copyWith(enabled: true);
  if (agent == null) return settings;
  final activeId = ref.watch(activeApiConfigProvider)?.id ?? '';
  final connection = agent.connection;
  final apiConfigId = switch (connection.mode) {
    AgentConnectionMode.config => connection.apiConfigId,
    AgentConnectionMode.helper =>
      pipeline.agents.helperApiConfigId.isNotEmpty
          ? pipeline.agents.helperApiConfigId
          : activeId,
    _ => activeId,
  };
  final model = connection.model.isNotEmpty
      ? connection.model
      : (connection.mode == AgentConnectionMode.helper
            ? pipeline.agents.helperModel
            : '');
  settings = settings.copyWith(apiConfigId: apiConfigId, modelOverride: model);
  if (agent.params.timeoutMs != null) {
    settings = settings.copyWith(timeoutMs: agent.params.timeoutMs!);
  }
  return settings;
});

final automatedCardEvolutionServiceProvider =
    Provider<AutomatedCardEvolutionService>((ref) {
      final settings = ref.watch(cardRewriterSettingsProvider);
      Future<AuxApiConfig> resolveModel() async {
        await ref.read(apiListProvider.future);
        final apiConfigs =
            ref.read(apiListProvider).value ?? const <ApiConfig>[];
        return CardRewriteSlotResolver.resolve(
          apiConfigs: apiConfigs,
          apiConfigId: settings.apiConfigId,
          modelOverride: settings.modelOverride,
        );
      }

      // The collector reads accepted story state, so it runs on the
      // Tracker's connection.
      Future<AuxApiConfig> resolveCollectorModel(String sessionId) async {
        await ref.read(apiListProvider.future);
        final engineConfig = PostGenEngineConfig(
          pipelineSettings: ref.read(pipelineSettingsProvider),
          apiConfigs: ref.read(apiListProvider).value ?? const <ApiConfig>[],
          activeApiConfig: ref.read(activeApiConfigProvider),
        );
        return engineConfig.resolveLedgerConfig(errorLabel: 'card-collector');
      }

      final service = AutomatedCardEvolutionService(
        repo: ref.watch(cardEvolutionRepoProvider),
        writerCallRepo: ref.watch(cardEvolutionWriterCallRepoProvider),
        requestCaptureRepo: ref.watch(llmRequestCaptureRepoProvider),
        resolveModel: resolveModel,
        resolveCollectorModel: resolveCollectorModel,
        isEnabled: () => ref.read(cardRewriterSettingsProvider).enabled,
        isLorebookEvolutionEnabled: () =>
            ref.read(cardRewriterSettingsProvider).lorebookEvolutionEnabled,
        timeoutMs: settings.timeoutMs,
        observationPromotionThreshold: () => ref
            .read(cardRewriterSettingsProvider)
            .observationPromotionThreshold,
        observationMinConfidence: () =>
            ref.read(cardRewriterSettingsProvider).observationMinConfidence,
        observationExpiryRuns: () =>
            ref.read(cardRewriterSettingsProvider).observationExpiryRuns,
        executor:
            ({
              required config,
              required prompt,
              required maxTokens,
              required temperature,
              required timeoutMs,
              cancelToken,
              captureContext,
            }) => const AuxLlmClient().callOnceWithLog(
              config: config,
              prompt: prompt,
              maxTokens: maxTokens,
              temperature: temperature,
              timeoutMs: timeoutMs,
              cancelToken: cancelToken,
              captureContext: captureContext,
            ),
      );
      ref.onDispose(service.dispose);
      return service;
    });

/// Session-scoped review history for the Card Rewriter Studio screen.
final cardRewriteJobsBySessionProvider =
    StreamProvider.family<List<RewriteJobRow>, String>((ref, sessionId) {
      return ref
          .watch(manualRewriteJobRepoProvider)
          .watchJobsBySessionId(sessionId);
    });

/// Effective session-local lorebook changes, including cloud-imported state.
final cardRewriteLorebookOverlaysProvider = StreamProvider.autoDispose
    .family<List<SessionLorebookEvolutionRow>, String>((ref, sessionId) {
      return ref
          .watch(sessionLorebookEvolutionRepoProvider)
          .watchBySessionId(sessionId);
    });

final cardRewriteDebugRunsProvider = FutureProvider.autoDispose
    .family<List<CardEvolutionDebugRunRow>, String>((ref, sessionId) {
      return ref.watch(cardEvolutionRepoProvider).readDebugRuns(sessionId);
    });
