import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../chat/chat_actions_service.dart';
import '../chat/chat_provider.dart';
import 'chat_history_provider.dart';
import 'chat_history_selection_provider.dart';

/// The dialogs-list action menu, shared by a row's own context menu and by the
/// header's overflow button while a multi-selection is running — they are the
/// same menu, just pointed at one session or at many.
///
/// Every action ends the selection, so the header falls back to the Chats
/// title once the work is done.
Future<void> showChatSessionActions(
  BuildContext context,
  WidgetRef ref,
  List<ChatSessionInfo> sessions,
) async {
  if (sessions.isEmpty) return;
  final single = sessions.length == 1;
  final rootNav = Navigator.of(context, rootNavigator: true);
  final result = await GlazeBottomSheet.show<String>(
    context,
    title: single ? 'Session' : '${sessions.length} ${'selected_count'.tr()}',
    items: [
      BottomSheetItem(
        icon: Icons.upload_file,
        label: 'action_export_chat'.tr(),
        onTap: () => rootNav.pop('export'),
      ),
      // A rename names exactly one session, so with several selected there is
      // nothing the entry could mean — it is dropped rather than shown dead.
      if (single)
        BottomSheetItem(
          icon: Icons.drive_file_rename_outline,
          label: 'action_rename'.tr(),
          onTap: () => rootNav.pop('rename'),
        ),
      BottomSheetItem(
        icon: Icons.delete_outline,
        label: 'action_delete'.tr(),
        isDestructive: true,
        onTap: () => rootNav.pop('delete'),
      ),
    ],
  );
  if (result == null || !context.mounted) return;
  switch (result) {
    case 'export':
      await _exportSessions(context, ref, sessions);
    case 'rename':
      _showRenameSheet(context, ref, sessions.first);
    case 'delete':
      _confirmDelete(context, ref, sessions);
  }
}

/// Exports one session per save dialog, in the order they appear in the list.
/// Each export switches the character's active session, so they cannot be run
/// concurrently.
Future<void> _exportSessions(
  BuildContext context,
  WidgetRef ref,
  List<ChatSessionInfo> sessions,
) async {
  final actions = ref.read(chatActionsServiceProvider);
  final selection = ref.read(chatHistorySelectionProvider.notifier);
  for (final session in sessions) {
    if (!context.mounted) break;
    await actions.exportSessionUI(
      context,
      charId: session.characterId,
      sessionId: session.sessionId,
    );
  }
  selection.clear();
}

void _showRenameSheet(
  BuildContext context,
  WidgetRef ref,
  ChatSessionInfo info,
) {
  final currentName = info.sessionName?.isNotEmpty == true
      ? info.sessionName!
      : 'session_name'.tr(
          namedArgs: {'id': (info.sessionIndex + 1).toString()},
        );
  final history = ref.read(chatHistoryProvider.notifier);
  final selection = ref.read(chatHistorySelectionProvider.notifier);
  GlazeBottomSheet.show<void>(
    context,
    title: 'Rename Session',
    input: BottomSheetInput(
      placeholder: 'Session name',
      value: currentName,
      confirmLabel: 'action_rename'.tr(),
      onConfirm: (val) {
        Navigator.of(context, rootNavigator: true).pop();
        if (val.trim().isEmpty) return;
        history.renameSession(info.sessionId, val.trim());
        ref.invalidate(chatProvider(info.characterId));
        selection.clear();
      },
    ),
  );
}

void _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  List<ChatSessionInfo> sessions,
) {
  final count = sessions.length;
  final ids = [for (final s in sessions) s.sessionId];
  // Read up front: the row that opened this menu can be gone from the list by
  // the time the deletions finish, taking its `ref` with it.
  final history = ref.read(chatHistoryProvider.notifier);
  final selection = ref.read(chatHistorySelectionProvider.notifier);
  GlazeBottomSheet.show<void>(
    context,
    title: 'action_delete_session'.tr(),
    bigInfo: BottomSheetBigInfo(
      icon: Icons.delete_outline,
      description: count == 1
          ? '${'action_delete_session'.tr()} — ${sessions.first.fullCharacterName}? ${'chat_clear_confirm'.tr()}'
          : 'dialogs_delete_selected_confirm'.plural(count),
    ),
    items: [
      BottomSheetItem(
        label: 'btn_delete'.tr(),
        isDestructive: true,
        centered: true,
        onTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          selection.clear();
          for (final id in ids) {
            await history.deleteSession(id);
          }
        },
      ),
      BottomSheetItem(
        label: 'btn_cancel'.tr(),
        centered: true,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}
