import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/platform_paths.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../services/plugin_package_reader.dart';
import '../services/plugin_store.dart';

/// A long-lived [Ref] the plugin API reads app state and services through.
final pluginRefProvider = Provider<Ref>((ref) => ref);

final pluginStoreProvider = FutureProvider<PluginStore>((ref) async {
  final base = await getAppDataDir();
  return PluginStore(
    root: p.join(base, 'plugins'),
    dataRoot: p.join(base, 'plugin_data'),
  );
});

/// How a permission that asks first is set up for one plugin.
enum PluginConsentMode { ask, always, off }

/// Internet access of one plugin.
enum PluginNetworkMode { off, listed, any }

/// Installed plugins in install order (= runtime order).
class PluginLibraryNotifier extends AsyncNotifier<List<InstalledPlugin>> {
  @override
  Future<List<InstalledPlugin>> build() async {
    final store = await ref.watch(pluginStoreProvider.future);
    await store.clearTemporaryFiles();
    return store.loadAll();
  }

  Future<PluginStore> get _store => ref.read(pluginStoreProvider.future);

  /// Validates and installs a package. Throws [PluginManifestException] with
  /// a readable reason when the package is rejected.
  Future<InstalledPlugin> install(Uint8List bytes) =>
      installPackage(readPluginPackage(bytes));

  /// Installs a package already read with [readPluginPackage].
  Future<InstalledPlugin> installPackage(PluginPackage package) async {
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

  Future<void> allowAlways(String id, String consent) =>
      _update(id, (x) => x.copyWith(grants: {...x.grants, consent}));

  /// Gives back or takes away a manifest permission.
  Future<void> setPermission(String id, String permission, bool allowed) =>
      _update(
        id,
        (x) => x.copyWith(
          revoked: allowed
              ? ({...x.revoked}..remove(permission))
              : {...x.revoked, permission},
          grants: allowed ? null : ({...x.grants}..remove(permission)),
        ),
      );

  /// Off takes `network` away; listed keeps it to [InstalledPlugin.networkHosts]
  /// (starting from the manifest's hosts); any lets it reach every host.
  Future<void> setNetworkMode(String id, PluginNetworkMode mode) => _update(
    id,
    (x) => x.copyWith(
      revoked: mode == PluginNetworkMode.off
          ? {...x.revoked, PluginPermission.network}
          : ({...x.revoked}..remove(PluginPermission.network)),
      networkHosts: switch (mode) {
        PluginNetworkMode.off => null,
        PluginNetworkMode.any => () => null,
        PluginNetworkMode.listed =>
          () => x.networkHosts ?? {...x.manifest.hosts},
      },
    ),
  );

  /// Adds [host] to, or removes it from, the plugin's allowed hosts.
  Future<void> setHostAllowed(String id, String host, bool allowed) => _update(
    id,
    (x) => x.copyWith(
      networkHosts: () => allowed
          ? {...?x.networkHosts, host}
          : ({...?x.networkHosts}..remove(host)),
    ),
  );

  /// For a permission that asks first: ask every time, allow for good, or
  /// take it away.
  Future<void> setConsentMode(
    String id,
    String consent,
    PluginConsentMode mode,
  ) => _update(
    id,
    (x) => x.copyWith(
      revoked: mode == PluginConsentMode.off
          ? {...x.revoked, consent}
          : ({...x.revoked}..remove(consent)),
      grants: mode == PluginConsentMode.always
          ? {...x.grants, consent}
          : ({...x.grants}..remove(consent)),
    ),
  );

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
