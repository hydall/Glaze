import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/generation_phase.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../../core/services/generation_notification_service.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/llm/studio_turn_config_snapshot.dart';
import '../../chat_generation_service.dart';
import '../../chat_state.dart';
import 'auto_summary_stage.dart';
import 'chat_embed_stage.dart';
import 'cleaner_stage.dart';
import 'ext_blocks_stage.dart';
import 'image_tag_stage.dart';
import 'ledger_stage.dart';
import 'memory_draft_stage.dart';
import 'stage_context.dart';
import 'sync_notification_stage.dart';

/// Post-generation task scheduler. Replaces the old inline postGenFutures
/// blocks in both the normal and regen paths. Implements the pipeline order
/// from PLAN_STUDIO_PIPELINE_SEPARATION.md §New Pipeline Order:
///
/// Studio ON:
///   3. Sync + notification (immediate, awaited)
///   4. Post-cleaner (fact-checker + rewrite + ext blocks + ledger)
///   5. Image tags — on canonical text, after cleaner
///   6. Embed (parallel fire-and-forget)
///   7. Auto-create drafts (parallel fire-and-forget)
///   8. Auto-summary (parallel fire-and-forget)
///
/// Studio OFF:
///   2. Sync + notification (immediate, awaited)
///   3. Image tags (immediate)
///   4. Ext blocks (immediate, agentSwipeId=-1)
///   5. Embed (parallel fire-and-forget)
///   6. Auto-create drafts (parallel fire-and-forget)
///   7. Auto-summary (parallel fire-and-forget)
class PostGenCoordinator {
  final StageContext ctx;
  final SyncNotificationStage syncStage;
  final ChatEmbedStage embedStage;
  final MemoryDraftStage draftStage;
  final AutoSummaryStage autoSummaryStage;
  final ImageTagStage imageTagStage;
  final ExtBlocksStage extBlocksStage;
  final LedgerStage ledgerStage;
  final CleanerStage cleanerStage;

  PostGenCoordinator(this.ctx)
    : syncStage = SyncNotificationStage(ctx),
      embedStage = ChatEmbedStage(ctx),
      draftStage = MemoryDraftStage(ctx),
      autoSummaryStage = AutoSummaryStage(ctx),
      imageTagStage = ImageTagStage(ctx),
      extBlocksStage = ExtBlocksStage(ctx),
      ledgerStage = LedgerStage(ctx),
      cleanerStage = CleanerStage(
        ctx,
        extBlocks: ExtBlocksStage(ctx),
        ledger: LedgerStage(ctx),
      );

  void _runInBackground(
    Future<void> Function() task,
    String label,
    GenerationNotificationService notifService, {
    void Function()? onTaskNotStarted,
  }) {
    unawaited(() async {
      var taskStarted = false;
      PostGenerationForegroundLease? lease;
      try {
        lease = await notifService.acquirePostGenerationLease();
        taskStarted = true;
        await task();
      } catch (error, stackTrace) {
        debugPrint(
          '[PostGenCoordinator] background $label failed: '
          '$error\n$stackTrace',
        );
      } finally {
        if (!taskStarted) onTaskNotStarted?.call();
        await lease?.release();
      }
    }());
  }

