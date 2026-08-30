import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/chat_session_service.dart';
import '../../features/chat_history/chat_history_provider.dart';
import '../../features/settings/api_list_provider.dart';
import '../llm/agent_runner.dart';
import '../llm/aux_llm_client.dart';
import '../llm/memory_graph_builder.dart';
import '../llm/memory_provenance.dart';
import '../llm/memory_cadence_service.dart';
import '../llm/memory_post_turn_service.dart';
import '../llm/memory_agentic_service.dart';
import '../llm/memory_studio_service.dart';
import '../llm/post_cleaner_service.dart';
import '../llm/prompt/ledger_tracker_loader.dart';
import '../llm/studio_ledger_service.dart';
import '../llm/studio/agent_config_resolver.dart';
import '../llm/controller_batcher.dart';
import '../models/api_config.dart';
import 'db_provider.dart';
import 'studio_regex_provider.dart';

/// Provider for the entity graph builder.
final memoryGraphBuilderProvider = Provider<MemoryGraphBuilder>((ref) {
  return MemoryGraphBuilder(
    ref.watch(memoryEntityRepoProvider),
    ref.watch(memorySalienceRepoProvider),
  );
});

/// Provenance index for derived state artifacts (tracker, proposed memory,
/// scene, and legacy catalog artifacts).
final memoryProvenanceIndexProvider =
    Provider<MemoryProvenanceIndex<MemoryDerivedArtifact<dynamic>>>((ref) {
      final index = MemoryProvenanceIndex<MemoryDerivedArtifact<dynamic>>();
      ref.onDispose(index.clear);
      return index;
    });

/// Cadence service for gating post-turn work.
final memoryCadenceServiceProvider = Provider<MemoryCadenceService>((ref) {
  return MemoryCadenceService(ref.watch(memoryCadenceRepoProvider));
});

/// Post-turn pipeline service. Fire-and-forget after assistant response.
/// Currently a no-op (entity graph disabled) — only cadence counter runs.
final memoryPostTurnServiceProvider = Provider<MemoryPostTurnService>((ref) {
  return MemoryPostTurnService(ref.watch(memoryCadenceServiceProvider));
});

/// Agentic memory service (Phase 10). Read-only searchMemory tool.
final memoryAgenticServiceProvider = Provider<MemoryAgenticService>((ref) {
  return MemoryAgenticService(ref);
});

/// Studio Mode pipeline service. Tracker-around-generator model.
final agentRunnerProvider = Provider<AgentRunner>((ref) {
  return AgentRunner(
    configResolver: AgentConfigResolver(
      loadApiConfigs: () async {
        await ref.read(apiListProvider.future);
        return ref.read(apiListProvider).value ?? const <ApiConfig>[];
      },
      readActiveApiConfig: () => ref.read(activeApiConfigProvider),
      readPipelineSettings: () => ref.read(pipelineSettingsProvider),
    ),
    readPipelineSettings: () => ref.read(pipelineSettingsProvider),
  );
});

final controllerBatcherProvider = Provider<ControllerBatcher>((ref) {
  return ControllerBatcher(ref.read(agentRunnerProvider));
});

final memoryStudioServiceProvider = Provider<MemoryStudioService>((ref) {
  return MemoryStudioService(
    ref,
    ref.read(agentRunnerProvider),
    ref.read(controllerBatcherProvider),
  );
});

/// POST-cleaner service (Stage 4). Rewrites the final assistant message
/// to remove clichés and repetition. Fire-and-forget after generation.
final postCleanerServiceProvider = Provider<PostCleanerService>((ref) {
  final studioRegexes = ref.watch(studioRegexProvider).value ?? const [];
  return PostCleanerService(
    llm: const AuxLlmClient(),
    chatRepo: ref.read(chatRepoProvider),
    snapshotRepo: ref.read(trackerSnapshotRepoProvider),
    onSessionUpdated: ChatSessionService.updateCache,
    invalidateChatHistory: () => ref.invalidate(chatHistoryProvider),
    readStudioRegexes: () => studioRegexes,
  );
});

/// Studio Ledger service (Stage 5). Runs after the POST-cleaner to extract
/// and persist accepted continuity state (entity/relationship/arc/world/scene)
/// plus scoped character knowledge facts from the final assistant response.
/// See docs/plans/STUDIO_LEDGER_MEMORY.md.
final ledgerTrackerLoaderProvider = Provider<LedgerTrackerLoader>((ref) {
  return LedgerTrackerLoader(ref);
});

final studioLedgerServiceProvider = Provider<StudioLedgerService>((ref) {
  final studioRegexes = ref.watch(studioRegexProvider).value ?? const [];
  return StudioLedgerService(
    llm: const AuxLlmClient(),
    trackerRepo: ref.read(trackerRepoProvider),
    bookRepo: ref.read(memoryBookRepoProvider),
    snapshotRepo: ref.read(trackerSnapshotRepoProvider),
    knowledgeFactRepo: ref.read(characterKnowledgeFactRepoProvider),
    reconciliationCheckpointRepo: ref.read(
      ledgerReconciliationCheckpointRepoProvider,
    ),
    reconciliationRunRepo: ref.read(ledgerReconciliationRunRepoProvider),
    characterRepo: ref.read(characterRepoProvider),
    chatRepo: ref.read(chatRepoProvider),
    canonContextLoader: ref.read(effectiveCanonContextLoaderProvider),
    readStudioRegexes: () => studioRegexes,
  );
});
