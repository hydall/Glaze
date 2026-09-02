import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/haptics.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../composer_actions_provider.dart';

/// Picker for the button row under the chat composer: a switch per action and
/// a drag handle to order the ones that are on.
///
/// Opened by long-pressing the row itself and from Settings › Input. A
/// dedicated sheet rather than a settings sub-screen because the row is a chat
/// affordance — the user is looking at it when they decide to change it.
class ComposerActionsSheet {
  const ComposerActionsSheet._();

  static Future<void> show(BuildContext context) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'composer_actions_title'.tr(),
      child: const _ComposerActionsForm(),
    );
  }
}

class _ComposerActionsForm extends ConsumerWidget {
  const _ComposerActionsForm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled =
        ref.watch(composerActionsProvider).value ?? kDefaultComposerActions;

    // Enabled actions first, in their user order, then the hidden ones. The
    // reorderable list covers only the enabled block: dragging a hidden action
    // into a position it does not occupy would be a lie.
    final hidden = [
      for (final action in ComposerAction.values)
        if (!enabled.contains(action)) action,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'composer_actions_desc'.tr(),
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (enabled.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'composer_actions_empty'.tr(),
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              // onReorderItem, not the deprecated onReorder: it already
              // adjusts the target index for the item lifted out at `from`,
              // so no off-by-one correction of our own.
              onReorderItem: (from, to) {
                Haptics.mediumImpact();
                ref.read(composerActionsProvider.notifier).reorder(from, to);
              },
              children: [
                for (var i = 0; i < enabled.length; i++)
                  _ActionRow(
                    key: ValueKey(enabled[i].id),
                    action: enabled[i],
                    enabled: true,
                    dragIndex: i,
                    onChanged: (value) => ref
                        .read(composerActionsProvider.notifier)
                        .setEnabled(enabled[i], value),
                  ),
              ],
            ),
          for (final action in hidden)
            _ActionRow(
              key: ValueKey(action.id),
              action: action,
              enabled: false,
              onChanged: (value) => ref
                  .read(composerActionsProvider.notifier)
                  .setEnabled(action, value),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () =>
                  ref.read(composerActionsProvider.notifier).reset(),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text('btn_reset'.tr()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final ComposerAction action;
  final bool enabled;

  /// Position in the reorderable block; null for a hidden action, which has no
  /// position to drag.
  final int? dragIndex;
  final ValueChanged<bool> onChanged;

  const _ActionRow({
    super.key,
    required this.action,
    required this.enabled,
    required this.onChanged,
    this.dragIndex,
  });

  @override
  Widget build(BuildContext context) {
    final index = dragIndex;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            action.icon,
            size: 20,
            color: enabled ? context.cs.primary : context.cs.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              action.label,
              style: TextStyle(
                fontSize: 14,
                color: enabled
                    ? context.cs.onSurface
                    : context.cs.onSurfaceVariant,
              ),
            ),
          ),
          Switch(value: enabled, onChanged: onChanged),
          if (index != null)
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.drag_handle,
                  size: 20,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            )
          else
            // Keeps the switches of hidden rows aligned with the ones above.
            const SizedBox(width: 28),
        ],
      ),
    );
  }
}
