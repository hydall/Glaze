import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/glaze_switch.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/variation_chip.dart';
import '../compat/tavo/tavo_hub.dart';
import '../compat/tavo/tavo_manifest_converter.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_hub_provider.dart';
import '../providers/plugin_library_provider.dart';
import '../services/plugin_compatibility.dart';
import '../services/plugin_package_reader.dart';
import 'plugin_detail_screen.dart';
import 'plugin_hub_sheet.dart';

/// Opens the plugin list: a floating window on desktop, a pushed route on
/// phones.
Future<void> openPluginsScreen(BuildContext context) async {
  if (floatOnDesktop(context, 'plugins', push: true)) return;
  await Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const PluginsScreen()));
}

/// Installed plugins: import a package, switch each on or off,
/// open its details and settings.
class PluginsScreen extends ConsumerWidget {
  const PluginsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(pluginLibraryProvider);
    final locale = context.locale.toLanguageTag();
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = MediaQuery.of(context).padding.bottom + 20.0;
    final plugins = library.value ?? const <InstalledPlugin>[];
    final updates =
        ref.watch(pluginHubUpdatesProvider).value ?? const <String, Object>{};

    return GlazeScaffold(
      title: 'plugins_title'.tr(),
      showBackground: true,
      extendBodyBehindHeader: true,
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad),
        children: [
          MenuGroup(
            description: 'plugins_intro'.tr(),
            items: [
              MenuItem(
                icon: Icons.file_open_outlined,
                label: 'plugins_import'.tr(),
                subtitle: 'plugins_import_hint'.tr(),
                onTap: () => importPluginFromFile(context, ref),
              ),
              MenuItem(
                icon: Icons.link_rounded,
                label: 'plugins_install_from_link'.tr(),
                subtitle: 'plugins_install_from_link_hint'.tr(),
                onTap: () => _askForLink(context),
              ),
            ],
          ),
          MenuGroup(
            header: 'plugins_installed'.tr(),
            headerIcon: Icons.extension_rounded,
            description: library.isLoading
                ? null
                : plugins.isEmpty
                ? 'plugins_empty'.tr()
                : null,
            items: [
              for (final plugin in plugins)
                MenuItem(
                  icon: Icons.extension_outlined,
                  label: plugin.localizer(locale).resolve(plugin.manifest.name),
                  subtitle: [
                    if (plugin.manifest.author?.trim() case final a?
                        when a.isNotEmpty)
                      a,
                    plugin.manifest.version,
                  ].join(' · '),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Converted Tavo packages are marked; Glaze's own
                      // plugins need no label.
                      if (updates.containsKey(plugin.id)) ...[
                        VariationChip(name: 'plugins_hub_update_chip'.tr()),
                        const SizedBox(width: 6),
                      ],
                      if (plugin.manifest.compat == kTavoCompat) ...[
                        const VariationChip(name: 'Tavo'),
                        const SizedBox(width: 10),
                      ],
                      GlazeSwitch(
                        value: plugin.enabled,
                        onChanged: (v) => ref
                            .read(pluginLibraryProvider.notifier)
                            .setEnabled(plugin.id, v),
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert_rounded),
                        tooltip: 'plugins_more'.tr(),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _showPluginMenu(context, ref, plugin),
                      ),
                    ],
                  ),
                  onTap: () => openPluginDetailScreen(context, plugin.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Export and uninstall for one plugin of the list.
void _showPluginMenu(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin,
) {
  final name = plugin
      .localizer(context.locale.toLanguageTag())
      .resolve(plugin.manifest.name);
  GlazeBottomSheet.show<void>(
    context,
    title: name,
    items: [
      BottomSheetItem(
        label: 'plugins_export'.tr(),
        hint: 'plugins_export_hint_${pluginExportFormat(plugin)}'.tr(),
        icon: Icons.ios_share_rounded,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          exportPlugin(context, ref, plugin);
        },
      ),
      BottomSheetItem(
        label: 'plugins_uninstall'.tr(),
        icon: Icons.delete_outline_rounded,
        isDestructive: true,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          confirmPluginUninstall(context, ref, plugin);
        },
      ),
    ],
  );
}

/// Picks a plugin package and installs it, reporting the outcome in a toast.
Future<void> importPluginFromFile(BuildContext context, WidgetRef ref) async {
  final result = await FilePicker.pickFiles(
    type: Platform.isIOS ? FileType.any : FileType.custom,
    allowedExtensions: Platform.isIOS ? null : const ['glzp', 'tpg', 'zip'],
    withData: true,
  );
  final picked = result?.files.singleOrNull;
  if (picked == null) return;
  try {
    final bytes = picked.bytes ?? await File(picked.path!).readAsBytes();
    if (!context.mounted) return;
    await installPluginPackage(context, ref, readPluginPackage(bytes));
  } catch (e) {
    if (!context.mounted) return;
    _installFailed(context, e);
  }
}

/// Installs [package] the way every source does: a package that relies on
/// features Glaze lacks, or that replaces an installed plugin, is installed
/// only after the user confirms, and new permissions are offered right
/// after. Null when the user backed out; throws when the install fails.
Future<InstalledPlugin?> installPluginPackage(
  BuildContext context,
  WidgetRef ref,
  PluginPackage package, {
  String? hubSlug,
}) async {
  final unsupported = unsupportedPluginFeatures(package);
  if (unsupported.isNotEmpty) {
    final proceed = await _confirmUnsupported(context, unsupported);
    if (proceed != true || !context.mounted) return null;
  }
  final before = (ref.read(pluginLibraryProvider).value ?? const [])
      .where((x) => x.id == package.manifest.id)
      .firstOrNull;
  final sameAuthor =
      before != null && isSamePluginAuthor(before.manifest, package.manifest);
  if (before != null) {
    final proceed = await _confirmUpdate(
      context,
      before,
      package.manifest,
      sameAuthor: sameAuthor,
    );
    if (proceed != true || !context.mounted) return null;
  }
  final installed = await ref
      .read(pluginLibraryProvider.notifier)
      .installPackage(package, hubSlug: hubSlug);
  if (!context.mounted) return installed;
  final name = installed
      .localizer(context.locale.toLanguageTag())
      .resolve(installed.manifest.name);
  GlazeToast.show(
    context,
    'plugins_installed_toast'.tr(namedArgs: {'name': name}),
  );
  // New permissions start off; offer to switch them on right away.
  final asked = installed.manifest.permissions.where(
    (x) => !sameAuthor || !before.manifest.permissions.contains(x),
  );
  if (asked.isNotEmpty) {
    await showPluginPermissionsSheet(context, installed.id);
  }
  return installed;
}

void _installFailed(BuildContext context, Object e) => GlazeToast.show(
  context,
  'plugins_install_failed'.tr(namedArgs: {'error': '$e'}),
  isError: true,
  showCopyButton: true,
);

/// Asks for a hub link and opens the plugin it points at.
void _askForLink(BuildContext context) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'plugins_install_from_link'.tr(),
    input: BottomSheetInput(
      placeholder: 'https://$kTavoHubSite/plugins/…',
      confirmLabel: 'plugins_hub_open'.tr(),
      onConfirm: (value) {
        Navigator.of(context, rootNavigator: true).pop();
        final uri = Uri.tryParse(value.trim());
        if (uri == null || !openPluginHubLink(context, uri)) {
          GlazeToast.show(context, 'plugins_hub_bad_link'.tr(), isError: true);
        }
      },
    ),
  );
}

