import 'package:flutter/foundation.dart';

import '../../../../core/llm/memory_draft_planner.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/memory_book.dart';
import '../../../../core/models/pipeline_settings.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/memory_settings_provider.dart';
import '../../../memory/state/memory_active_drafts_provider.dart';
import '../../memory_draft_generator.dart';
import 'stage_context.dart';

typedef GenerateMemoryDraft =
    Future<MemoryDraft> Function({
      required MemoryDraft draft,
      required MemoryBookSettings settings,
      required PipelineSettings pipeline,
      required List<ChatMessage> messages,
      required String charId,
      required String sessionId,
      required Map<String, String> sessionVars,
    });

/// Stage 9 / 6: Auto-create memory drafts and optionally fill them with the
/// configured Memory Book LLM.
class MemoryDraftStage {
  final StageContext ctx;
  final GenerateMemoryDraft _generate;

  MemoryDraftStage(this.ctx, {GenerateMemoryDraft? generate})
    : _generate =
          generate ??
          (({
            required draft,
            required settings,
            required pipeline,
            required messages,
            required charId,
            required sessionId,
            required sessionVars,
          }) => MemoryDraftGenerator(ctx.ref).generate(
            draft: draft,
            settings: settings,
            pipeline: pipeline,
            messages: messages,
            charId: charId,
            sessionId: sessionId,
            sessionVars: sessionVars,
          ));

  MemoryDraftLease? reserveAutoGeneration(ChatSession? session) {
    if (session == null || !ctx.ref.mounted) return null;
    final settings = ctx.ref.read(memoryGlobalSettingsProvider);
    if (!settings.enabled ||
        !settings.autoCreateEnabled ||
        !settings.autoGenerateEnabled) {
      return null;
    }
    return ctx.ref
        .read(memoryActiveDraftsProvider.notifier)
        .tryAcquireExclusive(session.id);
  }

  Future<void> run(
    ChatSession? session, {
    MemoryDraftLease? generationLease,
  }) async {
    try {
      if (!ctx.ref.mounted || session == null) return;
      final settings = ctx.ref.read(memoryGlobalSettingsProvider);
      if (!settings.enabled || !settings.autoCreateEnabled) return;
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

      await repo.appendDrafts(session.id, plan.drafts);
      if (!settings.autoGenerateEnabled || generationLease == null) return;

      final pipeline = ctx.ref.read(pipelineSettingsProvider);
      for (final draft in plan.drafts.take(settings.batchSize)) {
        if (!ctx.ref.mounted) return;
        final draftMessages = session.messages
            .where((message) => draft.messageIds.contains(message.id))
            .toList();
        if (draftMessages.isEmpty) continue;
        try {
          final generated = await _generate(
            draft: draft,
            settings: book.settings,
            pipeline: pipeline,
            messages: draftMessages,
            charId: ctx.charId,
            sessionId: session.id,
            sessionVars: session.sessionVars,
          );
          if (!ctx.ref.mounted) return;
          await repo.mutateDraft(
            sessionId: session.id,
            draftId: draft.id,
            mutate: (current) => current.copyWith(
              content: generated.content,
              keys: generated.keys,
              keyParagraphs: generated.keyParagraphs,
              status: 'pending_approval',
              generatedAt: generated.generatedAt,
              updatedAt: generated.updatedAt,
              error: null,
            ),
          );
        } catch (e) {
          if (!ctx.ref.mounted) return;
          await repo.mutateDraft(
            sessionId: session.id,
            draftId: draft.id,
            mutate: (current) => current.copyWith(
              status: 'needs_regeneration',
              error: e.toString(),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[MemoryDraftStage] auto-create failed: $e');
    } finally {
      generationLease?.release();
    }
  }
}
