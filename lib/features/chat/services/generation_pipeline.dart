import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/db/repositories/lorebook_use_manifest_repo.dart';
import '../../../core/llm/prompt/exact_lorebook_manifest.dart';
import '../../../core/llm/studio/studio_history_limiter.dart';
import '../../../core/llm/studio/studio_stream_interceptor.dart';
import '../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../core/services/generation_notification_service.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../../../core/state/studio_turn_config_resolver.dart';
import '../../chat_history/chat_history_provider.dart';
import '../abort_handler.dart';
import '../chat_generation_service.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';
import '../state/studio_history_rotation_provider.dart';
import 'stages/cleaner_stage.dart';
import 'stages/ext_blocks_stage.dart';
import 'stages/ledger_stage.dart';
import 'stages/post_gen_coordinator.dart';
import 'stages/regen_resolver.dart';
import 'stages/stage_context.dart';

// Re-export for backward compatibility (tracker_memory_recovery_service,
// test files).
export 'pipeline_utils.dart'
    show extractRecentHistoryText, selectStudioLedgerTextAfterCleaner;

/// Result of [GenerationPipeline.run] when the regen target's id did not
/// match what the service wrote back (e.g. a stale completion after a new
/// generation started, or an abort mid-pipeline).
class GenerationOutcome {
  /// Final state to apply to the [ChatNotifier] state. May already include
  /// the rolled-back session, depending on the path.
  final ChatState state;

  /// If non-null, the [AbortHandler] should keep its restoration snapshot
  /// for the next abort. If null, restoration has been consumed.
  final ChatMessage? clearRestorationMessage;

  const GenerationOutcome({required this.state, this.clearRestorationMessage});
}

/// Runs the post-SSE side of a chat generation:
///   1. persist the service result (success path)
///   2. handle regen rollback if the service's regenTargetId does not match
///   3. handle restoration rollback if `abortHandler.restorationMessage` is set
///   4. clear `restorationMessage` and chat image `imgGenCancelToken`
///   5. sync + notification (immediate)
///   6. post-cleaner (Studio ON: fact-checker + rewrite + ext blocks + ledger)
///   7. embed + auto-create drafts (parallel fire-and-forget)
///
/// This class is a thin orchestrator — no business logic, no state ownership.
/// Constructor-injected dependencies: the [Ref] (for repo/provider reads),
/// the [AbortHandler] (for genId + restoration tracking), and the [ChatState]
/// at the moment the run started.
class GenerationPipeline {
  final StageContext ctx;
  late final _regenResolver = RegenResolver(ctx);
  late final _postGenCoordinator = PostGenCoordinator(ctx);
  late final _cleanerStage = CleanerStage(
    ctx,
    extBlocks: ExtBlocksStage(ctx),
    ledger: LedgerStage(ctx),
  );

  GenerationPipeline({
    required Ref ref,
    required String charId,
    required AbortHandler abortHandler,
    required void Function(AsyncValue<ChatState>) setState,
    required AsyncValue<ChatState> Function() getState,
  }) : ctx = StageContext(
         ref: ref,
         charId: charId,
         abortHandler: abortHandler,
         setState: setState,
         getState: getState,
       );

