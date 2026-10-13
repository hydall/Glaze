import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/glaze_switch.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../core/services/file_export_service.dart';
import '../compat/tavo/tavo_hub.dart';
import '../compat/tavo/tavo_manifest_converter.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_history_provider.dart';
import '../providers/plugin_hub_provider.dart';
import '../providers/plugin_library_provider.dart';
import '../providers/plugin_network_log_provider.dart';
import 'plugin_history_screen.dart';
import 'plugin_hub_sheet.dart';
import 'plugin_settings_form.dart';
import '../widgets/plugin_text_widgets.dart';

Future<void> openPluginDetailScreen(BuildContext context, String id) async {
  final viewId = Uri(path: 'plugin-detail', queryParameters: {'id': id});
  if (floatOnDesktop(context, viewId.toString(), push: true)) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => PluginDetailScreen(pluginId: id)),
  );
}

/// Groups of rows that set up what [plugin] may do: a switch per
/// permission, the ask/always/off choice for consents and the internet mode.
/// The first group, headed [header], holds the general permissions and
/// [afterNetwork] under the internet rows; variables, reading the library,
/// changing it and other chats follow, each in a group of its own.
List<Widget> pluginPermissionGroups(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin, {
  required String header,
  required IconData headerIcon,
  String? description,
  List<Widget> afterNetwork = const [],
}) {
  final notifier = ref.read(pluginLibraryProvider.notifier);
  final order = PluginPermission.all.toList();
  int rank(String p) {
    final i = order.indexOf(p);
    return i < 0 ? order.length : i;
  }

  final sections = <_PermissionSection, List<Widget>>{
    for (final s in _PermissionSection.values) s: [],
  };
  final permissions = [...plugin.manifest.permissions]
    ..sort((a, b) => rank(a).compareTo(rank(b)));
  for (final permission in permissions) {
    sections[_PermissionSection.of(permission)]!.addAll([
      PluginDetailScreen._permissionItem(context, notifier, plugin, permission),
      if (permission == PluginPermission.network &&
          plugin.allows(PluginPermission.network)) ...[
        MenuItem(
          icon: Icons.router_outlined,
          label: 'plugins_local_network'.tr(),
          subtitle: 'plugins_local_network_hint'.tr(),
          trailing: GlazeSwitch(
            value: plugin.localNetwork,
            onChanged: (v) => notifier.setLocalNetwork(plugin.id, v),
          ),
          onTap: () =>
              notifier.setLocalNetwork(plugin.id, !plugin.localNetwork),
        ),
        ...afterNetwork,
      ],
    ]);
  }
  return [
    MenuGroup(
      header: header,
      headerIcon: headerIcon,
      description: description,
      items: sections[_PermissionSection.general]!,
    ),
    for (final section in _PermissionSection.values.skip(1))
      if (sections[section]!.isNotEmpty)
        MenuGroup(
          header: 'plugins_permission_group_${section.name}'.tr(),
          headerIcon: section.icon,
          items: sections[section]!,
        ),
  ];
}

enum _PermissionSection {
  general(Icons.verified_user_outlined),
  variables(Icons.data_object_rounded),
  libraryRead(Icons.library_books_outlined),
  libraryChange(Icons.edit_outlined),
  chats(Icons.forum_outlined);

  const _PermissionSection(this.icon);

  final IconData icon;

  static _PermissionSection of(String permission) {
    if (permission == PluginPermission.variables ||
        permission == PluginPermission.variablesShared) {
      return variables;
    }
    if (PluginPermission.libraryReads.contains(permission)) return libraryRead;
    if (PluginPermission.library.contains(permission)) return libraryChange;
    if (PluginPermission.chats.contains(permission)) return chats;
    return general;
  }
}

/// Shown after a plugin is installed or updated with new permissions:
/// everything starts off and the user switches on what the plugin may do.
Future<void> showPluginPermissionsSheet(BuildContext context, String id) =>
    GlazeBottomSheet.show<void>(
      context,
      title: 'plugins_permissions_sheet_title'.tr(),
      child: _PermissionsSheet(pluginId: id),
    );

class _PermissionsSheet extends ConsumerWidget {
  const _PermissionsSheet({required this.pluginId});

