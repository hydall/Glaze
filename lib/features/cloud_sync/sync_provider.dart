import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/state/db_provider.dart';
import '../../../core/db/repositories/sync_session_consistency_repo.dart';
import '../../../core/state/character_folder_provider.dart'
    show characterFolderRepoProvider;
import '../../../core/state/lorebook_provider.dart'
    show saveLorebookActivations;
import '../../../shared/theme/theme_preset_storage.dart';
import 'adapters/ext_blocks_sync_stores.dart';
import 'services/sync_conflict.dart';
import 'services/sync_engine.dart';
import 'services/sync_service.dart';
import 'sync_config.dart';
import 'sync_models.dart';

final syncServiceProvider = FutureProvider<SyncService>((ref) async {
  await SyncConfig.load();

  final imageStorage = await ref.watch(imageStorageProvider.future);
  final themeStorage = await ThemePresetStorage.create();

  final service = SyncService(
    characterRepo: ref.watch(characterRepoProvider),
    chatRepo: ref.watch(chatRepoProvider),
    personaRepo: ref.watch(personaRepoProvider),
    presetRepo: ref.watch(presetRepoProvider),
    apiRepo: ref.watch(apiConfigRepoProvider),
    memoryBookRepo: ref.watch(memoryBookRepoProvider),
    lorebookRepo: ref.watch(lorebookRepoProvider),
    embeddingRepo: ref.watch(embeddingRepoProvider),
    imageStorage: imageStorage,
    themePresetRepo: themeStorage,
    extensionPresetRepo: ExtensionPresetSyncStore(
      ref.watch(extensionPresetsRepoProvider),
    ),
    extensionsSettingsStore: ExtensionsSettingsSyncStore(),
    infoBlockStore: InfoBlockSyncStore(ref.watch(infoBlocksRepoProvider)),
    trackerSnapshotStore: TrackerSnapshotSyncStore(
      ref.watch(trackerSnapshotRepoProvider),
    ),
    trackerValueStore: TrackerValueSyncStore(ref.watch(trackerRepoProvider)),
    studioConfigStore: ref.watch(studioConfigRepoProvider),
    studioPresetStore: ref.watch(studioPresetRepoProvider),
    chatSummaryStore: ChatSummarySyncStore(ref.watch(summaryRepoProvider)),
    characterFolderStore: CharacterFolderSyncStore(
      ref.watch(characterFolderRepoProvider),
    ),
    memoryGraphStore: MemoryGraphSyncStore(ref.watch(appDbProvider)),
    characterKnowledgeStore: CharacterKnowledgeSyncStore(
      ref.watch(appDbProvider),
    ),
    sessionLorebookOverlayStore: SessionLorebookOverlaySyncStore(
      ref.watch(appDbProvider),
    ),
    reconciliationStateStore: ReconciliationStateSyncStore(
      ref.watch(appDbProvider),
    ),
    sessionDeletionStore: ref.watch(sessionDeletionRepoProvider),
    characterDeletionStore: ref.watch(characterDeletionRepoProvider),
    saveLorebookActivations: saveLorebookActivations,
    reconcilePulledSessions: SyncSessionConsistencyRepo(
      ref.watch(appDbProvider),
    ).reconcile,
  );
  await service.init();

  ref.read(syncProviderProvider.notifier).state = service.provider;
  ref.read(syncConnectedProvider.notifier).state = service.isConnected();
  ref.read(syncAutoEnabledProvider.notifier).state = service.autoSyncEnabled;

  return service;
});

final syncStatusProvider = StateProvider<SyncStatus>((ref) => SyncStatus.idle);
final syncProviderProvider = StateProvider<SyncProvider>(
  (ref) => SyncProvider.dropbox,
);
final syncConnectedProvider = StateProvider<bool>((ref) => false);
final syncAutoEnabledProvider = StateProvider<bool>((ref) => false);
final syncConflictsProvider = StateProvider<List<SyncConflict>>((ref) => []);
final syncProgressProvider = StateProvider<SyncProgress?>((ref) => null);
final syncLastErrorProvider = StateProvider<String?>((ref) => null);

final autoSyncMessageCounterProvider = StateProvider<int>((ref) => 0);

void notifySyncMessageGenerated(Ref ref) {
  final autoEnabled = ref.read(syncAutoEnabledProvider);
  if (!autoEnabled) return;

  final counter = ref.read(autoSyncMessageCounterProvider) + 1;
  ref.read(autoSyncMessageCounterProvider.notifier).state = counter;

  final threshold = 5;
  if (counter >= threshold) {
    ref.read(autoSyncMessageCounterProvider.notifier).state = 0;
    final syncAsync = ref.read(syncServiceProvider);
    syncAsync.whenData((service) {
      if (service.isConnected()) {
        service.fullPush();
      }
    });
  }
}