  /// Run the full post-SSE pipeline. Returns the final [GenerationOutcome]
  /// describing the state to apply, or null if the genId was invalidated
  /// (caller should drop the result).
  Future<GenerationOutcome?> run({
    required int genId,
    required ChatSession session,
    required ChatSession? saveSession,
    required String? guidanceText,
    required List<String>? previousSwipes,
    int previousSwipeId = 0,
    String? previousReasoning,
    String? previousGenTime,
    int? previousTokens,
    List<Map<String, dynamic>>? previousSwipesMeta,
    String? regenTargetId,
  }) async {
    if (!ctx.ref.mounted) return null;
    ctx.abortHandler.clearStreaming();

    final notifService = GenerationNotificationService.instance;
    GenerationForegroundLease? notificationLease;

    try {
      notificationLease = await notifService.acquireGenerationLease('Glaze');
      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }
      final studioTurnConfig = await ctx.ref
          .read(studioTurnConfigResolverProvider)
          .resolve(session.id);
      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }
      final charRepo = ctx.ref.read(characterRepoProvider);
      final character = await charRepo.getById(ctx.charId);
      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }
      final service = ctx.ref.read(chatGenerationServiceProvider);
      var result = await service.generate(
        session: session,
        saveSession: saveSession,
        charId: ctx.charId,
        genId: genId,
        currentState: ctx.getState().value ?? ChatState(session: session),
        onStateUpdate: (s) {
          if (ctx.abortHandler.isCurrentGen(genId)) ctx.setState(AsyncData(s));
        },
        isAborted: () => !ctx.abortHandler.isCurrentGen(genId),
        previousSwipes: previousSwipes,
        previousSwipeId: previousSwipeId,
        previousReasoning: previousReasoning,
        previousGenTime: previousGenTime,
        previousTokens: previousTokens,
        previousSwipesMeta: previousSwipesMeta,
        guidanceText: guidanceText,
        regenTargetId: regenTargetId,
        studioTurnConfig: studioTurnConfig,
      );

      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }

      if (result.session == null) {
        await _handlePipelineError(
          StateError('Generation completed without a chat session'),
          genId,
        );
        return null;
      }

      final durableSession = await _commitGenerationResult(
        baseSession: saveSession ?? session,
        generatedSession: result.session!,
        regenTargetId: regenTargetId,
        manifest:
            result.mainModelContextSnapshot?.promptResult.exactLorebookManifest,
        studioTurnConfig: studioTurnConfig,
      );
      if (durableSession == null) {
        return null;
      }
      result = result.copyWith(session: durableSession);
      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }
      ChatSessionService.updateCache(durableSession);
      ctx.ref.invalidate(chatHistoryProvider);

      final generationErrored =
          regenTargetId == null &&
          result.session!.messages.lastOrNull?.isError == true;
      if (generationErrored) {
        ctx.abortHandler.clearStreaming();
        ctx.abortHandler.restorationMessage = null;
        final settled = result.copyWith(
          isGenerating: false,
          isPostGenRunning: false,
        );
        ctx.setState(AsyncData(settled));
        return GenerationOutcome(state: settled, clearRestorationMessage: null);
      }

      // Regen vs normal-result dispatch.
      final regenMsg = regenTargetId != null && result.session != null
          ? result.session!.messages
                .where((m) => m.id == regenTargetId)
                .firstOrNull
          : null;
      final regenSucceeded =
          regenTargetId != null &&
          regenMsg != null &&
          !regenMsg.isError &&
          !regenMsg.isTyping;
      final regenOutcome = await _regenResolver.resolve(
        result: result,
        regenTargetId: regenTargetId,
        saveSession: saveSession,
        session: session,
        genId: genId,
      );
      if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
        return null;
      }
      if (regenOutcome != null) {
        // INV-EG1: extensions + image tags must run after successful regen too.
        if (regenSucceeded && result.session != null) {
          // The stream has ended. The coordinator acquires
          // isPostGenRunning only if it finds a foreground post-gen task.
          ctx.setState(
            AsyncData(
              result.copyWith(isGenerating: false, regenTargetId: null),
            ),
          );
          await _postGenCoordinator.run(
            result: result.copyWith(isGenerating: false, regenTargetId: null),
            genId: genId,
            character: character,
            service: service,
            notifService: notifService,
            regenTargetId: regenTargetId,
            studioTurnConfig: studioTurnConfig,
          );
          // Post-gen finished — clear isPostGenRunning (unless a newer
          // generation has taken over, in which case leave its state
          // untouched).
          if (ctx.ref.mounted && ctx.abortHandler.isCurrentGen(genId)) {
            final after = ctx.getState().value;
            if (after != null && after.isPostGenRunning) {
              ctx.setState(AsyncData(after.copyWith(isPostGenRunning: false)));
            }
          }
        } else {
          // The owning pipeline releases its foreground lease in finally.
        }
        return regenOutcome;
      }

      // Normal path: regen not requested. Handle restoration snapshot if set.
      if (regenTargetId == null &&
          result.session?.messages.length == session.messages.length &&
          ctx.abortHandler.restorationMessage != null) {
        final restoration = ctx.abortHandler.restorationMessage!;
        var restoredSession = await ctx.ref
            .read(chatRepoProvider)
            .mutateSession(
              sessionId: session.id,
              updatedAt: currentTimestampSeconds(),
              mutate: (latest) {
                if (!ctx.abortHandler.isCurrentGen(genId)) return null;
                return _restoreAfterError(
                  latest: latest,
                  expected: session,
                  restoration: restoration,
                  regenTargetId: null,
                );
              },
            );
        restoredSession ??= await ctx.ref
            .read(chatRepoProvider)
            .getById(session.id);
        if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) {
          return null;
        }
        if (restoredSession == null) {
          return null;
        }
        ChatSessionService.updateCache(restoredSession);
        ctx.ref.invalidate(chatHistoryProvider);
        ctx.abortHandler.restorationMessage = null;
        ctx.setState(
          AsyncData(
            ChatState(
              session: restoredSession,
              isGenerating: true,
              error: result.error,
            ),
          ),
        );
      } else {
        // Streaming window still active — keep isGenerating true so the
        // streaming overlay stays visible until clearStreaming() runs
        // below. isPostGenRunning is set in the next setState (before the
        // coordinator starts).
        ctx.setState(AsyncData(result.copyWith(isGenerating: true)));
        ctx.abortHandler.restorationMessage = null;
      }
      ctx.abortHandler.clearStreaming();

      // The text stream is complete. PostGenCoordinator acquires the
      // foreground post-gen flag only for real foreground work.
      if (ctx.ref.mounted) {
        final pre = ctx.getState().value;
        if (pre != null && pre.session?.id == result.session?.id) {
          ctx.setState(AsyncData(pre.copyWith(isGenerating: false)));
        }
      }

      // Post-generation tasks: sync + notification, then (in order)
      // cleaner → image tags, with embed + auto-drafts in parallel. See
      // PLAN_STUDIO_PIPELINE_SEPARATION.md §New Pipeline Order.
      await _postGenCoordinator.run(
        result: result,
        genId: genId,
        character: character,
        service: service,
        notifService: notifService,
        regenTargetId: regenTargetId,
        studioTurnConfig: studioTurnConfig,
      );
      // Post-gen finished — clear isPostGenRunning (unless a newer
      // generation has taken over, in which case leave its state
      // untouched).
      if (ctx.ref.mounted && ctx.abortHandler.isCurrentGen(genId)) {
        final after = ctx.getState().value;
        if (after != null && after.isPostGenRunning) {
          ctx.setState(AsyncData(after.copyWith(isPostGenRunning: false)));
        }
      }

      return GenerationOutcome(
        state: ctx.getState().value ?? result,
        clearRestorationMessage: null,
      );
    } catch (e) {
      await _handlePipelineError(e, genId);
      return null;
    } finally {
      await notificationLease?.release();
    }
  }

  Future<ChatSession?> _commitGenerationResult({
    required ChatSession baseSession,
    required ChatSession generatedSession,
    required String? regenTargetId,
    required ExactLorebookManifest? manifest,
    required StudioTurnConfigSnapshot studioTurnConfig,
  }) async {
    final durableManifest = validateGenerationManifestForCommit(manifest);
    var sessionToCommit = generatedSession;
    StudioHistoryWindowPlan? rotation;
    if (regenTargetId == null &&
        studioTurnConfig.enabled &&
        generatedSession.messages.lastOrNull?.isError != true) {
      final settings = studioTurnConfig.pipelineSettings.studioAgent;
      final finalContextSize = settings.studioFinalContextSize > 0
          ? settings.studioFinalContextSize
          : studioTurnConfig.preset!.maxFinalHistoryMessages;
      rotation = StudioStreamInterceptor.planCompletedHistoryWindow(
        generatedSession.messages,
        finalContextSize: finalContextSize,
        historyWindowStartMessageId:
            baseSession.sessionVars[StudioHistoryLimiter.historyWindowStartVar],
        reasoningHistoryCount: settings.studioFinalReasoningHistoryCount,
        excludeReasoningFromContextBudget:
            settings.studioFinalExcludeReasoningFromContextBudget,
      );
      final startId = rotation.startMessageId;
      if (rotation.didRotate && startId != null) {
        sessionToCommit = generatedSession.copyWith(
          sessionVars: {
            ...generatedSession.sessionVars,
            StudioHistoryLimiter.historyWindowStartVar: startId,
          },
        );
      }
    }
    var wakeLoreEmbeddingWorker = false;
    final chatRepo = ctx.ref.read(chatRepoProvider);
    Future<ChatSession?> commit(ExactLorebookManifest? manifest) =>
        chatRepo.commitGenerationResult(
          baseSession: baseSession,
          generatedSession: sessionToCommit,
          regenTargetId: regenTargetId,
          manifest: manifest,
          beforeWrite: (_, after) async {
            final canonRollback = await ctx.ref
                .read(sessionCanonRollbackRepoProvider)
                .reconcileInTransaction(
                  sessionId: after.id,
                  survivingMessages: after.messages,
                );
            wakeLoreEmbeddingWorker =
                canonRollback.shouldWakeLoreEmbeddingWorker;
          },
        );
    final committed = await commitGenerationWithManifestFallback(
      manifest: durableManifest,
      commit: commit,
      onManifestFailure: () => wakeLoreEmbeddingWorker = false,
    );
    if (committed == null) {
      debugPrint(
        '[GenerationPipeline] generation commit rejected by stale anchor '
        'session=${generatedSession.id} regenTarget=$regenTargetId',
      );
    }
    if (wakeLoreEmbeddingWorker) {
      unawaited(ctx.ref.read(sessionLorebookEmbeddingWorkerProvider).drain());
    }
    if (committed != null && rotation?.didRotate == true && ctx.ref.mounted) {
      ctx.ref
          .read(studioHistoryRotationProvider(ctx.charId).notifier)
          .state = StudioHistoryRotationNotice(
        sessionId: committed.id,
        droppedMessageCount: rotation!.droppedMessageCount,
      );
    }
    return committed;
  }

  static bool _sameGenerationAnchor(ChatMessage expected, ChatMessage current) {
    return expected.content == current.content &&
        expected.swipeId == current.swipeId &&
        expected.agentSwipeId == current.agentSwipeId &&
        jsonEncode(expected.swipes) == jsonEncode(current.swipes) &&
        jsonEncode(expected.swipesMeta) == jsonEncode(current.swipesMeta) &&
        jsonEncode(
              expected.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            ) ==
            jsonEncode(
              current.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            );
  }

  /// Re-run the POST-cleaner against an existing assistant message.
  /// Delegates to [CleanerStage.rerun].
  Future<void> rerunCleaner({
    required String sessionId,
    required String messageId,
  }) async {
    await _cleanerStage.rerun(sessionId: sessionId, messageId: messageId);
  }

  Future<void> _handlePipelineError(Object e, int genId) async {
    if (!ctx.ref.mounted) return;
    if (!ctx.abortHandler.isCurrentGen(genId)) return;
    final current = ctx.getState().value;
    if (current != null && (current.isGenerating || current.isPostGenRunning)) {
      final restoration = ctx.abortHandler.restorationMessage;
      if (restoration != null) {
        final session = current.session;
        ChatSession? durableSession;
        Object? persistenceError;
        if (session != null) {
          try {
            durableSession = await ctx.ref
                .read(chatRepoProvider)
                .mutateSession(
                  sessionId: session.id,
                  updatedAt: currentTimestampSeconds(),
                  mutate: (latest) {
                    if (!ctx.abortHandler.isCurrentGen(genId)) return null;
                    return _restoreAfterError(
                      latest: latest,
                      expected: session,
                      restoration: restoration,
                      regenTargetId: current.regenTargetId,
                    );
                  },
                );
            durableSession ??= await ctx.ref
                .read(chatRepoProvider)
                .getById(session.id);
          } catch (err) {
            persistenceError = err;
            debugPrint('[GenerationPipeline] failed to persist restored: $err');
            try {
              durableSession = await ctx.ref
                  .read(chatRepoProvider)
                  .getById(session.id);
            } catch (reloadError) {
              debugPrint(
                '[GenerationPipeline] failed to reload current session: '
                '$reloadError',
              );
            }
          }
        }
        if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return;
        if (durableSession != null) {
          ChatSessionService.updateCache(durableSession);
          ctx.ref.invalidate(chatHistoryProvider);
        }
        ctx.setState(
          AsyncData(
            current.copyWith(
              session: durableSession ?? current.session,
              isGenerating: false,
              isPostGenRunning: false,
              error: persistenceError == null
                  ? e.toString()
                  : '$e\nFailed to restore the previous response: '
                        '$persistenceError',
            ),
          ),
        );
      } else {
        ctx.setState(
          AsyncData(
            current.copyWith(
              isGenerating: false,
              isPostGenRunning: false,
              error: e.toString(),
            ),
          ),
        );
      }
      ctx.abortHandler.restorationMessage = null;
    }
  }

  static ChatSession? _restoreAfterError({
    required ChatSession latest,
    required ChatSession expected,
    required ChatMessage restoration,
    required String? regenTargetId,
  }) {
    if (regenTargetId != null) {
      final expectedIndex = expected.messages.indexWhere(
        (message) => message.id == regenTargetId,
      );
      final latestIndex = latest.messages.indexWhere(
        (message) => message.id == regenTargetId,
      );
      if (latestIndex < 0) return null;
      final current = latest.messages[latestIndex];
      if (_sameGenerationAnchor(restoration, current)) return latest;
      if (expectedIndex < 0 ||
          !_sameGenerationAnchor(expected.messages[expectedIndex], current)) {
        return null;
      }
      final messages = [...latest.messages];
      messages[latestIndex] = restoration.copyWith(
        isHidden: current.isHidden,
        imageHidden: current.imageHidden,
      );
      return latest.copyWith(messages: messages);
    }

    if (latest.messages.any((message) => message.id == restoration.id)) {
      return latest;
    }
    if (latest.messages.lastOrNull?.id != expected.messages.lastOrNull?.id) {
      return null;
    }
    return latest.copyWith(messages: [...latest.messages, restoration]);
  }
}

