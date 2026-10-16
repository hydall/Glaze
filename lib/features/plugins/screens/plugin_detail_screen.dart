import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
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
import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../core/services/file_export_service.dart';
import '../../chat/widgets/action_glyph.dart';
import '../compat/tavo/tavo_hub.dart';
import '../compat/tavo/tavo_manifest_converter.dart';
import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
import '../models/plugin_settings_schema.dart';
import '../providers/plugin_history_provider.dart';
import '../providers/plugin_hub_provider.dart';
import '../providers/plugin_library_provider.dart';
import '../providers/plugin_network_log_provider.dart';
import '../services/plugin_data_transfer.dart';
import '../services/plugin_localizer.dart';
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
/// The first group, headed [header], holds the general permissions; the
/// internet, variables, the library and other chats follow, each in a group
/// of its own. Every group's header has a switch that gives or takes away
/// all of its permissions.
List<Widget> pluginPermissionGroups(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin, {
  required String header,
  required IconData headerIcon,
  String? description,
}) {
  final notifier = ref.read(pluginLibraryProvider.notifier);
  final order = PluginPermission.all.toList();
  int rank(String p) {
    final i = order.indexOf(p);
    return i < 0 ? order.length : i;
  }

  final rows = <PluginPermissionCategory, List<Widget>>{};
  final members = <PluginPermissionCategory, List<String>>{};
  final permissions = [...plugin.manifest.permissions]
    ..sort((a, b) => rank(a).compareTo(rank(b)));
  for (final permission in permissions) {
    final section = PluginPermissionCategory.of(permission);
    if (PluginPermission.all.contains(permission)) {
      (members[section] ??= []).add(permission);
    }
    (rows[section] ??= []).addAll([
      PluginDetailScreen._permissionItem(context, notifier, plugin, permission),
      if (permission == PluginPermission.network &&
          plugin.allows(PluginPermission.network)) ...[
        if (PluginDetailScreen._networkMode(plugin) == PluginNetworkMode.listed)
          _HostsBlock(plugin: plugin),
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
      ],
    ]);
  }

  Widget? groupSwitch(PluginPermissionCategory section) {
    final list = members[section];
    if (list == null || list.isEmpty) return null;
    return GlazeSwitch(
      value: list.every(plugin.allows),
      onChanged: (v) => notifier.setPermissions(plugin.id, list, v),
    );
  }

  return [
    MenuGroup(
      header: header,
      headerIcon: headerIcon,
      description: description,
      headerTrailing: groupSwitch(PluginPermissionCategory.general),
      items: rows[PluginPermissionCategory.general] ?? const [],
    ),
    for (final section in PluginPermissionCategory.values.skip(1))
      if (rows[section] case final items?)
        MenuGroup(
          header: 'plugins_permission_category_${section.name}'.tr(),
          headerIcon: _groupIcons[section],
          headerTrailing: groupSwitch(section),
          items: items,
        ),
  ];
}

const _groupIcons = {
  PluginPermissionCategory.network: Icons.public_rounded,
  PluginPermissionCategory.variables: Icons.data_object_rounded,
  PluginPermissionCategory.library: Icons.library_books_outlined,
  PluginPermissionCategory.chats: Icons.forum_outlined,
};

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
      ),
    );
  }
}

/// One installed plugin, on tabs picked from the header's dropdown: what it
/// is, what it may do, then the plugin's own settings tabs.
class PluginDetailScreen extends ConsumerStatefulWidget {
  const PluginDetailScreen({super.key, required this.pluginId});

  final String pluginId;

  @override
  ConsumerState<PluginDetailScreen> createState() => _PluginDetailScreenState();

