export '../../core/application/sync_repo_interfaces.dart';
export '../../shared/application/sync_theme_store.dart';

import '../extensions/models/extension_preset.dart';
import '../extensions/models/extensions_settings.dart';
import '../extensions/models/info_block.dart';
import 'sync_models.dart';

abstract class SyncExtensionPresetStore {
  Future<List<ExtensionPreset>> getAll();
  Future<ExtensionPreset?> getById(String id);
  Future<void> put(ExtensionPreset preset);
  Future<void> delete(String id);
}

abstract class SyncExtensionsSettingsStore {
  Future<ExtensionsSettings> get();
  Future<void> put(ExtensionsSettings settings);
}

abstract class SyncInfoBlockStore {
  Future<List<String>> getAllSessionIds();
  Future<List<InfoBlock>> getBySessionId(String sessionId);
  Future<void> deleteBySessionId(String sessionId);
  Future<void> insert(InfoBlock block);
}

abstract class SyncManifestProvider {
  Future<SyncManifest> buildLocalManifest({SyncManifest? cloudManifest});
  Future<SyncManifest> readLocalManifest();
  Future<void> writeLocalManifest(SyncManifest manifest);
  Future<void> clearLocalManifest();
  Future<void> clearDeleted();
  Future<String> getDeviceId();
}
