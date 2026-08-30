import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/utils/error_format.dart';
import '../../../chat/bridge/chat_bridge_controller.dart';
import '../../../chat/bridge/chat_bridge_registry.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import '../block_context_builder.dart';
import 'block_context.dart';
import 'infoblock_handler.dart';

class JsBlockExecutor {
  const JsBlockExecutor({
    required this.ref,
    required this.repo,
    required this.markBlockError,
    required this.refreshPanelForMessage,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final BlockErrorMarker markBlockError;
  final PanelRefresher refreshPanelForMessage;

  Future<InfoBlock?> executeMessageScript({
    required BlockContext context,
    required String script,
    String Function(String result)? panelContentBuilder,
  }) async {
    final blockConfig = context.blockConfig;
    final bridge = ref.read(chatBridgeRegistryProvider(context.charId));
    if (bridge == null) {
      debugPrint(
        '[ExtPostGen] jsRunner "${blockConfig.name}" - Chat WebView bridge unavailable',
      );
      return markBlockError(
        context: context,
        errorMessage: 'Chat WebView JS bridge is unavailable',
      );
    }

    try {
      final contextMessages = buildContextMessages(
        messages: context.messages,
        anchorMessageId: context.messageId,
        count: blockConfig.contextMessageCount,
      );
      final result = await runWithFallback(
        bridge: bridge,
        script: script,
        contextMessages: contextMessages,
        character: context.character,
        sessionId: context.sessionId,
        previousOutput: context.previousOutput,
        cancelToken: context.cancelToken,
      );

      if (context.cancelToken.isCancelled) {
        await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
        final stopped = context.placeholder.copyWith(
          status: BlockRunStatus.stopped,
        );
        ref
            .read(infoBlocksProvider(context.sessionId).notifier)
            .addOrReplace(stopped);
        refreshPanelForMessage(
          context.charId,
          context.sessionId,
          context.messageId,
          context.swipeId,
          context.agentSwipeId,
        );
        return stopped;
      }

      final content = panelContentBuilder?.call(result) ?? result;

      await repo.updateContent(context.placeholderId, content);
      await repo.updateStatus(context.placeholderId, BlockRunStatus.done);

      final done = InfoBlock(
        id: context.placeholderId,
        sessionId: context.sessionId,
        messageId: context.messageId,
        swipeId: context.swipeId,
        agentSwipeId: context.agentSwipeId,
        blockId: blockConfig.id,
        blockName: blockConfig.name,
        blockType: blockConfig.type.name,
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: blockConfig.order,
        status: BlockRunStatus.done,
      );
      ref
          .read(infoBlocksProvider(context.sessionId).notifier)
          .addOrReplace(done);
      refreshPanelForMessage(
        context.charId,
        context.sessionId,
        context.messageId,
        context.swipeId,
        context.agentSwipeId,
      );
      return done;
    } catch (e) {
      if (context.cancelToken.isCancelled) {
        await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
        final stopped = context.placeholder.copyWith(
          status: BlockRunStatus.stopped,
        );
        ref
            .read(infoBlocksProvider(context.sessionId).notifier)
            .addOrReplace(stopped);
        refreshPanelForMessage(
          context.charId,
          context.sessionId,
          context.messageId,
          context.swipeId,
          context.agentSwipeId,
        );
        return stopped;
      }
      debugPrint('[ExtPostGen] jsRunner "${blockConfig.name}" failed: $e');
      return markBlockError(context: context, errorMessage: formatError(e));
    }
  }

  static Future<String> runWithFallback({
    required ChatBridgeController? bridge,
    required String script,
    required List<ChatMessage> contextMessages,
    required Character? character,
    required String sessionId,
    required String? previousOutput,
    required CancelToken cancelToken,
  }) async {
    final visualBridge = bridge;
    if (visualBridge == null) {
      throw StateError('Chat WebView JS bridge is unavailable');
    }
    return visualBridge.runJsBlock(
      script: script,
      messages: contextMessages,
      character: character,
      sessionId: sessionId,
      previousOutput: previousOutput,
      contextMessageCount: -1,
      cancelToken: cancelToken,
    );
  }

  static Map<String, dynamic> jsContextMap({
    required List<Map<String, String>> messages,
    required Character? character,
    required String sessionId,
    required String? previousOutput,
  }) {
    return {
      'messages': messages,
      'sessionId': sessionId,
      'characterId': character?.id,
      'character': character == null
          ? null
          : {
              'name': character.name,
              'description': character.description ?? '',
              'personality': character.personality ?? '',
              'scenario': character.scenario ?? '',
            },
      'previousOutput': previousOutput,
    };
  }
}
