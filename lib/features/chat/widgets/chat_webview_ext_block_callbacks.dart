import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/persona.dart';

import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../extensions/models/info_block.dart';
import '../../extensions/providers/info_blocks_provider.dart';
import '../../extensions/services/extension_post_gen_service.dart';
import '../chat_provider.dart';
import 'ext_block_dialogs.dart';

/// Wire-up for the chat WebView's ext-block bridge callbacks
/// (`onExtBlocksRunAll`, `onExtBlockStop`, `onExtBlockRegen`,
/// `onExtBlockRegenImage`, `onExtBlockEdit`, `onExtBlockDelete`).
///
/// Extracted from `chat_webview_widget.dart` so the widget's
/// `onWebViewCreated` callback can stay focused on bridge setup
/// rather than extension block orchestration. The controller is a
/// plain object: it captures the [WidgetRef], the widget's
/// identifiers (charId, sessionId), a refresh hook for the inline
/// ext-block panel, and a [mounted] check. The widget owns the
/// lifecycle.
class ChatWebViewExtBlockCallbacks {
  ChatWebViewExtBlockCallbacks({
    required this.ref,
    required this.charId,
    required this.sessionId,
    required this.context,
    required this.isMounted,
    required this.refreshPanel,
  });

  final WidgetRef ref;
  final String charId;
  final String? sessionId;
  final BuildContext context;
  final bool Function() isMounted;
  final Future<void> Function(String sessionId, String messageId)
      refreshPanel;

  /// Build the `onExtBlocksRunAll` callback: re-runs every enabled
  /// block for the given [messageId] (resolves sessionId/character
  /// from the current widget state).
  Future<void> Function(String messageId) onRunAll() {
    return (String messageId) async {
      if (!isMounted()) return;
      final sessionId = this.sessionId;
      if (sessionId == null || sessionId.isEmpty) return;
      final chatState = ref.read(chatProvider(charId)).value;
      if (chatState == null) return;
      final character = ref.read(characterByIdProvider(charId));
      if (character == null) return;
      final persona = _effectivePersona();
      await ref.read(extensionPostGenServiceProvider).runBlocksForMessage(
            charId: charId,
            sessionId: sessionId,
            messageId: messageId,
            swipeId: _swipeIdFor(chatState.messages, messageId),
            agentSwipeId: _agentSwipeIdFor(chatState.messages, messageId),
            messages: chatState.messages,
            character: character,
            persona: persona,
          );
    };
  }

  /// Build the `onExtBlockStop` callback: cancel any in-flight block
  /// generation for the current session.
  void Function(String blockId, String messageId) onStop() {
    return (_, _) {
      if (!isMounted()) return;
      ref.read(extensionPostGenServiceProvider).cancelBlocks();
    };
  }

  /// Build the `onExtBlockRegen` callback: re-runs a single block
  /// for an already-existing message.
  Future<void> Function(String blockId, String messageId) onRegen() {
    return (String blockId, String messageId) async {
      if (!isMounted()) return;
      final sessionId = this.sessionId;
      if (sessionId == null || sessionId.isEmpty) return;
      final chatState = ref.read(chatProvider(charId)).value;
      if (chatState == null) return;
      final character = ref.read(characterByIdProvider(charId));
      if (character == null) return;
      final persona = _effectivePersona();
      await ref.read(extensionPostGenServiceProvider).rerunBlock(
            blockId: blockId,
            messageId: messageId,
            swipeId: _swipeIdFor(chatState.messages, messageId),
            agentSwipeId: _agentSwipeIdFor(chatState.messages, messageId),
            sessionId: sessionId,
            charId: charId,
            messages: chatState.messages,
            character: character,
            persona: persona,
          );
      if (!isMounted()) return;
      await refreshPanel(sessionId, messageId);
    };
  }

