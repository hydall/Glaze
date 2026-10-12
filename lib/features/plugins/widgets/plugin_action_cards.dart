import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/widgets/magic_drawer_models.dart';
import '../../chat/widgets/magic_drawer_widgets.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_library_provider.dart';
import '../runtime/plugin_chat_host.dart';

/// Which contribution list a card comes from, and the event prefix its
/// handler is registered under.
enum PluginActionKind {
  input('inputActions'),
  sidebar('sidebar');

  const PluginActionKind(this.eventPrefix);
  final String eventPrefix;
}

typedef PluginActionEntry = ({
  String pluginId,
  String pluginName,
  PluginAction action,
  String label,
});

/// Actions of every enabled plugin for [kind], with localized labels.
List<PluginActionEntry> pluginActionEntries(
  WidgetRef ref,
  BuildContext context,
  PluginActionKind kind,
) {
  final locale = context.locale.toLanguageTag();
  return [
    for (final plugin in ref.watch(enabledPluginsProvider))
      for (final action in switch (kind) {
        PluginActionKind.input => plugin.manifest.inputActions,
        PluginActionKind.sidebar => plugin.manifest.sidebarActions,
      })
        (
          pluginId: plugin.id,
          pluginName: plugin.localizer(locale).resolve(plugin.manifest.name),
          action: action,
          label: plugin.localizer(locale).resolve(action.label),
        ),
  ];
}

/// Runs a plugin action in the chat's runtime and reports a failure.
Future<void> runPluginAction(
  BuildContext context,
  WidgetRef ref, {
  required String charId,
  required PluginActionKind kind,
  required PluginActionEntry entry,
}) async {
  final runtime = ref.read(pluginRuntimeRegistryProvider(charId));
  if (runtime == null) {
    GlazeToast.show(context, 'plugins_runtime_not_ready'.tr(), isWarning: true);
    return;
  }
  final result = await runtime.runAction(
    entry.pluginId,
    '${kind.eventPrefix}:${entry.action.id}',
  );
  if (result.ok || !context.mounted) return;
  final message = switch (result.reason) {
    'missing-handler' => 'plugins_action_missing'.tr(),
    'runtime-not-ready' => 'plugins_runtime_not_ready'.tr(),
    _ => 'plugins_action_failed'.tr(
      namedArgs: {'error': result.message ?? result.reason ?? '?'},
    ),
  };
  GlazeToast.show(context, message, isError: true);
}

/// Drawer cards for plugin actions, sized like the cards around them.
List<Widget> pluginActionCards(
  BuildContext context,
  WidgetRef ref, {
  required String charId,
  required PluginActionKind kind,
  required double itemWidth,
  required bool listRow,
  required bool editing,
  VoidCallback? beforeRun,
}) {
  return [
    for (final entry in pluginActionEntries(ref, context, kind))
      SizedBox(
        width: itemWidth,
        child: MagicCard(
          key: ValueKey('plugin-${entry.pluginId}-${entry.action.id}'),
          item: MagicDrawerCardItem(
            def: MagicDrawerItemDef(
              id: 'plugin:${entry.pluginId}:${entry.action.id}',
              label: entry.label,
              icon: Icons.widgets_outlined,
              category: MagicDrawerCategory.tools,
            ),
            status: entry.pluginName,
          ),
          editing: editing,
          hovered: false,
          deletable: false,
          listRow: listRow,
          onDelete: () {},
          onTap: () {
            beforeRun?.call();
            runPluginAction(
              context,
              ref,
              charId: charId,
              kind: kind,
              entry: entry,
            );
          },
        ),
      ),
  ];
}
