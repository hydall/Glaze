import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../services/plugin_store.dart';
import 'plugin_html_inliner.dart';
import 'tavo_bridge_service.dart';
import 'tavo_file_store.dart';

/// Builds the argument of `window.glazePlugins.setup(...)`: one entry per
/// enabled plugin with its entry source, `/chat` fragments, effective config,
/// i18n snapshot, storage and the methods it may call.
class PluginRuntimePayloadBuilder {
  const PluginRuntimePayloadBuilder({required this.store});

  final PluginStore store;

  Future<Map<String, Object?>> build({
    required List<InstalledPlugin> plugins,
    required String locale,
    required String sdkSource,
    required Map<String, dynamic> chatVars,
    required Map<String, dynamic> globalVars,
  }) async {
    final entries = <Map<String, Object?>>[];
    for (final plugin in plugins) {
      try {
        entries.add(
          await pluginEntry(
            plugin,
            locale: locale,
            chatVars: chatVars,
            globalVars: globalVars,
          ),
        );
      } catch (e) {
        debugPrint('[PluginRuntime] ${plugin.id} skipped: $e');
      }
    }
    return {'sdk': sdkSource, 'plugins': entries};
  }

  Future<Map<String, Object?>> pluginEntry(
    InstalledPlugin plugin, {
    required String locale,
    required Map<String, dynamic> chatVars,
    required Map<String, dynamic> globalVars,
  }) async {
    final manifest = plugin.manifest;
    final localizer = plugin.localizer(locale);
    final entryPath = manifest.entry;
    final entryBytes = entryPath == null
        ? null
        : await store.readPackageFile(plugin.id, entryPath);

    final fragments = <Map<String, Object?>>[];
    for (final (index, fragment) in manifest.fragments.indexed) {
      if (fragment.mount.surface != PluginMountSurface.chat) {
        debugPrint(
          '[PluginRuntime] ${plugin.id}/${fragment.id}: message fragments '
          'are not supported yet',
        );
        continue;
      }
      final bytes = await store.readPackageFile(plugin.id, fragment.src);
      if (bytes == null) continue;
      final html = await inlinePluginAssets(
        utf8.decode(bytes, allowMalformed: true),
        store.readPackageFile,
      );
      fragments.add({
        'id': fragment.id,
        'html': html,
        'order': (fragment.mount.slot == 'start' ? 0 : 10) + index,
      });
    }

    final files = TavoFileStore(dataDir: store.dataDir(plugin.id));
    return {
      'pluginId': plugin.id,
      'entry': entryBytes == null
          ? null
          : utf8.decode(entryBytes, allowMalformed: true),
      'fragments': fragments,
      'config': plugin.effectiveConfig(localizer),
      'i18n': manifest.specVersion >= 2 ? localizer.runtimeSnapshot() : null,
      'vars': {'chat': chatVars, 'global': globalVars},
      'storage': await files.readStorage(),
      'methods': tavoMethodsFor(plugin),
    };
  }
}
