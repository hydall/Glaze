import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_db.dart';
import '../db/repositories/character_repo.dart';
import '../db/repositories/chat_repo.dart';
import '../db/repositories/preset_repo.dart';
import '../models/preset.dart';
import '../db/repositories/api_config_repo.dart';
import '../db/repositories/persona_repo.dart';
import '../db/repositories/lorebook_repo.dart';
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
import '../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../db/repositories/character_knowledge_fact_repo.dart';
import '../db/repositories/character_session_baseline_repo.dart';
import '../db/repositories/extension_presets_repository.dart';
import '../db/repositories/info_blocks_repository.dart';
import '../db/repositories/session_deletion_repo.dart';
import '../db/repositories/character_deletion_repo.dart';
import '../models/memory_book.dart';
import '../services/character_importer.dart';
import '../services/image_storage_service.dart';
import '../services/migration_service.dart';
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

final studioPresetProvider = FutureProvider<StudioPreset?>((ref) async {
  return ref.watch(studioPresetRepoProvider).getDefault();
});

/// Whether Studio is enabled for a given session. Drives Studio-only chat UI
/// affordances (e.g. the per-message "Re-run cleaner" button, which is a no-op
/// when Studio is off). Invalidated by the Studio settings sheet on save so the
/// UI reflects a toggle immediately. Returns `false` for a null/absent config.
final sessionStudioEnabledProvider = FutureProvider.family<bool, String>((
  ref,
  sessionId,
) async {
  if (sessionId.isEmpty) return false;
  // Respect the global Experimental Features master switch: Studio is off
  // everywhere when the feature is disabled, regardless of per-session config.
  if (!ref.watch(studioFeatureEnabledProvider)) return false;
  final config = await ref.watch(studioConfigRepoProvider).getBySessionId(
    sessionId,
  );
  return config?.enabled == true;
});

final trackerRepoProvider = Provider<TrackerRepo>((ref) {
  return TrackerRepo(ref.watch(appDbProvider));
});

final trackerSnapshotRepoProvider = Provider<TrackerSnapshotRepo>((ref) {
  return TrackerSnapshotRepo(ref.watch(appDbProvider));
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

final memoryBookProvider = FutureProvider.family<MemoryBook?, String>((
  ref,
  sessionId,
) async {
  final repo = ref.watch(memoryBookRepoProvider);
  return repo.getBySessionId(sessionId);
});

final extensionPresetsRepoProvider = Provider<ExtensionPresetsRepository>((
  ref,
) {
  return ExtensionPresetsRepository(ref.watch(appDbProvider));
});

final infoBlocksRepoProvider = Provider<InfoBlocksRepository>((ref) {
  return InfoBlocksRepository(ref.watch(appDbProvider));
});
