import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_db.dart'
    show CardEvolutionDebugRunRow, RewriteJobRow, SessionLorebookEvolutionRow;
import '../../features/settings/api_list_provider.dart';
import '../llm/card_rewrite_slot_resolver.dart';
import '../llm/aux_llm_client.dart';
import '../models/api_config.dart';
import '../models/card_rewriter_settings.dart';
import '../models/studio_pipeline_overrides.dart';
import '../services/card_rewriter/manual_rewrite_service.dart';
import '../services/card_rewriter/automated_card_evolution_service.dart';
import 'active_studio_preset_provider.dart';
import 'db_provider.dart';
import 'studio_turn_config_resolver.dart';

/// The Card Rewriter settings the lane actually runs on: the active Studio
/// preset's own copy when it has one, the global settings otherwise.
///
/// Every reader — the services below, the Agent Ops management tab, the
/// post-generation status card — goes through this, so the lane can never run
/// on one preset's settings while the UI edits another's. While the preset is
/// still loading the globals stand in; the services only call their closures
/// once a turn has resolved its preset, so nothing runs on the stand-in.
final cardRewriterSettingsProvider = Provider<CardRewriterSettings>((ref) {
  return effectiveCardRewriterSettings(
    ref.watch(pipelineSettingsProvider),
    ref.watch(studioPresetProvider).value,
  );
});

/// Phase-4B writer lane: the manual card-rewrite LLM orchestration service.
///
/// Wired here (not in `db_provider.dart`) because model resolution reads
/// `apiListProvider`, which itself imports `db_provider.dart`.
///
/// Its dedicated API/model slot is persisted on the active Studio preset (see
/// [cardRewriterSettingsProvider]). It always fails explicitly when the
/// selected API preset is absent; it never falls back to the active chat
/// configuration.
final manualRewriteServiceProvider = Provider<ManualRewriteService>((ref) {
  final settings = ref.watch(cardRewriterSettingsProvider);
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

      Future<AuxApiConfig> resolveCollectorModel(String sessionId) async {
        final turnConfig = await ref
            .read(studioTurnConfigResolverProvider)
            .resolve(sessionId);
        return turnConfig.resolveLedgerConfig(errorLabel: 'card-collector');
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
        observationPromotionThreshold: () =>
            ref.read(cardRewriterSettingsProvider).observationPromotionThreshold,
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
