import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../chat_provider.dart';
import '../editing_message_provider.dart';

void showMessageContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String charId,
  required String content,
  required int messageIndex,
  required String messageId,
  required bool isUser,
  required bool isTyping,
  required bool isError,
  required bool isLast,
  required bool isGenerating,
  required bool isHidden,
  required bool canDeleteSwipe,
  required bool canDeleteAgentSwipe,
}) {
  // Notifier is read fresh inside each onTap callback instead of captured
  // here. If the provider is invalidated while the menu is open (e.g. by a
  // background session switch), a captured reference would be disposed and
  // every callback would throw "Cannot use Ref after disposed".
  final isActivelyGenerating = isGenerating && isLast && !isUser;
  final isTypingTarget = isTyping && !isUser;

  final items = <BottomSheetItem>[
    if (isTypingTarget)
      BottomSheetItem(
        icon: Icons.stop_circle,
        iconColor: Colors.orange,
        label: 'Stop Generating',
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          ref.read(chatProvider(charId).notifier).abortGeneration();
        },
      )
    else ...[
      if (!isActivelyGenerating)
        BottomSheetItem(
          icon: Icons.copy,
          label: 'Copy',
          onTap: () {
            Clipboard.setData(ClipboardData(text: content));
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
      if (!isError && !isGenerating)
        BottomSheetItem(
          icon: Icons.edit,
          label: 'Edit',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            final state = ref.read(chatProvider(charId)).value;
            if (state == null ||
                state.isGenerating ||
                state.isGeneratingImage ||
                state.isPostGenRunning) {
              return;
            }
            ref.read(editingMessageIdProvider(charId).notifier).state =
                messageId;
          },
        ),
      if ((!isUser && isLast && !isGenerating) || isError)
        BottomSheetItem(
          icon: Icons.refresh,
          label: 'Regenerate',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(chatProvider(charId).notifier).regenerateLastAssistant();
          },
        ),
      if (isActivelyGenerating)
        BottomSheetItem(
          icon: Icons.stop_circle,
          iconColor: Colors.orange,
          label: 'Stop Generating',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(chatProvider(charId).notifier).abortGeneration();
          },
        ),
      if (!isError && !isActivelyGenerating)
        BottomSheetItem(
          icon: Icons.call_split,
          label: 'Branch',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(chatProvider(charId).notifier).branchSession(messageIndex);
          },
        ),
      BottomSheetItem(
        icon: isHidden ? Icons.visibility : Icons.visibility_off,
        label: isHidden ? 'Unhide' : 'Hide',
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          ref
              .read(chatProvider(charId).notifier)
              .toggleMessageHidden(messageIndex);
        },
      ),
      if (canDeleteSwipe && !isGenerating)
        BottomSheetItem(
          icon: Icons.delete_sweep_outlined,
          label: 'Delete Swipe',
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref
                .read(chatProvider(charId).notifier)
                .deleteActiveSwipe(messageIndex);
          },
        ),
      if (canDeleteAgentSwipe && !isGenerating)
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'Delete Agent Swipe',
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref
                .read(chatProvider(charId).notifier)
                .deleteActiveAgentSwipe(messageIndex);
          },
        ),
      if (isLast && !isGenerating)
        BottomSheetItem(
          icon: Icons.delete,
          label: 'Delete',
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(chatProvider(charId).notifier).deleteMessage(messageIndex);
          },
        ),
    ],
  ];

  GlazeBottomSheet.show<void>(context, items: items);
}
