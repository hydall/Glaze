import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_db.dart';
import '../db/repositories/character_repo.dart';
import '../db/repositories/chat_repo.dart';
import '../db/repositories/chat_session_branch_repo.dart';
import '../db/repositories/preset_repo.dart';
import '../models/preset.dart';
import '../db/repositories/api_config_repo.dart';
import '../db/repositories/persona_repo.dart';
import '../db/repositories/lorebook_repo.dart';
import '../db/repositories/session_lorebook_evolution_repo.dart';
import '../db/repositories/session_canon_checkpoint_repo.dart';
import '../db/repositories/session_canon_rollback_repo.dart';
import '../db/repositories/session_lorebook_revision_repo.dart';
import '../db/repositories/session_lorebook_embedding_job_repo.dart';
import '../db/repositories/lorebook_use_manifest_repo.dart';
import '../db/repositories/embedding_repo.dart';
import '../db/repositories/summary_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../db/repositories/memory_catalog_repo.dart';
import '../db/repositories/memory_entity_repo.dart';
import '../db/repositories/memory_salience_repo.dart';
import '../db/repositories/memory_cadence_repo.dart';
import '../db/repositories/studio_config_repo.dart';
import '../db/repositories/studio_preset_repo.dart';
import '../models/studio_config.dart';
import '../db/repositories/tracker_repo.dart';
import '../db/repositories/tracker_snapshot_repo.dart';
import '../db/repositories/ledger_raw_tracker_state_reader.dart';
import '../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../db/repositories/ledger_reconciliation_run_repo.dart';
import '../db/repositories/card_evolution_repo.dart';
import '../db/repositories/character_knowledge_fact_repo.dart';
import '../db/repositories/character_session_baseline_repo.dart';
import '../db/repositories/character_revision_repo.dart';
import '../db/repositories/applied_canon_transition_repo.dart';
import '../db/repositories/canon_transition_fact_ref_repo.dart';
import '../db/repositories/manual_rewrite_apply_repo.dart';
import '../db/repositories/manual_rewrite_job_repo.dart';
import '../db/repositories/extension_presets_repository.dart';
import '../db/repositories/info_blocks_repository.dart';
import '../db/repositories/session_deletion_repo.dart';
import '../db/repositories/character_deletion_repo.dart';
import '../models/memory_book.dart';
import '../services/character_importer.dart';
import '../services/image_storage_service.dart';
import '../services/migration_service.dart';
import '../services/card_rewriter/effective_canon_context_loader.dart';
import '../services/card_rewriter/effective_canon_read_repository.dart';
import 'studio_feature_provider.dart';

// Re-export so existing call sites that `import db_provider.dart` can still
// read pipelineSettingsProvider (previously defined here as a
// FutureProvider.family before the singleton-global refactor).
export 'pipeline_settings_provider.dart' show pipelineSettingsProvider;

// Re-export the global Studio master switch so the generation pipeline stages
// (which already import db_provider) can gate Studio without extra imports.
export 'studio_feature_provider.dart' show studioFeatureEnabledProvider;

final appDbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final imageStorageProvider = FutureProvider<ImageStorageService>((ref) async {
  return await ImageStorageService.create();
});

final characterImporterProvider = FutureProvider<CharacterImporter>((
  ref,
) async {
  final imageStorage = await ref.watch(imageStorageProvider.future);
  return CharacterImporter(imageStorage);
});

final migrationServiceProvider = FutureProvider<MigrationService>((ref) async {
  final imageStorage = await ref.watch(imageStorageProvider.future);
  return MigrationService(
    charRepo: ref.watch(characterRepoProvider),
    chatRepo: ref.watch(chatRepoProvider),
    personaRepo: ref.watch(personaRepoProvider),
    presetRepo: ref.watch(presetRepoProvider),
    apiRepo: ref.watch(apiConfigRepoProvider),
    imageStorage: imageStorage,
  );
});

final characterRepoProvider = Provider<CharacterRepo>((ref) {
  return CharacterRepo(ref.watch(appDbProvider));
});

final chatRepoProvider = Provider<ChatRepo>((ref) {
  return ChatRepo(ref.watch(appDbProvider));
});

final chatSessionBranchRepoProvider = Provider<ChatSessionBranchRepo>((ref) {
  return ChatSessionBranchRepo(ref.watch(appDbProvider));
});

final sessionDeletionRepoProvider = Provider<SessionDeletionRepo>((ref) {
  return SessionDeletionRepo(ref.watch(appDbProvider));
});

final characterDeletionRepoProvider = Provider<CharacterDeletionRepo>((ref) {
  return CharacterDeletionRepo(ref.watch(appDbProvider));
});

final presetRepoProvider = Provider<PresetRepo>((ref) {
  return PresetRepo(ref.watch(appDbProvider));
});