Future<bool?> _confirmUnsupported(
  BuildContext context,
  Set<UnsupportedPluginFeature> features,
) {
  final list = features
      .map((f) => '• ${'plugins_unsupported_${f.name}'.tr()}')
      .join('\n');
  return GlazeBottomSheet.show<bool>(
    context,
    title: 'plugins_unsupported_title'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.warning_amber_rounded,
      description: '${'plugins_unsupported_body'.tr()}\n\n$list',
      buttonText: 'plugins_unsupported_install'.tr(),
      buttonIcon: Icons.download_rounded,
      onButtonTap: () => Navigator.of(context, rootNavigator: true).pop(true),
    ),
  );
}

/// Asks before [installed] is replaced by a package with the same id. A
/// different author means a different plugin as far as Glaze can tell: it
/// starts over, without the old one's permissions and data.
Future<bool?> _confirmUpdate(
  BuildContext context,
  InstalledPlugin installed,
  PluginManifest next, {
  required bool sameAuthor,
}) {
  final locale = context.locale.toLanguageTag();
  final name = installed.localizer(locale).resolve(installed.manifest.name);
  final added = [
    for (final x in next.permissions)
      if (!installed.manifest.permissions.contains(x))
        '• ${_permissionName(x)}',
  ];
  final lines = [
    'plugins_update_version'.tr(
      namedArgs: {'from': installed.manifest.version, 'to': next.version},
    ),
    if (!sameAuthor)
      'plugins_update_author_changed'.tr(
        namedArgs: {
          'from': installed.manifest.author ?? '—',
          'to': next.author ?? '—',
        },
      ),
    if (sameAuthor && added.isNotEmpty) ...[
      'plugins_update_new_permissions'.tr(),
      ...added,
    ],
  ];
  return GlazeBottomSheet.show<bool>(
    context,
    title: 'plugins_update_title'.tr(namedArgs: {'name': name}),
    bigInfo: BottomSheetBigInfo(
      icon: sameAuthor
          ? Icons.system_update_alt_rounded
          : Icons.gpp_maybe_outlined,
      description: lines.join('\n'),
      buttonText: 'plugins_update_confirm'.tr(),
      buttonIcon: Icons.download_rounded,
      onButtonTap: () => Navigator.of(context, rootNavigator: true).pop(true),
    ),
  );
}

String _permissionName(String permission) {
  final key = 'plugins_permission_name_${permission.replaceAll('.', '_')}';
  final text = key.tr();
  return text == key ? permission : text;
}
