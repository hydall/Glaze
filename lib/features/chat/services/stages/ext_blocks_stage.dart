import 'package:flutter/foundation.dart';

import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../../core/state/persona_resolution.dart';
import '../../../extensions/services/extension_post_gen_service.dart';
import '../../state/post_gen_status_provider.dart';
import 'stage_context.dart';

/// Launches extension blocks for the trailing assistant message, bound to
/// [agentSwipeId]. Called from [CleanerStage] after the cleaner finalizes
/// (or skips/fails) so blocks always target the swipe the user will
/// actually see:
/// - `agentSwipeId >= 0` → cleaned blue sub-swipe (post-cleaner path).
/// - `agentSwipeId = -1` → original 'final' swipe (cleaner disabled or
///   skipped/fallback branches — legacy binding, identical to pre-patch
///   behavior when the cleaner was off).
/// See docs/plans/PLAN_EXT_BLOCKS_AFTER_CLEANER.md.
class ExtBlocksStage {
  final StageContext ctx;

  ExtBlocksStage(this.ctx);

  Future<void> launchForSwipe({
    required ChatSession session,
    required Character character,
    required int agentSwipeId,
    MainModelContextSnapshot? mainModelContextSnapshot,
  }) async {
    if (session.id.isEmpty || session.messages.isEmpty) return;
    final lastMessage = session.messages.last;
    if (lastMessage.role == 'user' || lastMessage.isError) return;
    PostGenStatusState? runningStatus;
    try {
      final extensionService = ctx.ref.read(extensionPostGenServiceProvider);
      final didRun = await extensionService.processAfterGeneration(
        charId: ctx.charId,
        session: session,
        character: character,
        persona: ctx.ref.read(
          effectivePersonaForChatProvider((
            charId: ctx.charId,
            sessionId: session.id,
          )),
        ),
        agentSwipeId: agentSwipeId,
        onStarted: () {
          if (!ctx.ref.mounted) return;
          final status = PostGenStatusState.running(
            sessionId: session.id,
            task: PostGenTask.extBlocks,
          );
          runningStatus = status;
          ctx.ref.read(postGenStatusProvider.notifier).state = status;
        },
        mainModelContextSnapshot: mainModelContextSnapshot,
      );
      if (didRun &&
          ctx.ref.mounted &&
          identical(ctx.ref.read(postGenStatusProvider), runningStatus)) {
        ctx.ref
            .read(postGenStatusProvider.notifier)
            .state = PostGenStatusState.done(
          sessionId: session.id,
          task: PostGenTask.extBlocks,
        );
      }
    } catch (e) {
      debugPrint('[ExtBlocksStage] launch for swipe=$agentSwipeId failed: $e');
      if (ctx.ref.mounted &&
          identical(ctx.ref.read(postGenStatusProvider), runningStatus)) {
        ctx.ref
            .read(postGenStatusProvider.notifier)
            .state = PostGenStatusState.error(
          sessionId: session.id,
          task: PostGenTask.extBlocks,
        );
      }
    }
  }
}
