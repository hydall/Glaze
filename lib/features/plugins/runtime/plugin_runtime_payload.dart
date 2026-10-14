import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../chat/bridge/chat_webview_environment.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../services/plugin_localizer.dart';
import '../services/plugin_store.dart';
import 'api/files_api.dart';
import 'plugin_bridge_service.dart';
import 'plugin_file_store.dart';
import 'plugin_html_inliner.dart';

/// Builds the argument of `window.glazePlugins.setup(...)`: one entry per
/// enabled plugin with its main script, panels, effective settings, i18n
/// snapshot, storage, message actions and the methods it may call.
class PluginRuntimePayloadBuilder {
  const PluginRuntimePayloadBuilder({required this.store});

  final PluginStore store;

  Future<Map<String, Object?>> build({
    required List<InstalledPlugin> plugins,
    required String locale,
    required String sdkSource,
    required Map<String, String> compatSources,
    required Future<Map<String, dynamic>> Function(
      InstalledPlugin plugin,
      String scope,
    )
    readVars,
  }) async {
    final entries = <Map<String, Object?>>[];
    for (final plugin in plugins) {
      try {
        final variables = plugin.allows(PluginPermission.variables);
        entries.add(
          await pluginEntry(
            plugin,
            locale: locale,
            chatVars: variables ? await readVars(plugin, 'chat') : const {},
            globalVars: variables ? await readVars(plugin, 'global') : const {},
          ),
        );
      } catch (e) {
        debugPrint('[PluginRuntime] ${plugin.id} skipped: $e');
      }
    }
    return {
      'sdk': sdkSource,
      'compat': compatSources,
      'plugins': entries,
      'rtcToken': chatWebViewRtcToken,
    };
  }

  Future<Map<String, Object?>> pluginEntry(
    InstalledPlugin plugin, {
    required String locale,
    Map<String, dynamic> chatVars = const {},
    Map<String, dynamic> globalVars = const {},
  }) async {
    final manifest = plugin.manifest;
    final localizer = plugin.localizer(locale);
    final mainPath = manifest.main;
    final mainBytes = mainPath == null
        ? null
        : await store.readPackageFile(plugin.id, mainPath);

    final panels = <Map<String, Object?>>[];
    for (final (index, panel) in manifest.panels.indexed) {
      final bytes = await store.readPackageFile(plugin.id, panel.src);
      if (bytes == null) continue;
      final html = await inlinePluginAssets(
        utf8.decode(bytes, allowMalformed: true),
        store.readPackageFile,
      );
      panels.add({
        ...panel.toJson(),
        'html': html,
        'order': (panel.slot == 'start' ? 0 : 10) + index,
      });
    }

    final files = PluginFileStore(dataDir: store.dataDir(plugin.id));
    return {
      'pluginId': plugin.id,
      'compat': manifest.compat,
      'main': mainBytes == null
          ? null
          : utf8.decode(mainBytes, allowMalformed: true),
      'panels': panels,
      'config': plugin.effectiveConfig(localizer),
      'i18n': localizer.catalogs.isEmpty ? null : localizer.runtimeSnapshot(),
      'vars': {'chat': chatVars, 'global': globalVars},
      'storage': await files.readStorage(),
      'storageQuota': PluginFileStore.maxStorageBytes,
      'methods': pluginMethodsFor(plugin),
      'events': pluginEventsFor(plugin),
      // true: any host; a list: only those hosts; false: none.
      'network': !plugin.allows(PluginPermission.network)
          ? false
          : plugin.networkHosts == null
          ? true
          : (plugin.networkHosts!.toList()..sort()),
      'localNetwork':
          plugin.allows(PluginPermission.network) && plugin.localNetwork,
      'messageActions': await messageActions(plugin, localizer),
    };
  }

  /// Message actions with resolved labels and icons as data URLs.
  Future<List<Map<String, Object?>>> messageActions(
    InstalledPlugin plugin,
    PluginLocalizer localizer,
  ) async => [
    for (final a in plugin.manifest.messageActions)
      {
        'id': a.id,
        'label': localizer.resolve(a.label, fallback: a.id),
        'role': a.role,
        'icon': await iconDataUrl(plugin, a.icon),
      },
  ];

  Future<String?> iconDataUrl(InstalledPlugin plugin, String? path) async {
    if (path == null) return null;
    final bytes = await store.readPackageFile(plugin.id, path);
    if (bytes == null || bytes.length > 512 * 1024) return null;
    return 'data:${pluginMimeType(path)};base64,${base64Encode(bytes)}';
  }

  /// Sources of a file handler's own scripts, in order.
  Future<List<Map<String, String>>> fileHandlerScripts(
    InstalledPlugin plugin,
    PluginFileHandler handler,
  ) async => [
    for (final path in handler.scripts)
      {
        'name': path,
        'source': utf8.decode(
          await store.readPackageFile(plugin.id, path) ?? const [],
          allowMalformed: true,
        ),
      },
  ];
}