  static const _icons = {
    PluginPermission.composer: Icons.edit_note_rounded,
    PluginPermission.messages: Icons.chat_bubble_outline_rounded,
    PluginPermission.variables: Icons.data_object_rounded,
    PluginPermission.variablesShared: Icons.share_outlined,
    PluginPermission.files: Icons.folder_outlined,
    PluginPermission.generate: Icons.auto_awesome_outlined,
    PluginPermission.images: Icons.image_outlined,
    PluginPermission.network: Icons.public_rounded,
    // Library rows, by action.
    'read': Icons.visibility_outlined,
    'create': Icons.add_circle_outline_rounded,
    'update': Icons.edit_outlined,
    'delete': Icons.delete_outline_rounded,
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
    final key = permission.replaceAll('.', '_');
    // Library rows take the action's icon; their names say the kind.
    final parts = permission.split('.');
    final icon =
        _icons[PluginPermission.library.contains(permission)
            ? parts[1]
            : permission] ??
        Icons.help_outline_rounded;
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
        // The group is already headed Internet.
        label: 'plugins_network_access'.tr(),
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

/// A tab of the plugin screen: Info, Permissions, or one of the plugin's.
typedef _PluginTab = ({
  String id,
  String label,
  IconData icon,

  /// A plugin tab's own icon in its package.
  String? iconFile,
});

const _infoTab = '@info';

const _tabSwitch = Duration(milliseconds: 360);
const _permissionsTab = '@permissions';

/// The tab of a plugin without `settingsTabs`, holding all its settings.
const _settingsTab = '@settings';

/// The last tab: the plugin and its data to and from files.
const _dataTab = '@data';

class _PluginDetailScreenState extends ConsumerState<PluginDetailScreen> {
  String _tab = _infoTab;

  List<_PluginTab> _tabs(InstalledPlugin plugin, PluginLocalizer localizer) {
    final manifest = plugin.manifest;
    final declared = manifest.settingsTabs;
    // A tab without fields would open on nothing.
    final used = {
      for (final f in manifest.settings) f.tab ?? declared.firstOrNull?.id,
    };
    return [
      (
        id: _infoTab,
        label: 'plugins_tab_info'.tr(),
        icon: Icons.info_outline_rounded,
        iconFile: null,
      ),
      (
        id: _permissionsTab,
        label: 'plugins_permissions'.tr(),
        icon: Icons.verified_user_outlined,
        iconFile: null,
      ),
      if (declared.isEmpty && manifest.settings.isNotEmpty)
        (
          id: _settingsTab,
          label: 'plugins_settings'.tr(),
          icon: Icons.tune_rounded,
          iconFile: null,
        ),
      for (final t in declared.take(PluginSettingsTab.max))
        if (used.contains(t.id))
          (
            id: t.id,
            label: localizer.resolve(t.label, fallback: t.id),
            icon: Icons.tune_rounded,
            iconFile: t.icon == null
                ? null
                : p.joinAll([plugin.directory, ...t.icon!.split('/')]),
          ),
      (
        id: _dataTab,
        label: 'plugins_data_group'.tr(),
        icon: Icons.inventory_2_outlined,
        iconFile: null,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(pluginLibraryProvider).value ?? const [];
    final plugin = plugins.where((x) => x.id == widget.pluginId).firstOrNull;
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
    final tabs = _tabs(plugin, localizer);
    final tab = tabs.where((t) => t.id == _tab).firstOrNull ?? tabs.first;
    final cover = plugin.manifest.icon;

    return GlazeScaffold(
      title: localizer.resolve(plugin.manifest.name),
      showBackground: true,
      extendBodyBehindHeader: true,
      onBack: () => Navigator.of(context).pop(),
      body: Stack(
        children: [
          // On Info the cover fills the screen behind everything, the header
          // included; it fades out when another tab is picked.
          if (cover != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: tab.id == _infoTab ? 1 : 0,
                  duration: _tabSwitch,
                  curve: Curves.easeOut,
                  child: _CoverBackdrop(
                    path: p.joinAll([plugin.directory, ...cover.split('/')]),
                  ),
                ),
              ),
            ),
          // The tab dropdown sits right under the header and stays put, so
          // the tabs are in sight however far the page scrolls.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(16, topPad + 8, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GlazeDropdownChip(
                    label: tab.label,
                    leading: _tabGlyph(context, tab, size: 16),
                    onTap: () => showGlazePickerSheet(
                      context,
                      title: localizer.resolve(plugin.manifest.name),
                      items: [
                        for (final t in tabs)
                          GlazePickerItem(
                            label: t.label,
                            isActive: t.id == tab.id,
                            value: t.id,
                            iconWidget: _tabGlyph(context, t, size: 20),
                          ),
                      ],
                      onSelect: (v) => setState(() => _tab = v as String),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: _tabSwitch,
                  // Fade-through: the old tab is gone by halfway, then the
                  // new one fades in rising into place; the two never overlap.
                  transitionBuilder: (child, animation) {
                    final phase = CurvedAnimation(
                      parent: animation,
                      curve: const Interval(0.5, 1, curve: Curves.easeOutCubic),
                    );
                    return FadeTransition(
                      opacity: phase,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.03),
                          end: Offset.zero,
                        ).animate(phase),
                        child: child,
                      ),
                    );
                  },
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(tab.id),
                    child: _body(context, plugin, localizer, tab, bottomPad),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    InstalledPlugin plugin,
    PluginLocalizer localizer,
    _PluginTab tab,
    double bottomPad,
  ) {
    if (tab.id == _infoTab && plugin.manifest.icon != null) {
      return _coverInfo(context, plugin, localizer, tab, bottomPad);
    }
    return ListView(
      key: PageStorageKey(tab.id),
      padding: EdgeInsets.fromLTRB(0, 0, 0, bottomPad),
      children: switch (tab.id) {
        _infoTab => _info(context, plugin, localizer),
        _permissionsTab => [
          ...pluginPermissionGroups(
            context,
            ref,
            plugin,
            // The tab is already named Permissions.
            header: 'plugins_permission_category_general'.tr(),
            headerIcon: Icons.verified_user_outlined,
            description: plugin.manifest.permissions.isEmpty
                ? 'plugins_permissions_none'.tr()
                : null,
          ),
          _NetworkLog(plugin: plugin),
          _History(plugin: plugin),
        ],
        _dataTab => [
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
                icon: Icons.data_object_rounded,
                label: 'plugins_data_export'.tr(),
                subtitle: 'plugins_data_export_hint'.tr(),
                onTap: () => exportPluginData(context, ref, plugin),
              ),
              MenuItem(
                icon: Icons.settings_backup_restore_rounded,
                label: 'plugins_data_import'.tr(),
                subtitle: 'plugins_data_import_hint'.tr(),
                onTap: () => importPluginData(context, ref, plugin),
              ),
            ],
          ),
        ],
        _ => [
          PluginSettingsForm(
            plugin: plugin,
            localizer: localizer,
            tab: tab.id == _settingsTab ? null : tab.id,
          ),
        ],
      },
    );
  }

