import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/state/db_provider.dart';
import '../../../core/utils/platform_paths.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../runtime/plugin_variable_store.dart';
import '../services/plugin_data_transfer.dart';
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

/// The one store behind every chat's `glaze.variables`.
final pluginVariableStoreProvider = FutureProvider<PluginVariableStore>((
  ref,
) async {
  final store = await ref.watch(pluginStoreProvider.future);
  return PluginVariableStore(
    chatRepo: ref.watch(chatRepoProvider),
    globalFile: (id) => File(p.join(store.dataDir(id), 'variables.json')),
    sharedFile: File(p.join(store.dataRoot, '_shared_variables.json')),
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

  /// Installs a package already read with [readPluginPackage]; [hubSlug]
  /// when it came from the hub.
  Future<InstalledPlugin> installPackage(
    PluginPackage package, {
    String? hubSlug,
  }) async {
    final previous = (state.value ?? const <InstalledPlugin>[])
        .where((x) => x.id == package.manifest.id)
        .firstOrNull;
    final installed = await (await _store).install(package, hubSlug: hubSlug);
    // Another author's package starts over; what the old plugin kept in
    // chats is not its to read.
    if (previous != null &&
        !isSamePluginAuthor(previous.manifest, package.manifest)) {
      await _forgetVariables(installed.id);
    }
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
    await _forgetVariables(id);
    state = AsyncData([
      for (final x in state.value ?? const <InstalledPlugin>[])
        if (x.id != id) x,
    ]);
  }

  Future<void> _forgetVariables(String id) async {
    try {
      await (await ref.read(
        pluginVariableStoreProvider.future,
      )).forgetPlugin(id);
    } catch (e) {
      debugPrint('[PluginLibrary] $id variables not cleared: $e');
    }
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

  /// Gives back or takes away every one of [permissions] at once; a
  /// permission that asks comes back as Ask.
  Future<void> setPermissions(
    String id,
    Iterable<String> permissions,
    bool allowed,
  ) => _update(
    id,
    (x) => x.copyWith(
      revoked: allowed
          ? ({...x.revoked}..removeAll(permissions))
          : {...x.revoked, ...permissions},
      grants: allowed ? null : ({...x.grants}..removeAll(permissions)),
    ),
  );

  /// Off takes `network` away; listed keeps it to [InstalledPlugin.networkHosts]
  /// (the manifest's hosts show up switched off); any lets it reach every
  /// host.
  Future<void> setNetworkMode(String id, PluginNetworkMode mode) => _update(
    id,
    (x) => x.copyWith(
      revoked: mode == PluginNetworkMode.off
          ? {...x.revoked, PluginPermission.network}
          : ({...x.revoked}..remove(PluginPermission.network)),
      networkHosts: switch (mode) {
        PluginNetworkMode.off => null,
        PluginNetworkMode.any => () => null,
        PluginNetworkMode.listed => () => x.networkHosts ?? <String>{},
      },
    ),
  );

  /// Lets the plugin reach the user's own network, or stops it.
  Future<void> setLocalNetwork(String id, bool allowed) =>
      _update(id, (x) => x.copyWith(localNetwork: allowed));

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

  /// Everything [id] keeps, for a JSON file.
  Future<Map<String, Object?>> exportData(String id) async {
    final plugin = (state.value ?? const <InstalledPlugin>[]).firstWhere(
      (x) => x.id == id,
    );
    return (await _dataTransfer).export(plugin);
  }

  /// Replaces what [id] keeps with a file made by [exportData] and starts
  /// its frames over. Returns how many chats in the file were not found.
  Future<int> importData(String id, Object? json) async {
    final plugin = (state.value ?? const <InstalledPlugin>[]).firstWhere(
      (x) => x.id == id,
    );
    final result = await (await _dataTransfer).import(plugin, json);
    await _update(
      id,
      (x) =>
          x.copyWith(config: result.config, dataRevision: x.dataRevision + 1),
    );
    return result.skippedChats;
  }

  Future<PluginDataTransfer> get _dataTransfer async => PluginDataTransfer(
    store: await _store,
    variables: await ref.read(pluginVariableStoreProvider.future),
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
