import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/persona.dart';
import '../../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../../core/utils/error_format.dart';
import '../../models/block_config.dart';
import '../../models/extension_preset.dart';
import '../../models/info_block.dart';
import 'block_context.dart';
import 'block_handler.dart';
import 'block_status_tracker.dart';

class SingleBlockRunner {
  const SingleBlockRunner({
    required this.statusTracker,
    required this.refreshPanelForMessage,
    required this.handlerFor,
  });

  final BlockStatusTracker statusTracker;
  final BlockPanelRefresh refreshPanelForMessage;
  final BlockHandler Function(BlockType type) handlerFor;

  Future<InfoBlock?> run({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required ExtensionPreset preset,
    required Character character,
    required Persona? persona,
    required String? previousOutput,
    required CancelToken cancelToken,
    String? reuseBlockId,
    MainModelContextSnapshot? mainModelContextSnapshot,
  }) async {
    if (cancelToken.isCancelled) return null;

    final prepared = await statusTracker.prepare(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      blockConfig: blockConfig,
      reuseBlockId: reuseBlockId,
    );
    final placeholderId = prepared.placeholderId;
    final placeholder = prepared.placeholder;

    if (cancelToken.isCancelled) {
      return statusTracker.markStoppedForPlaceholder(
        charId: charId,
        sessionId: sessionId,
        messageId: messageId,
        placeholderId: placeholderId,
        placeholder: placeholder,
      );
    }

    refreshPanelForMessage(charId, sessionId, messageId, swipeId, agentSwipeId);

    final context = BlockContext(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      messages: messages,
      blockConfig: blockConfig,
      preset: preset,
      character: character,
      persona: persona,
      previousOutput: previousOutput,
      cancelToken: cancelToken,
      placeholderId: placeholderId,
      placeholder: placeholder,
      mainModelContextSnapshot: mainModelContextSnapshot,
    );

    try {
      final result = await handlerFor(blockConfig.type).handle(context);
      if (cancelToken.isCancelled && result == null) {
        return statusTracker.markStoppedForPlaceholder(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          placeholderId: placeholderId,
          placeholder: placeholder,
        );
      }
      return result;
    } catch (e) {
      if (!cancelToken.isCancelled) {
        debugPrint('[ExtPostGen] Error in block "${blockConfig.name}": $e');
        return statusTracker.markErrorForPlaceholder(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          placeholderId: placeholderId,
          placeholder: placeholder,
          errorMessage: formatError(e),
        );
      }
      return statusTracker.markStoppedForPlaceholder(
        charId: charId,
        sessionId: sessionId,
        messageId: messageId,
        placeholderId: placeholderId,
        placeholder: placeholder,
      );
    }
  }
}
