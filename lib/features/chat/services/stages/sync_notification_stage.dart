import '../../../../core/models/character.dart';
import '../../../../core/services/generation_notification_service.dart';
import '../../../cloud_sync/sync_provider.dart' show notifySyncMessageGenerated;
import '../../chat_state.dart';
import '../../unread_sessions_provider.dart';
import '../../utils/message_preview.dart';
import 'stage_context.dart';

/// Stage 3 / 2: Sync + notification. Runs immediately after generation
/// completes (or after regen rollback handling). Extracted from the old
/// `_runPostTextSide` so that image tags and extension blocks can be
/// scheduled independently (and after the cleaner when Studio is on).
class SyncNotificationStage {
  final StageContext ctx;

  SyncNotificationStage(this.ctx);

  Future<void> run({
    required ChatState result,
    required int genId,
    required Character? character,
    required GenerationNotificationService notifService,
  }) async {
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;

    notifySyncMessageGenerated(ctx.ref);

    final preview = buildMessagePreview(result.session?.messages ?? const []);
    final sessionId = result.session?.id;
    // Snapshot BEFORE the notification pipeline: it awaits platform channels
    // and SharedPreferences, and the user may leave the chat during that gap.
    // A reply they watched land on screen must never turn into an unread dot.
    final wasActive = notifService.isActiveSession(ctx.charId, sessionId);
    await notifService.onGenerationCompleted(
      character?.name ?? 'Unknown',
      ctx.charId,
      messagePreview: preview,
      sessionId: sessionId,
      msgId: result.session?.messages.isNotEmpty == true
          ? result.session!.messages.last.id
          : null,
      avatarPath: character?.avatarPath,
    );

    // Flag the reply as unread when it landed for a session the user isn't
    // currently looking at (matches the notification suppression rule). The
    // chat list shows a dot + highlight until the session is opened. Both the
    // before- and after-await checks must agree: the reply was neither watched
    // as it landed nor opened while the pipeline ran.
    if (sessionId != null &&
        !wasActive &&
        !notifService.isActiveSession(ctx.charId, sessionId)) {
      ctx.ref.read(unreadSessionsProvider.notifier).markUnread(sessionId);
    }
  }
}
