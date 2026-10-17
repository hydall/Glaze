import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../shared/widgets/glaze_toast.dart';
import '../../chat/widgets/magic_drawer_models.dart';
import '../../chat/widgets/magic_drawer_widgets.dart';
import '../models/plugin_manifest.dart';
import '../providers/plugin_library_provider.dart';
import '../runtime/plugin_chat_host.dart';

/// Which contribution list a card comes from, and the event prefix its
/// handler is registered under.
enum PluginActionKind {
  composer('action:composer'),
  tools('action:tools');

  const PluginActionKind(this.eventPrefix);
  final String eventPrefix;
}

typedef PluginActionEntry = ({
  String pluginId,
  String pluginName,
  PluginAction action,
  String label,

  /// The action's icon in the unpacked package, when it names one.
  String? iconFile,
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
        PluginActionKind.composer => plugin.manifest.composerActions,
        PluginActionKind.tools => plugin.manifest.toolsActions,
      })
        (
          pluginId: plugin.id,
          pluginName: plugin.localizer(locale).resolve(plugin.manifest.name),
          action: action,
          label: plugin.localizer(locale).resolve(action.label),
          iconFile: action.icon == null
              ? null
              : p.joinAll([plugin.directory, ...action.icon!.split('/')]),
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

/// Drawer cards for plugin actions, sized like the cards around them. The
/// plugin picks a card's label and icon; the line under it is always the
/// puzzle piece and the plugin's name, so a plugin's card cannot pass for
/// one of Glaze's own.
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
              iconFile: entry.iconFile,
              category: MagicDrawerCategory.tools,
            ),
            status: entry.pluginName,
            statusIcon: Icons.extension_rounded,
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
