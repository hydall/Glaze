import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/generation_phase.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../../core/services/generation_notification_service.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../chat_generation_service.dart';
import '../../chat_state.dart';
import 'auto_summary_stage.dart';
import 'cleaner_stage.dart';
import 'ledger_stage.dart';
import '../agents/agent_turn_service.dart';
import '../../../../core/llm/post_gen_engine_config.dart';
import '../../../../core/state/db_provider.dart';
import 'chat_embed_stage.dart';
import 'ext_blocks_stage.dart';
import 'image_tag_stage.dart';
import 'memory_draft_stage.dart';
import 'stage_context.dart';
import 'sync_notification_stage.dart';

/// Post-generation task scheduler. Runs after the reply is committed:
///   1. Sync + notification (immediate, awaited)
///   2. Embed, auto-summary and memory auto-draft (parallel fire-and-forget)
///   3. Ext blocks (background, agentSwipeId=-1)
///   4. Image tags (foreground, only when the reply carries an [IMG:GEN] tag)
class PostGenCoordinator {
  final StageContext ctx;
  final SyncNotificationStage syncStage;
  final ChatEmbedStage embedStage;
  final MemoryDraftStage draftStage;
  final AutoSummaryStage autoSummaryStage;
  final ImageTagStage imageTagStage;
  final ExtBlocksStage extBlocksStage;
  final CleanerStage cleanerStage;

  PostGenCoordinator(this.ctx)
    : syncStage = SyncNotificationStage(ctx),
      embedStage = ChatEmbedStage(ctx),
      draftStage = MemoryDraftStage(ctx),
      autoSummaryStage = AutoSummaryStage(ctx),
      imageTagStage = ImageTagStage(ctx),
      extBlocksStage = ExtBlocksStage(ctx),
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
    required String completedMessageId,
    String? regenTargetId,
  }) async {
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;
    if (result.session == null) return;

    final sessionId = result.session!.id;
    // The post agents this turn started with (Post Clean, Tracker, Card
    // Rewriter). Taken before the first await: the plan belongs to [genId].
    final agentPlan = ctx.ref
        .read(agentTurnRegistryProvider)
        .take(ctx.charId, genId);
    final engineConfig = agentPlan.postProcessing.isEmpty
        ? null
        : await ctx.ref
              .read(agentTurnServiceProvider)
              .engineConfigFor(agentPlan);
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;
    final enginesRun = engineConfig != null;
    // Reserve the memory session before the first await so another memory
    // workflow cannot claim the same auto-generation batch while scheduling.
    // With the engines running, memory drafts wait for the Tracker's clock and
    // reserve after it.
    final ordinaryMemoryLease = enginesRun
        ? null
        : draftStage.reserveAutoGeneration(result.session);

    // Sync + notification (immediate, awaited).
    try {
      await syncStage.run(
        result: result,
        genId: genId,
        character: character,
        notifService: notifService,
        completedMessageId: completedMessageId,
      );
    } catch (_) {
      ordinaryMemoryLease?.release();
      rethrow;
    }
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
      ordinaryMemoryLease?.release();
      return;
    }

    // Embedding starts from the committed response immediately.
    _runInBackground(
      () => embedStage.run(
        sessionId: sessionId,
        messages: result.session!.messages,
        genId: genId,
      ),
      'chat embedding',
      notifService,
    );
    // The summary reads the committed reply as it is.
    _runInBackground(
      () => autoSummaryStage.run(result.session),
      'auto-summary',
      notifService,
    );
    if (!enginesRun) {
      _runInBackground(
        () => draftStage.run(
          result.session,
          generationLease: ordinaryMemoryLease,
        ),
        'memory auto-draft',
        notifService,
        onTaskNotStarted: ordinaryMemoryLease?.release,
      );
    }

    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;

    if (enginesRun) {
      await _runEngines(
        result: result,
        sessionId: sessionId,
        genId: genId,
        character: character,
        service: service,
        notifService: notifService,
        engineConfig: engineConfig,
      );
      return;
    }

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
  }

  /// Post Clean / Tracker path. The cleaner runs first (the Tracker runs
  /// inside it, on the canonical text); memory drafts and image tags then read
  /// the reloaded session so they see the cleaned swipe and the Tracker clock.
  /// Keeps the foreground post-gen hold until all of it is done.
  Future<void> _runEngines({
    required ChatState result,
    required String sessionId,
    required int genId,
    required Character? character,
    required ChatGenerationService service,
    required GenerationNotificationService notifService,
    required PostGenEngineConfig engineConfig,
  }) async {
    if (!_beginForegroundPostGen(sessionId: sessionId, genId: genId)) return;
    final cleanerTask = cleanerStage.run(
      sessionId: sessionId,
      messages: result.session!.messages,
      genId: genId,
      promptPayload: result.promptPayload,
      mainModelContextSnapshot: result.mainModelContextSnapshot,
      character: character,
      engineConfig: engineConfig,
    );

    Future<ChatSession?> reload() async {
      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }
      final refreshed = await ctx.ref.read(chatRepoProvider).getById(sessionId);
      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }
      return refreshed;
    }

    await Future.wait([
      cleanerTask,
      cleanerTask.then((_) async {
        final refreshed = await reload();
        if (refreshed == null) return;
        final memoryLease = draftStage.reserveAutoGeneration(refreshed);
        _runInBackground(
          () => draftStage.run(refreshed, generationLease: memoryLease),
          'memory auto-draft',
          notifService,
          onTaskNotStarted: memoryLease?.release,
        );
      }),
      cleanerTask.then((_) async {
        final refreshed = await reload();
        if (refreshed == null) return;
        await imageTagStage.run(
          result: ChatState(session: refreshed),
          genId: genId,
          service: service,
        );
      }),
    ]);
  }
}
