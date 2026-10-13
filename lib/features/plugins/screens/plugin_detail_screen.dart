import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/glaze_switch.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_library_provider.dart';
import '../providers/plugin_network_log_provider.dart';
import '../runtime/plugin_api.dart';
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
    final cover = manifest.icon;

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
            description: manifest.permissions.isEmpty
                ? 'plugins_permissions_none'.tr()
                : null,
            items: [
              for (final permission in manifest.permissions)
                _permissionItem(context, notifier, plugin, permission),
            ],
          ),
          _NetworkLog(plugin: plugin),
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

  static const _icons = {
    PluginPermission.composer: Icons.edit_note_rounded,
    PluginPermission.messages: Icons.chat_bubble_outline_rounded,
    PluginPermission.variables: Icons.data_object_rounded,
    PluginPermission.files: Icons.folder_outlined,
    PluginPermission.generate: Icons.auto_awesome_outlined,
    PluginPermission.images: Icons.image_outlined,
    PluginPermission.library: Icons.library_books_outlined,
    PluginPermission.network: Icons.public_rounded,
    'tts': Icons.record_voice_over_outlined,
  };

  static String _text(String key, String fallback) {
    final text = key.tr();
    return text == key ? fallback : text;
  }

  Widget _permissionItem(
    BuildContext context,
    PluginLibraryNotifier notifier,
    InstalledPlugin plugin,
    String permission,
  ) {
    final icon = _icons[permission] ?? Icons.help_outline_rounded;
    final label = _text('plugins_permission_name_$permission', permission);
    final subtitle = _text('plugins_permission_$permission', '');
    if (!PluginPermission.all.contains(permission)) {
      // Asked for, but nothing in Glaze provides it (e.g. Tavo's `tts`).
      return MenuItem(
        icon: icon,
        label: label,
        subtitle: subtitle.isEmpty ? null : subtitle,
        onTap: () {},
      );
    }
    if (PluginConsent.values.any((c) => c.name == permission)) {
      final mode = !plugin.allows(permission)
          ? PluginConsentMode.off
          : plugin.grants.contains(permission)
          ? PluginConsentMode.always
          : PluginConsentMode.ask;
      return MenuItem(
        icon: icon,
        label: label,
        subtitle: subtitle,
        value: 'plugins_consent_mode_${mode.name}'.tr(),
        onTap: () =>
            _pickConsentMode(context, notifier, plugin, permission, mode),
      );
    }
    if (permission == PluginPermission.network) {
      final mode = _networkMode(plugin);
      return MenuItem(
        icon: icon,
        label: label,
        subtitle: subtitle,
        value: 'plugins_network_mode_${mode.name}'.tr(),
        onTap: () => _pickNetworkMode(context, notifier, plugin, mode),
      );
    }
    final allowed = plugin.allows(permission);
    return MenuItem(
      icon: icon,
      label: label,
      subtitle: subtitle,
      trailing: GlazeSwitch(
        value: allowed,
        onChanged: (v) => notifier.setPermission(plugin.id, permission, v),
      ),
      onTap: () => notifier.setPermission(plugin.id, permission, !allowed),
    );
  }

  static PluginNetworkMode _networkMode(InstalledPlugin plugin) =>
      !plugin.allows(PluginPermission.network)
      ? PluginNetworkMode.off
      : plugin.networkHosts == null
      ? PluginNetworkMode.any
      : PluginNetworkMode.listed;

  void _pickNetworkMode(
    BuildContext context,
    PluginLibraryNotifier notifier,
    InstalledPlugin plugin,
    PluginNetworkMode current,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'plugins_permission_name_network'.tr(),
      items: [
        for (final mode in PluginNetworkMode.values)
          BottomSheetItem(
            label: 'plugins_network_mode_${mode.name}'.tr(),
            hint: 'plugins_network_mode_${mode.name}_hint'.tr(),
            icon: mode == current ? Icons.check_rounded : null,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              notifier.setNetworkMode(plugin.id, mode);
            },
          ),
      ],
    );
  }

  void _pickConsentMode(
    BuildContext context,
    PluginLibraryNotifier notifier,
    InstalledPlugin plugin,
    String permission,
    PluginConsentMode current,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: _text('plugins_permission_name_$permission', permission),
      items: [
        for (final mode in PluginConsentMode.values)
          BottomSheetItem(
            label: 'plugins_consent_mode_${mode.name}'.tr(),
            hint: 'plugins_consent_mode_${mode.name}_hint'.tr(),
            icon: mode == current ? Icons.check_rounded : null,
            isDestructive: mode == PluginConsentMode.off,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              notifier.setConsentMode(plugin.id, permission, mode);
            },
          ),
      ],
    );
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

