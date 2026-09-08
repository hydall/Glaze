import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chat_message.dart';
import '../../core/llm/studio_turn_config_snapshot.dart';
import 'chat_state.dart';
import 'services/stream_generation_service.dart';
import 'services/image_gen_processor.dart';

final chatGenerationServiceProvider = Provider<ChatGenerationService>((ref) {
  return ChatGenerationService(ref);
});

class ChatGenerationService {
  final Ref _ref;

  ChatGenerationService(this._ref);

  Future<ChatState> generate({
    required ChatSession session,
    ChatSession? saveSession,
    required String charId,
    required int genId,
    required ChatState currentState,
    required void Function(ChatState) onStateUpdate,
    required bool Function() isAborted,
    List<String>? previousSwipes,
    int previousSwipeId = 0,
    String? previousReasoning,
    String? previousGenTime,
    int? previousTokens,
    List<Map<String, dynamic>>? previousSwipesMeta,
    String? guidanceText,
    String? regenTargetId,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    return StreamGenerationService(
      ref: _ref,
      charId: charId,
      genId: genId,
      isAborted: isAborted,
    ).run(
      session: session,
      saveSession: saveSession,
      previousSwipes: previousSwipes,
      previousSwipeId: previousSwipeId,
      previousReasoning: previousReasoning,
      previousGenTime: previousGenTime,
      previousTokens: previousTokens,
      previousSwipesMeta: previousSwipesMeta,
      guidanceText: guidanceText,
      regenTargetId: regenTargetId,
      currentState: currentState,
      studioTurnConfig: studioTurnConfig,
    );
  }

  Future<void> processImageTags({
    required ChatState currentState,
    required String charId,
    String? targetMessageId,
    CancelToken? cancelToken,
    bool Function()? isCurrentOperation,
    required void Function(ChatState) onStateUpdate,
  }) async {
    return ImageGenProcessor(
      ref: _ref,
      charId: charId,
      cancelToken: cancelToken,
      isCurrentOperation: isCurrentOperation,
      onStateUpdate: onStateUpdate,
    ).process(currentState, targetMessageId: targetMessageId);
  }
}
