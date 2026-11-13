import 'dart:typed_data';

import '../../plugins/services/plugin_snapshot.dart';
import '../../plugins/services/plugin_store.dart';
import '../sync_repo_interfaces.dart';

/// Cloud-sync adapter for the installed plugins.
class PluginSyncStore implements SyncPluginStore {
  PluginSyncStore(PluginStore store) : _snapshot = PluginSnapshot(store);

  final PluginSnapshot _snapshot;

  @override
  Future<Map<String, dynamic>> read() => _snapshot.syncPayload();

  @override
  Future<Uint8List> pack(String id) => _snapshot.pack(id);

  @override
  Future<void> apply(
    Map<String, dynamic> data,
    Future<Uint8List> Function(String id) download,
  ) => _snapshot.applySync(data, download);
}