final presetsListProvider = FutureProvider<List<Preset>>((ref) {
  return ref.watch(presetRepoProvider).getAll();
});

final apiConfigRepoProvider = Provider<ApiConfigRepo>((ref) {
  return ApiConfigRepo(ref.watch(appDbProvider));
});

final personaRepoProvider = Provider<PersonaRepo>((ref) {
  return PersonaRepo(ref.watch(appDbProvider));
});

final lorebookRepoProvider = Provider<LorebookRepo>((ref) {
  return LorebookRepo(ref.watch(appDbProvider));
});

final sessionLorebookEvolutionRepoProvider =
    Provider<SessionLorebookEvolutionRepo>((ref) {
      return SessionLorebookEvolutionRepo(ref.watch(appDbProvider));
    });

final sessionCanonCheckpointRepoProvider = Provider<SessionCanonCheckpointRepo>(
  (ref) {
    return SessionCanonCheckpointRepo(ref.watch(appDbProvider));
  },
);

final sessionCanonRollbackRepoProvider = Provider<SessionCanonRollbackRepo>((
  ref,
) {
  return SessionCanonRollbackRepo(ref.watch(appDbProvider));
});

final sessionLorebookRevisionRepoProvider =
    Provider<SessionLorebookRevisionRepo>((ref) {
      return SessionLorebookRevisionRepo(ref.watch(appDbProvider));
    });

final sessionLorebookEmbeddingJobRepoProvider =
    Provider<SessionLorebookEmbeddingJobRepo>((ref) {
      return SessionLorebookEmbeddingJobRepo(ref.watch(appDbProvider));
    });

final lorebookUseManifestRepoProvider = Provider<LorebookUseManifestRepo>((
  ref,
) {
  return LorebookUseManifestRepo(ref.watch(appDbProvider));
});

final ledgerReconciliationRunRepoProvider =
    Provider<LedgerReconciliationRunRepo>(
      (ref) => LedgerReconciliationRunRepo(ref.watch(appDbProvider)),
    );

final embeddingRepoProvider = Provider<EmbeddingRepo>((ref) {
  return EmbeddingRepo(ref.watch(appDbProvider));
});

final summaryRepoProvider = Provider<SummaryRepo>((ref) {
  return SummaryRepo(ref.watch(appDbProvider));
});

final memoryBookRepoProvider = Provider<MemoryBookRepo>((ref) {
  return MemoryBookRepo(ref.watch(appDbProvider), ref);
});

final memoryCatalogRepoProvider = Provider<MemoryCatalogRepo>((ref) {
  return MemoryCatalogRepo(ref.watch(appDbProvider));
});

final memoryEntityRepoProvider = Provider<MemoryEntityRepo>((ref) {
  return MemoryEntityRepo(ref.watch(appDbProvider));
});

final memorySalienceRepoProvider = Provider<MemorySalienceRepo>((ref) {
  return MemorySalienceRepo(ref.watch(appDbProvider));
});

final memoryCadenceRepoProvider = Provider<MemoryCadenceRepo>((ref) {
  return MemoryCadenceRepo(ref.watch(appDbProvider));
});

final studioConfigRepoProvider = Provider<StudioConfigRepo>((ref) {
  return StudioConfigRepo(ref.watch(appDbProvider));
});

final studioPresetRepoProvider = Provider<StudioPresetRepo>((ref) {
  return StudioPresetRepo(ref.watch(appDbProvider));
});

// `studioPresetProvider` — the preset a turn actually runs — lives in
// `active_studio_preset_provider.dart`: it needs the active-preset id, and that
// provider already imports this file.

final studioPresetListProvider = FutureProvider<List<StudioPreset>>((
  ref,
) async {
  return ref.watch(studioPresetRepoProvider).getAll();
});

/// Whether Studio is enabled globally. The session id remains part of the
/// provider API for its chat UI consumers, but no longer controls activation.
final sessionStudioEnabledProvider = FutureProvider.family<bool, String>((
  ref,
  sessionId,
) async {
  if (sessionId.isEmpty) return false;
  return ref.watch(studioFeatureEnabledProvider);
});

final trackerRepoProvider = Provider<TrackerRepo>((ref) {
  return TrackerRepo(ref.watch(appDbProvider));
});

final trackerSnapshotRepoProvider = Provider<TrackerSnapshotRepo>((ref) {
  return TrackerSnapshotRepo(ref.watch(appDbProvider));
});

/// Ref-free raw Ledger read boundary for transaction-fenced canon operations.
final ledgerRawTrackerStateReaderProvider =
    Provider<LedgerRawTrackerStateReader>((ref) {
      return LedgerRawTrackerStateReader(ref.watch(appDbProvider));
    });

final ledgerReconciliationCheckpointRepoProvider =
    Provider<LedgerReconciliationCheckpointRepo>((ref) {
      return LedgerReconciliationCheckpointRepo(ref.watch(appDbProvider));
    });

