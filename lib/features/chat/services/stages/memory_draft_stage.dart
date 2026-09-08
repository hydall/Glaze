import 'package:flutter/foundation.dart';

import '../../../../core/llm/memory_draft_planner.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/memory_settings_provider.dart';
import 'stage_context.dart';

/// Stage 9 / 6: Auto-create memory drafts (parallel fire-and-forget,
/// no LLM — just a planner over the MemoryBook).
class MemoryDraftStage {
  final StageContext ctx;

  MemoryDraftStage(this.ctx);

  Future<void> run(ChatSession? session) async {
    if (!ctx.ref.mounted) return;
    if (session == null) return;
    final settings = ctx.ref.read(memoryGlobalSettingsProvider);
    if (!settings.enabled || !settings.autoCreateEnabled) return;

    try {
      final repo = ctx.ref.read(memoryBookRepoProvider);
      final book = await repo.ensureForSession(session.id);
      if (!ctx.ref.mounted) return;
      final plan = MemoryDraftPlanner.plan(
        book: book,
        messages: session.messages,
        interval: settings.autoCreateInterval,
        lagMessages: settings.autoCreateLagMessages,
        source: 'auto_create',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
      );
      if (plan.drafts.isEmpty) return;

      await repo.put(
        book.copyWith(pendingDrafts: [...book.pendingDrafts, ...plan.drafts]),
      );
    } catch (e) {
      debugPrint('[MemoryDraftStage] auto-create failed: $e');
    }
  }
}
