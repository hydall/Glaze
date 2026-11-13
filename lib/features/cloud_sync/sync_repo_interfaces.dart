import 'dart:typed_data';

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

/// The installed plugins as one sync entity. Packages and plugin data
/// travel as one zip per plugin, next to the entity.
abstract class SyncPluginStore {
  /// `{"items": [{"record", "hash"}], "shared"}`: each plugin's record
  /// without its permissions and a hash of its files, in install order.
  Future<Map<String, dynamic>> read();

  /// Plugin [id]'s files as a zip.
  Future<Uint8List> pack(String id);

  /// Makes this device's plugins those of [data], fetching each plugin
  /// whose files differ with [download].
  Future<void> apply(
    Map<String, dynamic> data,
    Future<Uint8List> Function(String id) download,
  );
}

abstract class SyncManifestProvider {
  Future<SyncManifest> buildLocalManifest({
    SyncManifest? cloudManifest,
    bool applyAcceptedHashes = true,
  });
  Future<SyncManifest> readLocalManifest();
  Future<void> writeLocalManifest(SyncManifest manifest);
  Future<void> clearLocalManifest();
  Future<void> clearDeleted();
  Future<String> getDeviceId();
  Future<bool> isDeleted(String type, String id);
}
