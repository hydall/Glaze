import 'dart:convert';
import 'dart:io';

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
import '../widgets/memory_sheet.dart';
import '../widgets/prompt_inspector_sheet.dart';
import '../widgets/session_picker_sheet.dart';

/// Opens the sheet behind a Tools-tab card, by card id.
///
/// Lived inside the drawer panel until the composer's pinned row could hold
/// tools too: a pinned card is tapped from the input bar, where the drawer is
/// not even mounted, so the behaviour had to stop being the panel's private
/// state. Every sheet here opens on the root navigator, so any context in the
/// chat route drives it.
class DrawerItemLauncher {
  final WidgetRef ref;
  final String charId;

  /// Hides the hosting drawer before an item navigates away from the chat.
  /// Null when the launcher runs from the composer's pinned row, where there is
  /// no open drawer to get out of the way.
  final VoidCallback? onClose;

  const DrawerItemLauncher({
    required this.ref,
    required this.charId,
    this.onClose,
  });

  /// Runs the card named [itemId]. Unknown ids are ignored — a stored layout or
  /// a pinned button may still name a card this build has dropped.
  Future<void> open(BuildContext context, String itemId) async {
    switch (itemId) {
      case 'inspector':
        await showPromptInspectorSheet(context, charId);
      case 'memory':
        await showMemorySheet(context, charId);
      case 'sessions':
        await _showSessionsSheet(context);
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
      case 'lorebooks':
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          barrierColor: Colors.black54,
          isScrollControlled: true,
          builder: (_) => const LorebookListScreen(),
        );
      case 'regex':
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          barrierColor: Colors.black54,
          isScrollControlled: true,
          builder: (_) => const RegexSheet(),
        );
      case 'api':
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          barrierColor: Colors.black54,
          isScrollControlled: true,
          builder: (_) => const ApiSettingsScreen(),
        );
      case 'presets':
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          barrierColor: Colors.black54,
          isScrollControlled: true,
          builder: (_) => PresetListScreen(charId: charId),
        );
      case 'personas':
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => const PersonaListScreen(),
        );
      case 'image-gen':
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => ImageGenSheet(charId: charId),
        );
      case 'authors-note':
        await showAuthorsNoteSheet(context, charId);
      case 'glossary':
        await GlossarySheet.show(context);
      case 'ext-blocks':
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          backgroundColor: context.cs.surfaceContainerHigh,
          isScrollControlled: true,
          builder: (_) => const ExtBlocksSettingsSheet(),
        );
      case 'agent-ops':
        await _showAgentOpsLog(context);
      case 'card-rewriter':
        await _showCardRewriter(context);
    }
  }

  Future<void> _showCardRewriter(BuildContext context) async {
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

  Future<void> _showAgentOpsLog(BuildContext context) async {
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

  Future<void> _showSessionsSheet(BuildContext context) async {
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
        await _importChat(context);
    }
  }

  Future<void> _importChat(BuildContext context) async {
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
        final importResult = importChatFromJsonlString(utf8.decode(file.bytes!));
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
