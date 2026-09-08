import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/services/generation_notification_service.dart';
import '../../../chat/bridge/chat_bridge_registry.dart';
import '../../models/block_config.dart';

class PeriodicJsBlockRunner {
  const PeriodicJsBlockRunner({required this.ref});

  final Ref ref;

  Future<String?> run({
    required String charId,
    required String sessionId,
    required BlockConfig block,
    required List<ChatMessage> contextMessages,
    bool Function()? isAuthorized,
  }) async {
    if (!(isAuthorized?.call() ?? true)) return null;
    if (block.type != BlockType.jsRunner) {
      throw ArgumentError(
        'runJsBlock only supports BlockType.jsRunner (got ${block.type.name})',
      );
    }
    final script = block.prompt.isNotEmpty ? block.prompt : block.script;
    if (script.isEmpty) {
      return null;
    }
    final bridge = ref.read(chatBridgeRegistryProvider(charId));
    if (bridge == null) {
      debugPrint(
        '[ExtPostGen] runJsBlock: no active chat bridge (block "${block.name}")',
      );
      return null;
    }
    final cancelToken = CancelToken();
    final authoritySub = GenerationNotificationService
        .instance
        .activeChatContextChanges
        .listen((_) {
          if (!(isAuthorized?.call() ?? true) && !cancelToken.isCancelled) {
            cancelToken.cancel('Periodic chat authority changed');
          }
        });
    try {
      if (cancelToken.isCancelled || !(isAuthorized?.call() ?? true)) {
        return null;
      }
      final result = await bridge.runJsBlock(
        script: script,
        messages: contextMessages,
        character: null,
        sessionId: sessionId,
        previousOutput: null,
        contextMessageCount: -1,
        cancelToken: cancelToken,
      );
      return !cancelToken.isCancelled && (isAuthorized?.call() ?? true)
          ? result
          : null;
    } catch (e) {
      debugPrint('[ExtPostGen] runJsBlock failed: $e');
      return null;
    } finally {
      unawaited(authoritySub.cancel());
    }
  }
}