@visibleForTesting
ExactLorebookManifest? validateGenerationManifestForCommit(
  ExactLorebookManifest? manifest,
) {
  if (manifest == null) return null;
  try {
    return ExactLorebookManifest.decodeDurable(manifest.toJson());
  } catch (error, stackTrace) {
    // Lorebook provenance is auxiliary. A malformed manifest must not roll
    // back an otherwise valid generated message or regenerated swipe.
    debugPrint(
      '[GenerationPipeline] discarding invalid lorebook manifest: '
      '$error\n$stackTrace',
    );
    return null;
  }
}

@visibleForTesting
Future<T?> commitGenerationWithManifestFallback<T>({
  required ExactLorebookManifest? manifest,
  required Future<T?> Function(ExactLorebookManifest? manifest) commit,
  void Function()? onManifestFailure,
}) async {
  try {
    return await commit(manifest);
  } on LorebookUseManifestIntegrityConflict catch (error, stackTrace) {
    // Provenance is auxiliary to the generated message. Preserve the strict
    // manifest transaction, then retry the same guarded message commit
    // without provenance so a malformed/conflicting manifest cannot eat a
    // completed response or regenerated swipe.
    debugPrint(
      '[GenerationPipeline] lorebook manifest commit failed; preserving '
      'generated message without provenance: $error\n$stackTrace',
    );
    onManifestFailure?.call();
    return commit(null);
  }
}
