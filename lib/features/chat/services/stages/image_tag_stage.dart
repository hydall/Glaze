import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../image_gen_processor.dart';
import '../../chat_generation_service.dart';
import '../../chat_state.dart';
import 'stage_context.dart';

/// Stage 5: Image tags. Operates on the canonical text — when Studio is
/// enabled this runs AFTER the cleaner completes (re-reads the session
/// from DB so image tags bind to the cleaned swipe, not the raw stream).
/// When Studio is off, this runs immediately after sync.
class ImageTagStage {
  final StageContext ctx;

  ImageTagStage(this.ctx);

  Future<void> run({
    required ChatState result,
    required int genId,
    required ChatGenerationService service,
  }) async {
    final targetMessageId = result.session?.messages.lastOrNull?.id;
    if (targetMessageId == null) return;
    final imgCancelToken = CancelToken();
    ctx.abortHandler.imgGenCancelToken = imgCancelToken;

    try {
      await service.processImageTags(
        currentState: result,
        charId: ctx.charId,
        cancelToken: imgCancelToken,
        isCurrentOperation: () =>
            ctx.abortHandler.isCurrentGen(genId) &&
            identical(ctx.abortHandler.imgGenCancelToken, imgCancelToken),
        onStateUpdate: (update) {
          final merged = ImageGenProcessor.mergeOwnedStateUpdate(
            liveState: ctx.getState().value,
            update: update,
            sessionId: result.session!.id,
            targetMessageId: targetMessageId,
            ownsOperation:
                ctx.abortHandler.isCurrentGen(genId) &&
                identical(ctx.abortHandler.imgGenCancelToken, imgCancelToken),
          );
          if (merged != null) ctx.setState(AsyncData(merged));
        },
      );
    } catch (e) {
      debugPrint('[ImageTagStage] processImageTags failed (continuing): $e');
    } finally {
      if (identical(ctx.abortHandler.imgGenCancelToken, imgCancelToken)) {
        ctx.abortHandler.imgGenCancelToken = null;
      }
    }
  }
}
