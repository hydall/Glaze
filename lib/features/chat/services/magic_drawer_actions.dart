import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/chat_import_export.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../card_rewrite/card_rewriter_studio_sheet.dart';
import '../../character_list/character_detail_screen.dart';
import '../../extensions/widgets/ext_blocks_settings_sheet.dart';
import '../../glossary/glossary_sheet.dart';
import '../../image_gen/widgets/image_gen_sheet.dart';
import '../../lorebooks/lorebook_list_screen.dart';
import '../../personas/persona_list_screen.dart';
import '../../presets/preset_list_screen.dart';
import '../../regex/regex_sheet.dart';
import '../../settings/api_settings_screen.dart';
import '../chat_actions_service.dart';
import '../chat_provider.dart';
import '../widgets/agentic_operations_log_dialog.dart';
import '../widgets/authors_note_sheet.dart';
import '../widgets/magic_drawer_models.dart';
import '../widgets/memory_sheet.dart';
import '../widgets/prompt_inspector_sheet.dart';
import '../widgets/session_picker_sheet.dart';

/// The Quick Access catalogue and the sheet each entry opens.
///
/// Both surfaces that offer Quick Access go through this: the full
/// [MagicDrawerPanel] grid, and the collapsed icon strip in the desktop right
/// sidebar. Keeping the catalogue and the dispatch here is what lets the strip
/// open exactly the same sheets as the panel without duplicating either list.
class MagicDrawerActions {
  final String charId;

  /// Asks the host to hide the panel before an action navigates away from the
  /// chat. The sidebar strip has nothing to hide and leaves it null.
  final VoidCallback? onClose;

  /// Scrolls the chat webview to a message id, when the host has a webview.
  final Future<void> Function(String messageId)? onScrollToMessage;

  const MagicDrawerActions({
    required this.charId,
    this.onClose,
    this.onScrollToMessage,
  });

  /// Every Quick Access entry, in default order.
  static final all = <MagicDrawerItemDef>[
    MagicDrawerItemDef(
      id: 'inspector',
      label: 'prompt_inspector_title'.tr(),
      icon: Icons.travel_explore,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'memory',
      label: 'Memory',
      icon: Icons.subject,
      category: MagicDrawerCategory.session,
    ),
    MagicDrawerItemDef(
      id: 'sessions',
      label: 'history_title'.tr(),
      icon: Icons.history,
      category: MagicDrawerCategory.session,
    ),
    MagicDrawerItemDef(
      id: 'char-card',
      label: 'menu_characters'.tr(),
      icon: Icons.account_box,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'lorebooks',
      label: 'label_lorebooks'.tr(),
      icon: Icons.library_books,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'regex',
      label: 'menu_regex'.tr(),
      icon: Icons.code,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'api',
      label: 'tab_api'.tr(),
      icon: Icons.cloud,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'presets',
      label: 'tab_presets'.tr(),
      icon: Icons.description,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'personas',
      label: 'menu_personas'.tr(),
      icon: Icons.manage_accounts,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'image-gen',
      label: 'imggen_title'.tr(),
      icon: Icons.image,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'authors-note',
      label: 'magic_authors_notes'.tr(),
      icon: Icons.edit_note,
      category: MagicDrawerCategory.session,
    ),
    MagicDrawerItemDef(
      id: 'glossary',
      label: 'menu_glossary'.tr(),
      icon: Icons.menu_book,
      category: MagicDrawerCategory.library,
    ),
    MagicDrawerItemDef(
      id: 'ext-blocks',
      label: 'Ext Blocks',
      icon: Icons.extension_outlined,
      category: MagicDrawerCategory.config,
    ),
    MagicDrawerItemDef(
      id: 'agent-ops',
      label: 'agent_ops_title'.tr(),
      icon: Icons.smart_toy_outlined,
      category: MagicDrawerCategory.tools,
    ),
    MagicDrawerItemDef(
      id: 'card-rewriter',
      label: 'magic_card_rewriter'.tr(),
      icon: Icons.auto_fix_high_outlined,
      category: MagicDrawerCategory.tools,
    ),
  ];