  bool _beginForegroundPostGen({
    required String sessionId,
    required int genId,
  }) {
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
      return false;
    }
    final current = ctx.getState().value;
    if (current == null || current.session?.id != sessionId) return false;
    ctx.setPhase(GenerationPhase.finalizing, genId: genId);
    if (!current.isPostGenRunning) {
      ctx.setState(
        AsyncData(
          current.copyWith(isGenerating: false, isPostGenRunning: true),
        ),
      );
    }
    return true;
  }

  bool _hasForegroundImageWork(ChatSession session) {
    if (session.messages.isEmpty) return false;
    final lastMessage = session.messages.last;
    return (lastMessage.role == 'assistant' ||
            lastMessage.role == 'character') &&
        ImageTagMarkup.hasImageGenTags(lastMessage.content);
  }

  void _launchExtensionBlocksInBackground({
    required ChatSession session,
    required Character? character,
    required MainModelContextSnapshot? mainModelContextSnapshot,
    required GenerationNotificationService notifService,
  }) {
    if (character == null) return;
    _runInBackground(
      () => extBlocksStage.launchForSwipe(
        session: session,
        character: character,
        agentSwipeId: -1,
        mainModelContextSnapshot: mainModelContextSnapshot,
      ),
      'extension blocks',
      notifService,
    );
  }

  Future<void> run({
    required ChatState result,
    required int genId,
    required Character? character,
    required ChatGenerationService service,
    required GenerationNotificationService notifService,
    String? regenTargetId,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;
    if (result.session == null) return;

    final sessionId = result.session!.id;
    final studioEnabled = studioTurnConfig?.enabled == true;
    // Reserve the memory session before the first await so another memory
    // workflow cannot claim the same auto-generation batch while scheduling.
    final ordinaryMemoryLease = studioEnabled
        ? null
        : draftStage.reserveAutoGeneration(result.session);

    // Stage 3 / 2: Sync + notification (immediate, awaited).
    try {
      await syncStage.run(
        result: result,
        genId: genId,
        character: character,
        notifService: notifService,
      );
    } catch (_) {
      ordinaryMemoryLease?.release();
      rethrow;
    }
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
      ordinaryMemoryLease?.release();
      return;
    }

    // Embedding is independent of the Studio Ledger clock and can start from
    // the committed response immediately.
    _runInBackground(
      () => embedStage.run(
        sessionId: sessionId,
        messages: result.session!.messages,
        genId: genId,
      ),
      'chat embedding',
      notifService,
    );
    if (!studioEnabled) {
      _runInBackground(
        () => draftStage.run(
          result.session,
          generationLease: ordinaryMemoryLease,
        ),
        'memory auto-draft',
        notifService,
        onTaskNotStarted: ordinaryMemoryLease?.release,
      );
      _runInBackground(
        () => autoSummaryStage.run(result.session),
        'auto-summary',
        notifService,
      );
    }

    // Determine Studio status before acquiring the foreground post-gen hold.
    // A disabled/no-op ordinary path must not retain that hold.
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;

    if (!studioEnabled) {
      // Ordinary chat does not need a post-gen hold merely to discover that
      // image generation is disabled or the reply has no [IMG:GEN] tag.
      // ExtBlocks are auxiliary and never own the send/Stop lifecycle.
      _launchExtensionBlocksInBackground(
        session: result.session!,
        character: character,
        mainModelContextSnapshot: result.mainModelContextSnapshot,
        notifService: notifService,
      );
      if (!_hasForegroundImageWork(result.session!)) return;
      if (!_beginForegroundPostGen(sessionId: sessionId, genId: genId)) return;

      await imageTagStage.run(result: result, genId: genId, service: service);
      return;
    }

    // Studio foreground work (cleaner and canonical image work) retains the
    // post-gen hold. Always release it, including errors.
    if (!_beginForegroundPostGen(sessionId: sessionId, genId: genId)) return;
    final postGenFutures = <Future<void>>[];

    // Studio ON: cleaner runs first, then image tags on canonical text.
    // Ledger runs inside CleanerStage. Ext blocks are launched from its
    // branches and bind to the swipe the user will see.
    final cleanerTask = cleanerStage.run(
      sessionId: sessionId,
      messages: result.session!.messages,
      genId: genId,
      promptPayload: result.promptPayload,
      mainModelContextSnapshot: result.mainModelContextSnapshot,
      character: character,
      studioTurnConfig: studioTurnConfig,
    );
    postGenFutures.add(cleanerTask);

    // Studio auxiliary consumers need the clock stamped by Ledger, which runs
    // inside CleanerStage. Re-read the durable session after that workflow so
    // Memory and Summary never infer a missing time from the pre-Ledger copy.
    postGenFutures.add(
      cleanerTask.then((_) async {
        if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;
        final refreshed = await ctx.ref
            .read(chatRepoProvider)
            .getById(sessionId);
        if (!ctx.ref.mounted ||
            !ctx.abortHandler.isCurrentGen(genId) ||
            refreshed == null) {
          return;
        }
        final memoryLease = draftStage.reserveAutoGeneration(refreshed);
        _runInBackground(
          () => draftStage.run(refreshed, generationLease: memoryLease),
          'memory auto-draft',
          notifService,
          onTaskNotStarted: memoryLease?.release,
        );
        _runInBackground(
          () => autoSummaryStage.run(refreshed),
          'auto-summary',
          notifService,
        );
      }),
    );

    // Stage 5: Image tags — on canonical text, after cleaner. Re-read
    // the session from DB so image tags bind to the cleaned swipe.
    postGenFutures.add(
      cleanerTask.then((_) async {
        if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
          return;
        }
        final refreshed = await ctx.ref
            .read(chatRepoProvider)
            .getById(sessionId);
        if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
          return;
        }
        if (refreshed == null) {
          return;
        }
        await imageTagStage.run(
          result: ChatState(session: refreshed),
          genId: genId,
          service: service,
        );
      }),
    );

    await Future.wait(postGenFutures);
  }
}
