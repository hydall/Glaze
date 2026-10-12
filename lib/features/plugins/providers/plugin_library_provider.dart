import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/platform_paths.dart';
import '../models/installed_plugin.dart';
import '../services/plugin_package_reader.dart';
import '../services/plugin_store.dart';

final pluginStoreProvider = FutureProvider<PluginStore>((ref) async {
  final base = await getAppDataDir();
  return PluginStore(
    root: p.join(base, 'plugins'),
    dataRoot: p.join(base, 'plugin_data'),
  );
});

/// Installed plugins in install order (= runtime order).
class PluginLibraryNotifier extends AsyncNotifier<List<InstalledPlugin>> {
  @override
  Future<List<InstalledPlugin>> build() async {
    final store = await ref.watch(pluginStoreProvider.future);
    return store.loadAll();
  }

  Future<PluginStore> get _store => ref.read(pluginStoreProvider.future);

  /// Validates and installs a `.tpg`. Throws [PluginManifestException] with a
  /// readable reason when the package is rejected.
  Future<InstalledPlugin> install(Uint8List bytes) async {
    final package = readPluginPackage(bytes);
    final installed = await (await _store).install(package);
    final current = [...(state.value ?? const <InstalledPlugin>[])];
    final index = current.indexWhere((x) => x.id == installed.id);
    if (index >= 0) {
      current[index] = installed;
    } else {
      current.add(installed);
    }
    state = AsyncData(current);
    return installed;
  }

  Future<void> uninstall(String id) async {
    await (await _store).uninstall(id);
    state = AsyncData([
      for (final x in state.value ?? const <InstalledPlugin>[])
        if (x.id != id) x,
    ]);
  }

  Future<void> setEnabled(String id, bool enabled) =>
      _update(id, (x) => x.copyWith(enabled: enabled));

  Future<void> setConfigValue(String id, String key, Object? value) =>
      _update(id, (x) => x.copyWith(config: {...x.config, key: value}));

  Future<void> resetConfigValue(String id, String key) =>
      _update(id, (x) => x.copyWith(config: {...x.config}..remove(key)));

  Future<void> _update(
    String id,
    InstalledPlugin Function(InstalledPlugin) change,
  ) async {
    final current = state.value;
    if (current == null) return;
    final index = current.indexWhere((x) => x.id == id);
    if (index < 0) return;
    final next = change(current[index]);
    state = AsyncData([...current]..[index] = next);
    await (await _store).save(next);
  }
}

final pluginLibraryProvider =
    AsyncNotifierProvider<PluginLibraryNotifier, List<InstalledPlugin>>(
      PluginLibraryNotifier.new,
    );

/// Enabled plugins only, in runtime order.
final enabledPluginsProvider = Provider<List<InstalledPlugin>>((ref) {
  final all = ref.watch(pluginLibraryProvider).value ?? const [];
  return [
    for (final x in all)
      if (x.enabled) x,
  ];
});
