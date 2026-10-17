import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/shell/desktop/desktop_floating_provider.dart';
import '../../../shared/shell/shell_header_provider.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_scaffold.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_history_provider.dart';
import '../providers/plugin_library_provider.dart';

Future<void> openPluginHistoryScreen(BuildContext context, String id) async {
  final viewId = Uri(path: 'plugin-history', queryParameters: {'id': id});
  if (floatOnDesktop(context, viewId.toString(), push: true)) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => PluginHistoryScreen(pluginId: id)),
  );
}

/// Everything a plugin asked to use: what it was given and what it was not,
/// how often and when last.
class PluginHistoryScreen extends ConsumerStatefulWidget {
  const PluginHistoryScreen({super.key, required this.pluginId});

  final String pluginId;

  @override
  ConsumerState<PluginHistoryScreen> createState() =>
      _PluginHistoryScreenState();
}

/// Which answers the history shows.
enum _Outcome { all, allowed, denied }

class _PluginHistoryScreenState extends ConsumerState<PluginHistoryScreen> {
  _Outcome _outcome = _Outcome.all;

  /// Null for every kind.
  PluginPermissionCategory? _category;

  String get pluginId => widget.pluginId;

  static String _label(String key) {
    final text = key.tr();
    return text == key ? key : text;
  }

  @override
  Widget build(BuildContext context) {
    final plugin = (ref.watch(pluginLibraryProvider).value ?? const [])
        .where((x) => x.id == pluginId)
        .firstOrNull;
    final history = ref.watch(pluginHistoryProvider(pluginId));
    final records = history.value?.values ?? const <PluginRequestRecord>[];
    // Kinds the history holds; a record kept before the permission was noted
    // has none and shows only under all kinds.
    final categories = {
      for (final r in records)
        if (r.permission case final p?) PluginPermissionCategory.of(p),
    };
    final shown = [
      for (final r in records)
        if (_category == null ||
            (r.permission != null &&
                PluginPermissionCategory.of(r.permission!) == _category))
          r,
    ];
    final denied = _outcome == _Outcome.allowed
        ? <PluginRequestRecord>[]
        : (shown.where((r) => r.denied > 0).toList()
            ..sort((a, b) => b.lastDenied.compareTo(a.lastDenied)));
    final allowed = _outcome == _Outcome.denied
        ? <PluginRequestRecord>[]
        : (shown.where((r) => r.allowed > 0).toList()
            ..sort((a, b) => b.lastAllowed.compareTo(a.lastAllowed)));
    final format = DateFormat.MMMd(context.locale.toLanguageTag()).add_Hm();
    final topPad = DetachedShellHost.of(context)
        ? 0.0
        : MediaQuery.of(context).padding.top + 74.0;
    final bottomPad = MediaQuery.of(context).padding.bottom + 20.0;

    MenuItem row(PluginRequestRecord r, {required bool wasAllowed}) => MenuItem(
      icon: wasAllowed
          ? Icons.check_circle_outline_rounded
          : Icons.block_rounded,
      label: _label(r.action),
      subtitle: 'plugins_history_count'.tr(
        namedArgs: {'count': '${wasAllowed ? r.allowed : r.denied}'},
      ),
      value: format.format(
        DateTime.fromMillisecondsSinceEpoch(
          wasAllowed ? r.lastAllowed : r.lastDenied,
        ),
      ),
      onTap: () {},
    );

    return GlazeScaffold(
      title: 'plugins_history_title'.tr(),
      showBackground: true,
      extendBodyBehindHeader: true,
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, topPad + 8, 0, bottomPad),
        children: [
          MenuGroup(
            header: plugin == null
                ? pluginId
                : plugin
                      .localizer(context.locale.toLanguageTag())
                      .resolve(plugin.manifest.name),
            headerIcon: Icons.extension_rounded,
            description: history.isLoading
                ? null
                : records.isEmpty
                ? 'plugins_history_empty'.tr()
                : 'plugins_history_intro'.tr(),
            items: const [],
          ),
          if (records.isNotEmpty) ...[
            GlazeFilterChipBar<_Outcome>(
              current: _outcome,
              options: _Outcome.values,
              labelBuilder: (o) => 'plugins_history_filter_${o.name}'.tr(),
              onSelected: (o) => setState(() => _outcome = o),
            ),
            if (categories.length > 1 || _category != null)
              GlazeFilterChipBar<PluginPermissionCategory?>(
                current: _category,
                options: [
                  null,
                  for (final c in PluginPermissionCategory.values)
                    if (categories.contains(c)) c,
                ],
                labelBuilder: (c) => c == null
                    ? 'plugins_history_filter_any_kind'.tr()
                    : 'plugins_permission_category_${c.name}'.tr(),
                onSelected: (c) => setState(() => _category = c),
              ),
            const SizedBox(height: 8),
            if (denied.isEmpty && allowed.isEmpty)
              MenuGroup(
                description: 'plugins_history_filter_empty'.tr(),
                items: const [],
              ),
          ],
          if (denied.isNotEmpty)
            MenuGroup(
              header: 'plugins_history_denied'.tr(),
              headerIcon: Icons.block_rounded,
              description: 'plugins_history_hint'.tr(),
              items: [for (final r in denied) row(r, wasAllowed: false)],
            ),
          if (allowed.isNotEmpty)
            MenuGroup(
              header: 'plugins_history_allowed'.tr(),
              headerIcon: Icons.check_circle_outline_rounded,
              items: [for (final r in allowed) row(r, wasAllowed: true)],
            ),
          if (records.isNotEmpty)
            MenuGroup(
              items: [
                MenuItem(
                  icon: Icons.delete_sweep_outlined,
                  label: 'plugins_history_clear'.tr(),
                  onTap: () => ref
                      .read(pluginHistoryProvider(pluginId).notifier)
                      .clear(),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