  final String pluginId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(pluginLibraryProvider).value ?? const [];
    final plugin = plugins.where((x) => x.id == pluginId).firstOrNull;
    if (plugin == null) return const SizedBox.shrink();
    final name = plugin
        .localizer(context.locale.toLanguageTag())
        .resolve(plugin.manifest.name);
    final notifier = ref.read(pluginLibraryProvider.notifier);
    final listed =
        PluginDetailScreen._networkMode(plugin) == PluginNetworkMode.listed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: pluginPermissionGroups(
        context,
        ref,
        plugin,
        header: name,
        headerIcon: Icons.extension_rounded,
        description: [
          'plugins_permissions_sheet_body'.tr(),
          if (plugin.foundInCode.isNotEmpty)
            'plugins_permissions_found_hint'.tr(),
        ].join('\n\n'),
        // The hosts the plugin names, to switch on without leaving.
        afterNetwork: [
          if (listed)
            for (final host in {
              ...plugin.manifest.hosts,
              ...?plugin.networkHosts,
            }.toList()..sort())
              MenuItem(
                icon: Icons.language_rounded,
                label: host,
                trailing: GlazeSwitch(
                  value: plugin.allowsHost(host),
                  onChanged: (v) => notifier.setHostAllowed(plugin.id, host, v),
                ),
                onTap: () => notifier.setHostAllowed(
                  plugin.id,
                  host,
                  !plugin.allowsHost(host),
                ),
              ),
        ],
      ),
    );
  }
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
    final update = ref.watch(pluginHubUpdatesProvider).value?[plugin.id];
    final description = manifest.description == null
        ? ''
        : localizer.resolve(manifest.description).trim();
    final releaseNotes = manifest.releaseNotes == null
        ? ''
        : localizer.resolve(manifest.releaseNotes).trim();

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
              if (description.isNotEmpty)
                PluginDescriptionItem(text: description),
              pluginVersionItem(
                context,
                version: manifest.version,
                releaseNotes: releaseNotes.isEmpty ? null : releaseNotes,
              ),
              if (plugin.hubSlug case final slug?)
                MenuItem(
                  icon: Icons.storefront_outlined,
                  label: 'plugins_hub_source'.tr(),
                  subtitle: update == null
                      ? null
                      : 'plugins_hub_update_available'.tr(
                          namedArgs: {'version': update.version},
                        ),
                  onTap: () => openPluginHubLink(
                    context,
                    Uri.https(kTavoHubSite, '/plugins/$slug'),
                  ),
                ),
            ],
          ),
          ...pluginPermissionGroups(
            context,
            ref,
            plugin,
            header: 'plugins_permissions'.tr(),
            headerIcon: Icons.verified_user_outlined,
            description: manifest.permissions.isEmpty
                ? 'plugins_permissions_none'.tr()
                : null,
          ),
          _NetworkLog(plugin: plugin),
          _History(plugin: plugin),
          if (manifest.settings.isNotEmpty)
            PluginSettingsForm(plugin: plugin, localizer: localizer),
          MenuGroup(
            items: [
              MenuItem(
                icon: Icons.ios_share_rounded,
                label: 'plugins_export'.tr(),
                subtitle: 'plugins_export_hint_${pluginExportFormat(plugin)}'
                    .tr(),
                onTap: () => exportPlugin(context, ref, plugin),
              ),
              MenuItem(
                icon: Icons.delete_outline_rounded,
                label: 'plugins_uninstall'.tr(),
                onTap: () => confirmPluginUninstall(
                  context,
                  ref,
                  plugin,
                  closeScreen: true,
                ),
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
    PluginPermission.variablesShared: Icons.share_outlined,
    PluginPermission.files: Icons.folder_outlined,
    PluginPermission.generate: Icons.auto_awesome_outlined,
    PluginPermission.images: Icons.image_outlined,
    PluginPermission.network: Icons.public_rounded,
    PluginPermission.charactersRead: Icons.person_outline_rounded,
    PluginPermission.personasRead: Icons.badge_outlined,
    PluginPermission.presetsRead: Icons.tune_rounded,
    PluginPermission.lorebooksRead: Icons.menu_book_outlined,
    PluginPermission.regexRead: Icons.code_rounded,
    PluginPermission.themesRead: Icons.palette_outlined,
    PluginPermission.libraryCreate: Icons.library_add_outlined,
    PluginPermission.libraryUpdate: Icons.edit_outlined,
    PluginPermission.libraryDelete: Icons.delete_outline_rounded,
    PluginPermission.chatsRead: Icons.forum_outlined,
    PluginPermission.chatsCreate: Icons.add_comment_outlined,
    PluginPermission.chatsUpdate: Icons.edit_note_rounded,
    PluginPermission.chatsDelete: Icons.delete_sweep_outlined,
    'tts': Icons.record_voice_over_outlined,
  };

  static String _text(String key, String fallback) {
    final text = key.tr();
    return text == key ? fallback : text;
  }

  static Widget _permissionItem(
    BuildContext context,
    PluginLibraryNotifier notifier,
    InstalledPlugin plugin,
    String permission,
  ) {
    final icon = _icons[permission] ?? Icons.help_outline_rounded;
    final key = permission.replaceAll('.', '_');
    final label = _text('plugins_permission_name_$key', permission);
    // A converted package names only some of what it uses; the rest was
    // found in its scripts, and the user is told which is which.
    final source = plugin.manifest.compat == null
        ? null
        : _SourceChip(found: plugin.foundInCode.contains(permission));
    final subtitle = _text('plugins_permission_$key', '');
    if (!PluginPermission.all.contains(permission)) {
      // Asked for, but nothing in Glaze provides it (e.g. Tavo's `tts`).
      return MenuItem(
        icon: icon,
        label: label,
        badge: source,
        subtitle: subtitle.isEmpty ? null : subtitle,
        onTap: () {},
      );
    }
    if (PluginPermission.asking.contains(permission)) {
      final mode = !plugin.allows(permission)
          ? PluginConsentMode.off
          : plugin.grants.contains(permission)
          ? PluginConsentMode.always
          : PluginConsentMode.ask;
      return MenuItem(
        icon: icon,
        label: label,
        badge: source,
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
        badge: source,
        subtitle: subtitle,
        value: 'plugins_network_mode_${mode.name}'.tr(),
        onTap: () => _pickNetworkMode(context, notifier, plugin, mode),
      );
    }
    final allowed = plugin.allows(permission);
    return MenuItem(
      icon: icon,
      label: label,
      badge: source,
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

  static void _pickNetworkMode(
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

  static void _pickConsentMode(
    BuildContext context,
    PluginLibraryNotifier notifier,
    InstalledPlugin plugin,
    String permission,
    PluginConsentMode current,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: _text(
        'plugins_permission_name_${permission.replaceAll('.', '_')}',
        permission,
      ),
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
}

/// Asks before [plugin] and everything it stored go; [closeScreen] also
/// leaves the plugin's own screen afterwards.
void confirmPluginUninstall(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin, {
  bool closeScreen = false,
}) {
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
        if (closeScreen && context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
    ),
  );
}

/// The format [plugin] is exported in: its own app's.
String pluginExportFormat(InstalledPlugin plugin) =>
    plugin.manifest.compat == kTavoCompat ? 'tpg' : 'glzp';

/// Packs [plugin] back into a file and saves it.
Future<void> exportPlugin(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin,
) async {
  try {
    final store = await ref.read(pluginStoreProvider.future);
    final bytes = await store.exportPackage(plugin.id);
    final ext = pluginExportFormat(plugin);
    final base = '${plugin.id}-${plugin.manifest.version}'.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final path = await FileExportService.exportBytes(
      bytes: bytes,
      filename: '$base.$ext',
      subfolder: 'plugins',
    );
    if (path.isEmpty || !context.mounted) return;
    GlazeToast.show(
      context,
      'plugins_exported_toast'.tr(namedArgs: {'path': path}),
    );
  } catch (e) {
    if (!context.mounted) return;
    GlazeToast.show(
      context,
      'plugins_export_failed'.tr(namedArgs: {'error': '$e'}),
      isError: true,
      showCopyButton: true,
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
      for (final h in {
        ...?plugin.networkHosts,
        if (listed) ...plugin.manifest.hosts,
      }.toList()..sort())
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
          _hostItem(
            notifier,
            h,
            allowed: !listed || plugin.allowsHost(h),
            listed: listed,
          ),
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

/// What the plugin tried and was not allowed to do.
/// The row opening the plugin's request history, with what it holds.
class _History extends ConsumerWidget {
  const _History({required this.plugin});

  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records =
        ref.watch(pluginHistoryProvider(plugin.id)).value?.values ??
        const <PluginRequestRecord>[];
    final denied = records.where((r) => r.denied > 0).length;
    final allowed = records.where((r) => r.allowed > 0).length;
    return MenuGroup(
      items: [
        MenuItem(
          icon: Icons.history_rounded,
          label: 'plugins_history_title'.tr(),
          subtitle: records.isEmpty
              ? 'plugins_history_empty_short'.tr()
              : 'plugins_history_summary'.tr(
                  namedArgs: {'allowed': '$allowed', 'denied': '$denied'},
                ),
          trailing: Icon(
            Icons.chevron_right_rounded,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          onTap: () => openPluginHistoryScreen(context, plugin.id),
        ),
      ],
    );
  }
}

/// Marks a converted plugin's permission as asked for by the plugin or found
/// in its code; the second stands out, as nothing in the plugin said so.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.found});

  final bool found;

  @override
  Widget build(BuildContext context) {
    final color = found ? const Color(0xFFE8A33D) : context.cs.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            found ? Icons.code_rounded : Icons.check_rounded,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              found
                  ? 'plugins_permission_found_in_code'.tr()
                  : 'plugins_permission_declared'.tr(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
