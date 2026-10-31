import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/llm/history_trim.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../extensions/services/extension_post_gen_service.dart';
import '../../settings/api_list_provider.dart';
import '../chat_provider.dart';
import '../editing_message_provider.dart';
import 'ext_block_dialogs.dart';
import 'message_delete_confirmation.dart';

void showMessageContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String charId,
  required String? sessionId,
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
  Future<bool> Function()? beforeRegenerate,
}) {
  // Notifier is read fresh inside each onTap callback instead of captured
  // here. If the provider is invalidated while the menu is open (e.g. by a
  // background session switch), a captured reference would be disposed and
  // every callback would throw "Cannot use Ref after disposed".
  final isActivelyGenerating = isGenerating && isLast && !isUser;
  final isTypingTarget = isTyping && !isUser;
  final rewriteBlocks = ref
      .read(extensionPostGenServiceProvider)
      .rewriteBlocks(charId);
  // Only the stepped trim holds the start of the history still, so only
  // there is a place to pin it. A hidden message is not in the prompt.
  final session = ref.read(chatProvider(charId)).value?.session;
  final canPinAnchor =
      !isHidden &&
      !isTyping &&
      session != null &&
      session.id == sessionId &&
      ref.read(activeApiConfigProvider)?.historyTrimMode ==
          HistoryTrimMode.stepped;
  final pinnedHere =
      session != null &&
      session.historyAnchorPinned &&
      session.historyAnchorId == messageId;

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
            final editing = ref.read(editingMessageIdProvider(charId).notifier);
            // Already pointed at this message means the tap is not changing the
            // value, and a same-value write notifies nobody — so the WebView
            // never gets another `startEdit`. That is the "tap edit again does
            // nothing" report: the editor UI was lost (keyboard dismissed, list
            // re-rendered) while the provider stayed set. Cycle through null so
            // the listener stops the stale session and opens a fresh editor.
            if (editing.state == messageId) editing.state = null;
            editing.state = messageId;
          },
        ),
      if (!isError &&
          !isGenerating &&
          sessionId != null &&
          rewriteBlocks.isNotEmpty)
        BottomSheetItem(
          icon: Icons.auto_fix_high,
          label: 'extblocks_rewrite_action'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final request = await ExtBlockDialogs.promptRewrite(
              context: context,
              blocks: rewriteBlocks,
            );
            if (request == null) return;
            final state = ref.read(chatProvider(charId)).value;
            final character = ref.read(characterByIdProvider(charId));
            if (state == null ||
                character == null ||
                state.session?.id != sessionId ||
                state.isGenerating) {
              return;
            }
            final persona = ref.read(
              effectivePersonaForChatProvider((
                charId: charId,
                sessionId: sessionId,
              )),
            );
            await ref
                .read(extensionPostGenServiceProvider)
                .runRewriteBlock(
                  blockId: request.blockId,
                  charId: charId,
                  sessionId: sessionId,
                  messageId: messageId,
                  messages: state.messages,
                  character: character,
                  persona: persona,
                  textToRewrite: request.fragment.trim().isEmpty
                      ? null
                      : request.fragment,
                  additionalPrompt: request.additionalPrompt,
                );
          },
        ),
      if ((!isUser && isLast && !isGenerating) || isError)
        BottomSheetItem(
          icon: Icons.refresh,
          label: 'Regenerate',
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            if (await beforeRegenerate?.call() == false) return;
            await ref
                .read(chatProvider(charId).notifier)
                .regenerateLastAssistant();
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
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final branch = await ref
                .read(chatProvider(charId).notifier)
                .branchSession(messageIndex);
            if (branch != null && context.mounted) {
              // A branch that kept the source card lands on that character's
              // next session index, not on 0.
              context.go(
                '/chat/${branch.characterId}?session=${branch.sessionIndex}',
              );
            }
          },
        ),
      if (canPinAnchor && !isGenerating)
        BottomSheetItem(
          icon: Icons.anchor,
          label: pinnedHere
              ? 'action_unpin_cache_anchor'.tr()
              : 'action_pin_cache_anchor'.tr(),
          hint: 'action_pin_cache_anchor_hint'.tr(),
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final notifier = ref.read(chatProvider(charId).notifier);
            if (pinnedHere) {
              await notifier.unpinHistoryAnchor();
            } else {
              await notifier.pinHistoryAnchor(messageIndex);
            }
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
      if (!isGenerating)
        BottomSheetItem(
          icon: Icons.delete,
          label: 'Delete',
          isDestructive: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            if (!await confirmMessageDeletion(
              context,
              ref,
              sessionId: sessionId,
            )) {
              return;
            }
            if (!context.mounted) return;
            await ref
                .read(chatProvider(charId).notifier)
                .deleteMessage(messageIndex);
          },
        ),
    ],
  ];

  GlazeBottomSheet.show<void>(context, items: items);
}