  Widget _tabGlyph(
    BuildContext context,
    _PluginTab tab, {
    required double size,
  }) => ActionGlyph(
    icon: tab.icon,
    file: tab.iconFile,
    size: size,
    color: context.cs.primary,
  );

  /// Info over a cover: the hero fills the screen, so the description sits
  /// at its bottom, with the hub link under it; it scrolls only when it
  /// does not fit.
  Widget _coverInfo(
    BuildContext context,
    InstalledPlugin plugin,
    PluginLocalizer localizer,
    _PluginTab tab,
    double bottomPad,
  ) {
    final manifest = plugin.manifest;
    final update = ref.watch(pluginHubUpdatesProvider).value?[plugin.id];
    final releaseNotes = manifest.releaseNotes == null
        ? ''
        : localizer.resolve(manifest.releaseNotes).trim();
    return CustomScrollView(
      key: PageStorageKey(tab.id),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomPad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  // The version is in the hero; a tap there opens the
                  // release notes.
                  child: _PluginHero(
                    plugin: plugin,
                    name: localizer.resolve(manifest.name),
                    description: manifest.description == null
                        ? ''
                        : localizer.resolve(manifest.description).trim(),
                    releaseNotes: releaseNotes.isEmpty ? null : releaseNotes,
                  ),
                ),
                if (plugin.hubSlug case final slug?)
                  MenuGroup(
                    items: [
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
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The About group of a plugin without a cover (see [_coverInfo]).
  /// Switching the plugin on or off and removing it are the plugin list's.
  List<Widget> _info(
    BuildContext context,
    InstalledPlugin plugin,
    PluginLocalizer localizer,
  ) {
    final manifest = plugin.manifest;
    final update = ref.watch(pluginHubUpdatesProvider).value?[plugin.id];
    final description = manifest.description == null
        ? ''
        : localizer.resolve(manifest.description).trim();
    final releaseNotes = manifest.releaseNotes == null
        ? ''
        : localizer.resolve(manifest.releaseNotes).trim();
    final version = pluginVersionItem(
      context,
      version: manifest.version,
      releaseNotes: releaseNotes.isEmpty ? null : releaseNotes,
    );
    final hub = switch (plugin.hubSlug) {
      final slug? => MenuItem(
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
      null => null,
    };
    return [
      MenuGroup(
        header: 'plugins_about'.tr(),
        headerIcon: Icons.info_outline_rounded,
        items: [
          MenuItem(
            icon: Icons.person_outline_rounded,
            label: 'plugins_author'.tr(),
            value: manifest.author ?? '—',
            onTap: () {},
          ),
          if (description.isNotEmpty) PluginDescriptionItem(text: description),
          version,
          ?hub,
        ],
      ),
    ];
  }
}

/// The plugin's cover filling the screen behind the Info tab, under a shade
/// at the top for the header and fading out towards the bottom, where the
/// groups sit on the app's own background.
class _CoverBackdrop extends StatelessWidget {
  const _CoverBackdrop({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    // The shade goes under the mask too, so the app's background below shows
    // as it is rather than darkened.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0, 0.5, 0.85],
      ).createShader(rect),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(path),
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xB3000000),
                  Color(0x26000000),
                  Color(0x26000000),
                  Color(0x99000000),
                ],
                stops: [0, 0.25, 0.4, 0.62],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Over the [_CoverBackdrop], as tall as it is given: the name, author and
/// version at the top and the description at the bottom,
/// leaving the picture room between them. The description is cut short and a
/// tap opens all of it; a tap on the version opens the release notes.
class _PluginHero extends StatelessWidget {
  const _PluginHero({
    required this.plugin,
    required this.name,
    required this.description,
    this.releaseNotes,
  });

  final InstalledPlugin plugin;
  final String name;
  final String description;
  final String? releaseNotes;

  @override
  Widget build(BuildContext context) {
    final byline = [
      if (plugin.manifest.author?.trim() case final a? when a.isNotEmpty) a,
      plugin.manifest.version,
    ].join(' · ');
    const shadow = [Shadow(color: Color(0x99000000), blurRadius: 8)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.15,
                        shadows: shadow,
                      ),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: releaseNotes == null
                          ? null
                          : () =>
                                showPluginReleaseNotes(context, releaseNotes!),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              byline,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.white70,
                                shadows: shadow,
                              ),
                            ),
                          ),
                          if (releaseNotes != null) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.notes_rounded,
                              size: 16,
                              color: Colors.white70,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // The picture shows between the two text blocks.
          const Spacer(),
          if (description.isNotEmpty)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => GlazeBottomSheet.show<void>(
                context,
                title: 'plugins_description'.tr(),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: PluginMarkdown(description),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: ClipRect(
                        child: PluginMarkdown(
                          description,
                          color: Colors.white.withValues(alpha: 0.92),
                        ),
                      ),
                    ),
                  ),
                  const Icon(Icons.expand_more_rounded, color: Colors.white70),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Asks before [plugin] and everything it stored go.
void confirmPluginUninstall(
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

/// Saves everything [plugin] keeps — settings, storage, variables and
/// files — as one JSON file.
Future<void> exportPluginData(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin,
) async {
  try {
    final data = await ref
        .read(pluginLibraryProvider.notifier)
        .exportData(plugin.id);
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final base = '${plugin.id}-data-$day'.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final path = await FileExportService.exportBytes(
      bytes: utf8.encode(const JsonEncoder.withIndent(' ').convert(data)),
      filename: '$base.json',
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

/// Picks a file made by [exportPluginData] and, once the user confirms,
/// replaces [plugin]'s data with it.
Future<void> importPluginData(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin,
) async {
  final result = await FilePicker.pickFiles(
    type: Platform.isIOS ? FileType.any : FileType.custom,
    allowedExtensions: Platform.isIOS ? null : const ['json'],
    withData: true,
  );
  final picked = result?.files.singleOrNull;
  if (picked == null || !context.mounted) return;
  final proceed = await GlazeBottomSheet.show<bool>(
    context,
    title: 'plugins_data_import'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.settings_backup_restore_rounded,
      description: 'plugins_data_import_confirm'.tr(),
      buttonText: 'plugins_data_import_button'.tr(),
      buttonIcon: Icons.settings_backup_restore_rounded,
      onButtonTap: () => Navigator.of(context, rootNavigator: true).pop(true),
    ),
  );
  if (proceed != true || !context.mounted) return;
  try {
    final bytes = picked.bytes ?? await File(picked.path!).readAsBytes();
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const PluginDataException(PluginDataError.notPluginData);
    }
    final skipped = await ref
        .read(pluginLibraryProvider.notifier)
        .importData(plugin.id, json);
    if (!context.mounted) return;
    GlazeToast.show(
      context,
      skipped == 0
          ? 'plugins_data_imported'.tr()
          : 'plugins_data_imported_skipped'.tr(
              namedArgs: {'count': '$skipped'},
            ),
    );
  } catch (e) {
    if (!context.mounted) return;
    final reason = e is PluginDataException
        ? 'plugins_data_error_${e.error.name}'.tr(
            namedArgs: {'id': e.detail ?? ''},
          )
        : '$e';
    GlazeToast.show(
      context,
      'plugins_data_import_failed'.tr(namedArgs: {'error': reason}),
      isError: true,
      showCopyButton: e is! PluginDataException,
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
    final format = DateFormat.MMMd(context.locale.toLanguageTag()).add_Hm();
    final empty = records.isEmpty;
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
    final rule = plugin.allowedHosts?.contains(host) ?? false;
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
}

/// The listed-hosts mode's hosts, closed to one row until tapped: the
/// manifest's, each with what the plugin says it uses it for and on until
/// switched off, then those the user added.
class _HostsBlock extends ConsumerStatefulWidget {
  const _HostsBlock({required this.plugin});

  final InstalledPlugin plugin;

  @override
  ConsumerState<_HostsBlock> createState() => _HostsBlockState();
}

class _HostsBlockState extends ConsumerState<_HostsBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugin;
    final notifier = ref.read(pluginLibraryProvider.notifier);
    final localizer = plugin.localizer(context.locale.toLanguageTag());
    final declared = plugin.manifest.hosts;
    final added = [
      for (final h
          in (plugin.networkHosts ?? const <String>{}).toList()..sort())
        if (!declared.contains(h)) h,
    ];
    final on =
        declared.where((h) => !plugin.blockedHosts.contains(h)).length +
        added.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuItem(
          icon: Icons.dns_outlined,
          label: 'plugins_network_hosts'.tr(),
          value: '$on / ${declared.length + added.length}',
          trailing: AnimatedRotation(
            turns: _open ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.expand_more_rounded,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          onTap: () => setState(() => _open = !_open),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final host in declared)
                      _host(
                        notifier,
                        host,
                        allowed: !plugin.blockedHosts.contains(host),
                        subtitle: localizer
                            .resolve(plugin.manifest.hostDescriptions[host])
                            .trim(),
                      ),
                    for (final host in added)
                      _host(
                        notifier,
                        host,
                        allowed: true,
                        subtitle: 'plugins_network_added'.tr(),
                      ),
                    MenuItem(
                      icon: Icons.add_rounded,
                      label: 'plugins_network_add'.tr(),
                      onTap: () => _addHost(context, notifier),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _host(
    PluginLibraryNotifier notifier,
    String host, {
    required bool allowed,
    required String subtitle,
  }) => MenuItem(
    icon: allowed ? Icons.language_rounded : Icons.block_rounded,
    label: host,
    subtitle: subtitle.isEmpty ? null : subtitle,
    trailing: GlazeSwitch(
      value: allowed,
      onChanged: (v) => notifier.setHostAllowed(widget.plugin.id, host, v),
    ),
    onTap: () => notifier.setHostAllowed(widget.plugin.id, host, !allowed),
  );

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
          notifier.setHostAllowed(widget.plugin.id, host, true);
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