  /// Runs the action behind [item]. [onFinished] runs once the action
  /// resolves, whether it completed or threw — the panel uses it to refresh
  /// its stats; the sidebar strip has none to refresh and passes null.
  Future<void> handleTap(
    BuildContext context,
    WidgetRef ref,
    MagicDrawerItemDef item, {
    Future<void> Function()? onFinished,
  }) async {
    try {
      switch (item.id) {
        case 'inspector':
          await showPromptInspectorSheet(context, charId);
          break;
        case 'memory':
          await showMemorySheet(context, charId);
          break;
        case 'sessions':
          await _showSessionsSheet(context, ref);
          break;
        case 'char-card':
          final result = await showModalBottomSheet<String>(
            context: context,
            isScrollControlled: true,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            builder: (_) => CharacterDetailScreen(charId: charId),
          );
          if (result != null && result.isNotEmpty && context.mounted) {
            // Real navigation away from the chat - close the panel first.
            onClose?.call();
            context.go(result);
          }
          break;
        case 'lorebooks':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => const LorebookListScreen(),
          );
          break;
        case 'regex':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => const RegexSheet(),
          );
          break;
        case 'api':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => const ApiSettingsScreen(),
          );
          break;
        case 'presets':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            isScrollControlled: true,
            builder: (_) => PresetListScreen(charId: charId),
          );
          break;
        case 'personas':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const PersonaListScreen(),
          );
          break;
        case 'image-gen':
          await showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => ImageGenSheet(charId: charId),
          );
          break;
        case 'authors-note':
          await showAuthorsNoteSheet(context, charId);
          break;
        case 'glossary':
          await GlossarySheet.show(context);
          break;
        case 'ext-blocks':
          await _showExtBlocksSheet(context, ref);
          break;
        case 'agent-ops':
          await _showAgentOpsLog(context, ref);
          break;
        case 'card-rewriter':
          await _showCardRewriter(context, ref);
          break;
      }
    } finally {
      if (onFinished != null) await onFinished();
    }
  }

  Future<void> _showCardRewriter(BuildContext context, WidgetRef ref) async {
    final session = ref.read(chatProvider(charId)).value?.session;
    if (session == null) return;
    final route = await CardRewriterStudioSheet.show(
      context,
      charId: charId,
      sessionId: session.id,
    );
    if (!context.mounted) return;
    if (route != null && route.isNotEmpty) {
      onClose?.call();
      context.go(route);
    }
  }

  Future<void> _showAgentOpsLog(BuildContext context, WidgetRef ref) async {
    final session = ref.read(chatProvider(charId)).value?.session;
    final route = await AgenticOperationsLogDialog.show(
      context,
      sessionId: session?.id,
      characterId: charId,
    );
    if (!context.mounted) return;
    if (route != null && route.isNotEmpty) {
      onClose?.call();
      context.go(route);
    }
  }

  Future<void> _showExtBlocksSheet(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: context.cs.surfaceContainerHigh,
      isScrollControlled: true,
      builder: (_) => const ExtBlocksSettingsSheet(),
    );
  }

  Future<void> _showSessionsSheet(BuildContext context, WidgetRef ref) async {
    final currentSession = ref.read(chatProvider(charId)).value?.session;
    if (currentSession == null) return;

    if (!context.mounted) return;
    // The same picker the character catalog opens — see
    // `showSessionPickerSheet`. Only what a pick does differs: here it switches
    // the open chat in place instead of routing to it.
    final result = await showSessionPickerSheet(context, charId: charId);
    if (result == null || !context.mounted) return;
    switch (result.action) {
      case SessionPickerAction.open:
        final target = result.session!.sessionIndex;
        final current = ref
            .read(chatProvider(charId))
            .value
            ?.session
            ?.sessionIndex;
        if (target == current) return;
        try {
          await ref
              .read(chatProvider(charId).notifier)
              .switchSession(target)
              .timeout(const Duration(seconds: 30));
        } catch (error) {
          if (context.mounted) {
            GlazeErrorDialog.show(
              context,
              error,
              prefix: 'Failed to switch chat session',
            );
          }
        }
      case SessionPickerAction.newSession:
        await ref.read(chatProvider(charId).notifier).newSession();
      case SessionPickerAction.importChat:
        await _importChat(context, ref);
    }
  }

  Future<void> _importChat(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      type: Platform.isIOS ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isIOS ? null : ['jsonl', 'json'],
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final filePath = file.path;
    try {
      ChatImportSaveResult saveResult;
      if (file.bytes != null) {
        final importResult = importChatFromJsonlString(
          utf8.decode(file.bytes!),
        );
        saveResult = await ref
            .read(chatActionsServiceProvider)
            .importChatFromResult(charId, importResult);
      } else if (filePath != null) {
        saveResult = await ref
            .read(chatActionsServiceProvider)
            .importChat(charId, filePath);
      } else {
        return;
      }
      if (!context.mounted) return;
      final count = saveResult.count;
      final sessionIndex = saveResult.sessionIndex;
      if (count > 0 && sessionIndex != null) {
        // The sessions sheet has already resolved and closed itself by the
        // time this runs (`showSessionPickerSheet` pops with the picked
        // action), so there is nothing left here to pop.
        context.go('/chat/$charId?session=$sessionIndex');
      }
      GlazeToast.show(
        context,
        count == 0 ? 'No messages found in file' : 'Imported $count messages',
      );
    } catch (e) {
      if (context.mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'Import failed: ');
      }
    }
  }
}