final characterKnowledgeFactRepoProvider = Provider<CharacterKnowledgeFactRepo>(
  (ref) {
    return CharacterKnowledgeFactRepo(ref.watch(appDbProvider));
  },
);

final characterSessionBaselineRepoProvider =
    Provider<CharacterSessionBaselineRepo>((ref) {
      return CharacterSessionBaselineRepo(ref.watch(appDbProvider));
    });

final characterRevisionRepoProvider = Provider<CharacterRevisionRepo>((ref) {
  return CharacterRevisionRepo(ref.watch(appDbProvider));
});

final appliedCanonTransitionRepoProvider = Provider<AppliedCanonTransitionRepo>(
  (ref) {
    return AppliedCanonTransitionRepo(ref.watch(appDbProvider));
  },
);

final canonTransitionFactRefRepoProvider = Provider<CanonTransitionFactRefRepo>(
  (ref) {
    return CanonTransitionFactRefRepo(ref.watch(appDbProvider));
  },
);

/// Construction only: [EffectiveCanonContextLoader] stays Ref-free.
final effectiveCanonContextLoaderProvider =
    Provider<EffectiveCanonContextLoader>((ref) {
      return EffectiveCanonContextLoader(
        db: ref.watch(appDbProvider),
        characterRepo: ref.watch(characterRepoProvider),
        characterRevisionRepo: ref.watch(characterRevisionRepoProvider),
        baselineRepo: ref.watch(characterSessionBaselineRepoProvider),
        factRepo: ref.watch(characterKnowledgeFactRepoProvider),
        transitionRepo: ref.watch(appliedCanonTransitionRepoProvider),
        transitionFactRefRepo: ref.watch(canonTransitionFactRefRepoProvider),
        loadRawTrackerState: ref
            .watch(ledgerRawTrackerStateReaderProvider)
            .read,
      );
    });

final memoryBookProvider = FutureProvider.family<MemoryBook?, String>((
  ref,
  sessionId,
) async {
  final repo = ref.watch(memoryBookRepoProvider);
  return repo.getBySessionId(sessionId);
});

final manualRewriteApplyRepoProvider = Provider<ManualRewriteApplyRepo>((ref) {
  return ManualRewriteApplyRepo(
    db: ref.watch(appDbProvider),
    lorebookEvolutionRepo: ref.watch(sessionLorebookEvolutionRepoProvider),
    checkpointRepo: ref.watch(sessionCanonCheckpointRepoProvider),
    lorebookRevisionRepo: ref.watch(sessionLorebookRevisionRepoProvider),
    embeddingJobRepo: ref.watch(sessionLorebookEmbeddingJobRepoProvider),
    canonReader: EffectiveCanonReadRepository(
      db: ref.watch(appDbProvider),
      characterRepo: ref.watch(characterRepoProvider),
      revisionRepo: ref.watch(characterRevisionRepoProvider),
      baselineRepo: ref.watch(characterSessionBaselineRepoProvider),
      factRepo: ref.watch(characterKnowledgeFactRepoProvider),
      transitionRepo: ref.watch(appliedCanonTransitionRepoProvider),
      transitionFactRefRepo: ref.watch(canonTransitionFactRefRepoProvider),
      rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
    ),
  );
});

/// Owns the durable Phase-4 job/review lifecycle. Advisory validation reads
/// through the same-DB raw Ledger reader; it never writes canon or characters.
final manualRewriteJobRepoProvider = Provider<ManualRewriteJobRepo>((ref) {
  return ManualRewriteJobRepo(
    db: ref.watch(appDbProvider),
    rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
  );
});

final cardEvolutionRepoProvider = Provider<CardEvolutionRepo>((ref) {
  final db = ref.watch(appDbProvider);
  return CardEvolutionRepo(
    db: db,
    canonReader: EffectiveCanonReadRepository(
      db: db,
      characterRepo: ref.watch(characterRepoProvider),
      revisionRepo: ref.watch(characterRevisionRepoProvider),
      baselineRepo: ref.watch(characterSessionBaselineRepoProvider),
      factRepo: ref.watch(characterKnowledgeFactRepoProvider),
      transitionRepo: ref.watch(appliedCanonTransitionRepoProvider),
      transitionFactRefRepo: ref.watch(canonTransitionFactRefRepoProvider),
      rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
    ),
    jobRepo: ref.watch(manualRewriteJobRepoProvider),
    lorebookEvolutionRepo: ref.watch(sessionLorebookEvolutionRepoProvider),
  );
});

final extensionPresetsRepoProvider = Provider<ExtensionPresetsRepository>((
  ref,
) {
  return ExtensionPresetsRepository(ref.watch(appDbProvider));
});

final infoBlocksRepoProvider = Provider<InfoBlocksRepository>((ref) {
  return InfoBlocksRepository(ref.watch(appDbProvider));
});
