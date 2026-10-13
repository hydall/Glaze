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
import '../models/installed_plugin.dart';
import '../providers/plugin_library_provider.dart';
import '../services/plugin_compatibility.dart';
import '../services/plugin_package_reader.dart';
import 'plugin_detail_screen.dart';

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
                    if (plugin.manifest.author != null) plugin.manifest.author!,
                    'v${plugin.manifest.version}',
                  ].join(' · '),
                  trailing: GlazeSwitch(
                    value: plugin.enabled,
                    onChanged: (v) => ref
                        .read(pluginLibraryProvider.notifier)
                        .setEnabled(plugin.id, v),
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

/// Picks a plugin package and installs it, reporting the outcome in a toast.
/// A package that relies on features Glaze lacks is installed only after the
/// user confirms a warning.
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
    final package = readPluginPackage(bytes);
    final unsupported = unsupportedPluginFeatures(package);
    if (unsupported.isNotEmpty) {
      if (!context.mounted) return;
      final proceed = await _confirmUnsupported(context, unsupported);
      if (proceed != true) return;
    }
    final installed = await ref
        .read(pluginLibraryProvider.notifier)
        .installPackage(package);
    if (!context.mounted) return;
    final name = installed
        .localizer(context.locale.toLanguageTag())
        .resolve(installed.manifest.name);
    GlazeToast.show(
      context,
      'plugins_installed_toast'.tr(namedArgs: {'name': name}),
    );
  } catch (e) {
    if (!context.mounted) return;
    GlazeToast.show(
      context,
      'plugins_install_failed'.tr(namedArgs: {'error': '$e'}),
      isError: true,
      showCopyButton: true,
    );
  }
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
