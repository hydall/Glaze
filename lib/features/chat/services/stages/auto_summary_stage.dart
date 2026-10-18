import 'package:flutter/foundation.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/state/summary_providers.dart';
import '../summary_generation_service.dart';
import 'stage_context.dart';

/// Regenerates the chat summary on its own once enough new messages have piled
/// up since the last one.
///
/// Runs from `PostGenCoordinator`, i.e. only after an assistant turn has been
/// written — a summary is never produced while the user's message is the last
/// one in the log. That is also checked explicitly in [isDue], because the
/// coordinator runs for flows whose final message is not the bot's.
///
/// Background, fire-and-forget: a failed or slow summary must not hold up the
/// chat, and the error surfaces in the Memory sheet on the next manual run.
class AutoSummaryStage {
  final StageContext ctx;

  AutoSummaryStage(this.ctx);

  static const _botRoles = {'assistant', 'character'};

  /// Whether an automatic run is warranted (INV-S4).
  ///
  /// [savedMessageCount] is the message count stamped on the stored summary;
  /// [interval] is the user's "every N messages" setting, `0` meaning off.
  static bool isDue({
    required List<ChatMessage> messages,
    required int savedMessageCount,
    required int interval,
  }) {
    if (interval <= 0 || messages.isEmpty) return false;
    final last = messages.last;
    // Only a real bot reply qualifies: never the user's own turn, and never an
    // error bubble (a failed turn is not content worth summarizing).
    if (!_botRoles.contains(last.role) || last.isError) return false;
    return messages.length - savedMessageCount >= interval;
  }

  Future<void> run(ChatSession? session) async {
    if (!ctx.ref.mounted || session == null) return;
    if (session.messages.isEmpty) return;
    final last = session.messages.last;
    if (!_botRoles.contains(last.role) || last.isError) return;

    final interval = await ctx.ref.read(summaryAutoIntervalProvider.future);
    if (interval <= 0 || !ctx.ref.mounted) return;

    try {
      final summaryService = ctx.ref.read(summaryServiceProvider);
      // A disabled summary is not injected into the prompt, so spending a
      // request on regenerating it would be pure waste.
      if (!await summaryService.isSummaryEnabled(session.id)) return;
      if (!ctx.ref.mounted) return;

      final savedCount = await summaryService.getSummaryMessageCount(
        session.id,
      );
      if (!ctx.ref.mounted) return;
      if (!isDue(
        messages: session.messages,
        savedMessageCount: savedCount,
        interval: interval,
      )) {
        return;
      }

      await ctx.ref
          .read(summaryGenerationServiceProvider)
          .generate(charId: ctx.charId, session: session);
      if (!ctx.ref.mounted) return;
      ctx.ref.read(summaryRevisionProvider.notifier).state++;
    } catch (e) {
      debugPrint('[AutoSummaryStage] auto-summary failed: $e');
    }
  }
}
