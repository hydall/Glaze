import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../compat/tavo/tavo_hub.dart';
import 'plugin_library_provider.dart';

final tavoHubClientProvider = Provider<TavoHubClient>((ref) => TavoHubClient());

/// Plugins installed from the hub that have a newer version there, by id.
/// Looked up once per app run (and again after an install); an unreachable
/// hub just means no updates are shown.
final pluginHubUpdatesProvider = FutureProvider<Map<String, TavoHubPlugin>>((
  ref,
) async {
  final plugins = await ref.watch(pluginLibraryProvider.future);
  final fromHub = {
    for (final x in plugins)
      if (x.hubSlug != null) x.id: x,
  };
  if (fromHub.isEmpty) return const {};
  try {
    final published = await ref
        .read(tavoHubClientProvider)
        .lookup(fromHub.keys);
    return {
      for (final e in published.entries)
        if (fromHub[e.key] case final installed?)
          if (e.value.version.isNotEmpty &&
              isNewerPluginVersion(e.value.version, installed.manifest.version))
            e.key: e.value,
    };
  } catch (e) {
    debugPrint('[PluginHub] update check failed: $e');
    return const {};
  }
});