/// Hosts the plugin's frames loaded from, or were stopped from loading from.
class _NetworkLog extends ConsumerWidget {
  const _NetworkLog({required this.plugin});

  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = PluginDetailScreen._networkMode(plugin);
    final listed = mode == PluginNetworkMode.listed;
    final notifier = ref.read(pluginLibraryProvider.notifier);
    final log =
        ref.watch(pluginNetworkLogProvider(plugin.id)).value ?? const {};
    final records = log.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    // Allowed hosts not seen yet still belong on the list.
    final unseen = [
      for (final h
          in (plugin.networkHosts ?? const <String>{}).toList()..sort())
        if (!log.containsKey(h)) h,
    ];
    final format = DateFormat.MMMd(context.locale.toLanguageTag()).add_Hm();
    final empty = records.isEmpty && unseen.isEmpty;
    return MenuGroup(
      header: 'plugins_network'.tr(),
      headerIcon: Icons.public_rounded,
      description: switch (mode) {
        PluginNetworkMode.off => 'plugins_network_offline'.tr(),
        PluginNetworkMode.listed => 'plugins_network_listed'.tr(),
        PluginNetworkMode.any =>
          empty ? 'plugins_network_empty'.tr() : 'plugins_network_hint'.tr(),
      },
      items: [
        for (final h in unseen)
          _hostItem(notifier, h, allowed: true, listed: listed),
        for (final r in records)
          // Not hosts: shown as they were, never switched per host.
          if (r.host == 'navigation' || r.host == 'webrtc')
            MenuItem(
              icon: r.lastBlocked
                  ? Icons.block_rounded
                  : Icons.swap_horiz_rounded,
              label: 'plugins_network_${r.host}'.tr(),
              subtitle: r.lastBlocked ? 'plugins_network_blocked'.tr() : null,
              value: format.format(
                DateTime.fromMillisecondsSinceEpoch(r.lastSeen),
              ),
              onTap: () {},
            )
          else
            _hostItem(
              notifier,
              r.host,
              allowed: listed ? plugin.allowsHost(r.host) : !r.lastBlocked,
              listed: listed,
              when: format.format(
                DateTime.fromMillisecondsSinceEpoch(r.lastSeen),
              ),
            ),
        if (listed)
          MenuItem(
            icon: Icons.add_rounded,
            label: 'plugins_network_add'.tr(),
            onTap: () => _addHost(context, notifier),
          ),
        if (records.isNotEmpty)
          MenuItem(
            icon: Icons.delete_sweep_outlined,
            label: 'plugins_network_clear'.tr(),
            onTap: () =>
                ref.read(pluginNetworkLogProvider(plugin.id).notifier).clear(),
          ),
      ],
    );
  }

  /// In the listed mode a tap allows or disallows the host.
  Widget _hostItem(
    PluginLibraryNotifier notifier,
    String host, {
    required bool allowed,
    required bool listed,
    String? when,
  }) {
    final rule = plugin.networkHosts?.contains(host) ?? false;
    return MenuItem(
      icon: allowed ? Icons.language_rounded : Icons.block_rounded,
      label: host,
      subtitle: listed
          ? (allowed
                ? 'plugins_network_allowed'.tr()
                : 'plugins_network_not_allowed'.tr())
          : allowed
          ? null
          : 'plugins_network_blocked'.tr(),
      // No room for the time next to the switch.
      value: listed ? null : when,
      trailing: listed
          ? GlazeSwitch(
              value: allowed,
              onChanged: (v) => notifier.setHostAllowed(plugin.id, host, v),
            )
          : null,
      // A host allowed by a `*.` rule cannot be switched off on its own.
      onTap: listed && (rule || !allowed)
          ? () => notifier.setHostAllowed(plugin.id, host, !allowed)
          : () {},
    );
  }

  void _addHost(BuildContext context, PluginLibraryNotifier notifier) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'plugins_network_add'.tr(),
      input: BottomSheetInput(
        placeholder: 'example.com, *.example.com',
        confirmLabel: 'plugins_network_add_confirm'.tr(),
        onConfirm: (text) {
          final host = normalizePluginHost(text);
          if (host == null) {
            GlazeToast.show(
              context,
              'plugins_network_add_invalid'.tr(),
              isError: true,
            );
            return;
          }
          Navigator.of(context, rootNavigator: true).pop();
          notifier.setHostAllowed(plugin.id, host, true);
        },
      ),
    );
  }
}
