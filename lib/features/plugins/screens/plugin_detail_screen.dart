import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/installed_plugin.dart';
import '../providers/plugin_library_provider.dart';
import 'plugin_settings_form.dart';

Future<void> openPluginDetailScreen(BuildContext context, String id) async {
  final viewId = Uri(path: 'plugin-detail', queryParameters: {'id': id});
  if (floatOnDesktop(context, viewId.toString(), push: true)) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => PluginDetailScreen(pluginId: id)),
  );
}

/// One installed plugin: what it is, what it may do, its settings form and
/// the uninstall action.
class PluginDetailScreen extends ConsumerWidget {
  const PluginDetailScreen({super.key, required this.pluginId});

  final String pluginId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(pluginLibraryProvider).value ?? const [];
    final plugin = plugins.where((x) => x.id == pluginId).firstOrNull;
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = MediaQuery.of(context).padding.bottom + 20.0;
    if (plugin == null) {
      return GlazeScaffold(
        title: 'plugins_title'.tr(),
        showBackground: true,
        onBack: () => Navigator.of(context).pop(),
        body: const SizedBox.shrink(),
      );
    }
    final localizer = plugin.localizer(context.locale.toLanguageTag());
    final manifest = plugin.manifest;
    final notifier = ref.read(pluginLibraryProvider.notifier);
    final cover = manifest.cover;

    return GlazeScaffold(
      title: localizer.resolve(manifest.name),
      showBackground: true,
      extendBodyBehindHeader: true,
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad),
        children: [
          if (cover != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.file(
                    File(p.joinAll([plugin.directory, ...cover.split('/')])),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          MenuGroup(
            header: 'plugins_about'.tr(),
            headerIcon: Icons.info_outline_rounded,
            description: localizer.resolve(manifest.description),
            items: [
              MenuSwitchItem(
                label: 'plugins_enabled'.tr(),
                value: plugin.enabled,
                onChanged: (v) => notifier.setEnabled(plugin.id, v),
              ),
              MenuItem(
                icon: Icons.person_outline_rounded,
                label: 'plugins_author'.tr(),
                value: manifest.author ?? '—',
                onTap: () {},
              ),
              MenuItem(
                icon: Icons.tag_rounded,
                label: 'plugins_version'.tr(),
                value: manifest.version,
                onTap: () {},
              ),
            ],
          ),
          MenuGroup(
            header: 'plugins_permissions'.tr(),
            headerIcon: Icons.verified_user_outlined,
            description: _permissionsText(plugin),
            items: const [],
          ),
          if (manifest.settings.isNotEmpty)
            PluginSettingsForm(plugin: plugin, localizer: localizer),
          if (manifest.releaseNotes != null)
            MenuGroup(
              header: 'plugins_release_notes'.tr(),
              headerIcon: Icons.new_releases_outlined,
              description: localizer.resolve(manifest.releaseNotes),
              items: const [],
            ),
          MenuGroup(
            items: [
              MenuItem(
                icon: Icons.delete_outline_rounded,
                label: 'plugins_uninstall'.tr(),
                onTap: () => _confirmUninstall(context, ref, plugin),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _permissionsText(InstalledPlugin plugin) {
    final permissions = plugin.manifest.permissions;
    if (permissions.isEmpty) return 'plugins_permissions_none'.tr();
    return permissions
        .map((x) {
          final key = 'plugins_permission_$x';
          final label = key.tr();
          return '• ${label == key ? x : label}';
        })
        .join('\n');
  }

  void _confirmUninstall(
    BuildContext context,
    WidgetRef ref,
    InstalledPlugin plugin,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'plugins_uninstall'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline_rounded,
        description: 'plugins_uninstall_confirm'.tr(),
        buttonText: 'plugins_uninstall'.tr(),
        buttonIcon: Icons.delete_outline_rounded,
        onButtonTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          await ref.read(pluginLibraryProvider.notifier).uninstall(plugin.id);
          if (context.mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        },
      ),
    );
  }
}
