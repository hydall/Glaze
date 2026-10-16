import 'package:flutter/foundation.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/models/summary_block.dart';
import '../../../../core/state/summary_providers.dart';
import '../summary_generation_service.dart';
import 'stage_context.dart';

/// Compacts the chat summary on its own once the prompt is full enough.
///
/// Runs from `PostGenCoordinator`, i.e. only after an assistant turn has been
/// written — a summary is never produced while the user's message is the last
/// one in the log. That is also checked explicitly in [isEligible], because the
/// coordinator runs for flows whose final message is not the bot's.
///
/// Whether there is anything to do is decided by
/// [SummaryGenerationService.compact] from how full the prompt is (INV-S4);
/// below the trigger it returns without a request.
///
/// Background, fire-and-forget: a failed or slow summary must not hold up the
/// chat, and the error surfaces in the Memory sheet on the next manual run.
class AutoSummaryStage {
  final StageContext ctx;

  AutoSummaryStage(this.ctx);

  static const _botRoles = {'assistant', 'character'};

  /// Whether the last turn allows an automatic run at all: a real bot reply,
  /// never the user's own turn and never an error bubble.
  static bool isEligible(List<ChatMessage> messages) {
    if (messages.isEmpty) return false;
    final last = messages.last;
    return _botRoles.contains(last.role) && !last.isError;
  }

  Future<void> run(ChatSession? session) async {
    if (!ctx.ref.mounted || session == null) return;
    if (!isEligible(session.messages)) return;

    final settings = await ctx.ref.read(
      summaryCompactionSettingsProvider.future,
    );
    if (!settings.autoEnabled || !ctx.ref.mounted) return;

    try {
      final summaryService = ctx.ref.read(summaryServiceProvider);
      // A disabled summary is not injected into the prompt, so spending a
      // request on it would be pure waste.
      if (!await summaryService.isSummaryEnabled(session.id)) return;
      if (!ctx.ref.mounted) return;
      if (SummaryGenerationService.isRunning(session.id)) return;

      await ctx.ref
          .read(summaryGenerationServiceProvider)
          .compact(charId: ctx.charId, session: session);
    } on SummaryChainException catch (e) {
      debugPrint('[AutoSummaryStage] skipped: ${e.reason}');
    } catch (e) {
      debugPrint('[AutoSummaryStage] auto-summary failed: $e');
    }
  }
}
