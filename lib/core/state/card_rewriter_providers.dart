import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_db.dart'
    show CardEvolutionDebugRunRow, RewriteJobRow, SessionLorebookEvolutionRow;
import '../../features/settings/api_list_provider.dart';
import '../llm/card_rewrite_slot_resolver.dart';
import '../llm/aux_llm_client.dart';
import '../models/api_config.dart';
import '../services/card_rewriter/manual_rewrite_service.dart';
import '../services/card_rewriter/automated_card_evolution_service.dart';
import 'db_provider.dart';

/// Phase-4B writer lane: the manual card-rewrite LLM orchestration service.
///
/// Wired here (not in `db_provider.dart`) because model resolution reads
/// `apiListProvider`, which itself imports `db_provider.dart`.
///
/// Its dedicated API/model slot is persisted in the global Studio settings.
/// It always fails explicitly when the selected API preset is absent; it never
/// falls back to the active chat configuration.
final manualRewriteServiceProvider = Provider<ManualRewriteService>((ref) {
  final settings = ref.watch(
    pipelineSettingsProvider.select((value) => value.cardRewriter),
  );
  final service = ManualRewriteService(
    db: ref.watch(appDbProvider),
    jobRepo: ref.watch(manualRewriteJobRepoProvider),
    characterRepo: ref.watch(characterRepoProvider),
    canonLoader: ref.watch(effectiveCanonContextLoaderProvider),
    resolveModel: () async {
      await ref.read(apiListProvider.future);
      final apiConfigs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
      return CardRewriteSlotResolver.resolve(
        apiConfigs: apiConfigs,
        apiConfigId: settings.apiConfigId,
        modelOverride: settings.modelOverride,
      );
    },
  );
  ref.onDispose(service.dispose);
  return service;
});

final automatedCardEvolutionServiceProvider =
    Provider<AutomatedCardEvolutionService>((ref) {
      final settings = ref.watch(
        pipelineSettingsProvider.select((value) => value.cardRewriter),
      );
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

      final service = AutomatedCardEvolutionService(
        repo: ref.watch(cardEvolutionRepoProvider),
        writerCallRepo: ref.watch(cardEvolutionWriterCallRepoProvider),
        requestCaptureRepo: ref.watch(llmRequestCaptureRepoProvider),
        resolveModel: resolveModel,
        isEnabled: () =>
            ref.read(pipelineSettingsProvider).cardRewriter.enabled,
        isLorebookEvolutionEnabled: () => ref
            .read(pipelineSettingsProvider)
            .cardRewriter
            .lorebookEvolutionEnabled,
        timeoutMs: settings.timeoutMs,
        observationPromotionThreshold: () => ref
            .read(pipelineSettingsProvider)
            .cardRewriter
            .observationPromotionThreshold,
        observationMinConfidence: () => ref
            .read(pipelineSettingsProvider)
            .cardRewriter
            .observationMinConfidence,
        observationExpiryRuns: () => ref
            .read(pipelineSettingsProvider)
            .cardRewriter
            .observationExpiryRuns,
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