  /// Build the `onExtBlockRegenImage` callback: re-runs only the
  /// image generation step of an existing ext-block (keeps agent HTML).
  Future<void> Function(String blockId, String messageId) onRegenImage() {
    return (String blockId, String messageId) async {
      if (!isMounted()) return;
      final sessionId = this.sessionId;
      if (sessionId == null || sessionId.isEmpty) return;
      final chatState = ref.read(chatProvider(charId)).value;
      if (chatState == null) return;
      final character = ref.read(characterByIdProvider(charId));
      if (character == null) return;
      final persona = _effectivePersona();
      await ref.read(extensionPostGenServiceProvider).rerunImageOnly(
            blockId: blockId,
            messageId: messageId,
            swipeId: _swipeIdFor(chatState.messages, messageId),
            agentSwipeId: _agentSwipeIdFor(chatState.messages, messageId),
            sessionId: sessionId,
            charId: charId,
            character: character,
            persona: persona,
          );
      if (!isMounted()) return;
      await refreshPanel(sessionId, messageId);
    };
  }

  /// Build the `onExtBlockEdit` callback: prompt the user to edit
  /// the block's content and persist the change.
  Future<void> Function(String blockId, String messageId) onEdit() {
    return (String blockId, String messageId) async {
      if (!isMounted()) return;
      final sessionId = this.sessionId;
      if (sessionId == null || sessionId.isEmpty) return;
      final block = _blockForChat(sessionId, messageId, blockId);
      if (block == null) return;
      if (!isMounted()) return;
      // ignore: use_build_context_synchronously
      final newContent = await ExtBlockDialogs.promptEdit(
        context: context,
        blockName: block.blockName,
        initialContent: block.content,
      );
      if (!isMounted()) return;
      if (newContent == null) return;
      await ref
          .read(infoBlocksProvider(sessionId).notifier)
          .updateContent(block.id, newContent);
      if (!isMounted()) return;
      await refreshPanel(sessionId, messageId);
    };
  }

  /// Build the `onExtBlockDelete` callback: confirm with the user
  /// and delete the block from the database.
  Future<void> Function(String blockId, String messageId) onDelete() {
    return (String blockId, String messageId) async {
      if (!isMounted()) return;
      final sessionId = this.sessionId;
      if (sessionId == null || sessionId.isEmpty) return;
      final block = _blockForChat(sessionId, messageId, blockId);
      if (block == null) return;
      if (!isMounted()) return;
      // ignore: use_build_context_synchronously
      final confirmed = await ExtBlockDialogs.confirmDelete(
        context: context,
        blockName: block.blockName,
      );
      if (!isMounted()) return;
      if (!confirmed) return;
      await ref
          .read(infoBlocksProvider(sessionId).notifier)
          .delete(block.id);
      if (!isMounted()) return;
      await refreshPanel(sessionId, messageId);
    };
  }

  Persona? _effectivePersona() {
    return ref.read(
      effectivePersonaForChatProvider((charId: charId, sessionId: sessionId)),
    );
  }

  InfoBlock? _blockForChat(
    String sessionId,
    String messageId,
    String blockId,
  ) {
    final chatState = ref.read(chatProvider(charId)).value;
    if (chatState == null) return null;
    for (final message in chatState.messages) {
      if (message.id != messageId) continue;
      final blocks = ref
          .read(infoBlocksProvider(sessionId).notifier)
          .getByMessageId(
            messageId,
            swipeId: message.swipeId,
            agentSwipeId: message.agentSwipeId,
          );
      for (final block in blocks) {
        if (block.blockId == blockId) return block;
      }
      return null;
    }
    return null;
  }

  static int _swipeIdFor(List<dynamic> messages, String messageId) {
    for (final message in messages) {
      if (message.id == messageId) return message.swipeId as int;
    }
    return 0;
  }

  static int _agentSwipeIdFor(List<dynamic> messages, String messageId) {
    for (final message in messages) {
      if (message.id == messageId) {
        return message.agentSwipeId as int;
      }
    }
    return -1;
  }
}
