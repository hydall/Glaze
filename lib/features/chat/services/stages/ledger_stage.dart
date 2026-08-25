import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/aux_llm_client.dart' show AuxApiConfig;
import '../../../../core/llm/game_time.dart';
import '../../../../core/llm/macro_engine.dart';
import '../../../../core/llm/studio_ledger_service.dart';
import '../../../../core/llm/studio_ledger_reconciliation.dart';
import '../../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../../core/models/agent_operation_record.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/pipeline_settings.dart';
import '../../../../core/models/studio_config.dart';
import '../../../../core/navigation/rewrite_review_navigation.dart';
import '../../../../core/services/card_rewriter/automated_card_evolution_service.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/memory_agent_providers.dart';
import '../../../../core/state/character_provider.dart';
import '../../../../core/state/card_rewriter_providers.dart';
import '../../../../core/state/persona_resolution.dart';
import '../../../../core/state/studio_turn_config_resolver.dart';
import '../../../../core/utils/time_helpers.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../chat_session_service.dart';
import '../../../card_rewrite/card_rewriter_recovery_view_service.dart';
import '../../state/agent_operations_log_provider.dart';
import '../../state/post_gen_status_provider.dart';
import '../collector_view_service.dart';
import '../current_ledger_injection_preview_service.dart';
import '../pipeline_utils.dart';
import '../prompt_capture_view_service.dart';
import '../reconciler_view_service.dart';
import 'stage_context.dart';

/// Stage 7: Studio Ledger trigger.
///
/// Fire-and-forget — does not block generation or user interaction.
/// Extracts entity/relationship/arc/world state from the final assistant
/// response and persists it to tracker_rows via [StudioLedgerService].
/// Only runs when Studio is enabled.
class LedgerStage {
  final StageContext ctx;

  LedgerStage(this.ctx);

  /// [finalAssistantText] — the text the ledger should analyse. When the
  /// POST-cleaner is enabled, this is the cleaned text (plan §Pipeline
  /// Placement: «Ledger must not run on pre-cleaner text»). When the cleaner
  /// is disabled this is the raw streamed assistant text.
  ///
  /// [targetMessage] — the assistant message the text belongs to. Used for
  /// provenance coordinates (messageId, swipeId, agentSwipeId).
  ///
  /// [messages] — full session message list for recent-history context.
  ///
  /// Staleness guard: checks [AbortHandler.isCurrentGen] before writing (after
  /// the LLM returns). The service itself never throws — errors land in
  /// [LedgerRunResult.status].
  Future<void> run({
    required String sessionId,
    required List<ChatMessage> messages,
    required int genId,
    required String finalAssistantText,
    required ChatMessage targetMessage,
    bool isManualRerun = false,
    CancelToken? cancelToken,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    if (!ctx.ref.mounted) return;

    PostGenStatusState? ownedRunningStatus;
    void startStatus(PostGenTask task) {
      if (!ctx.ref.mounted) return;
      final status = PostGenStatusState.running(
        sessionId: sessionId,
        task: task,
      );
      ownedRunningStatus = status;
      ctx.ref.read(postGenStatusProvider.notifier).state = status;
    }

    bool ownsRunningStatus() {
      if (!ctx.ref.mounted || ownedRunningStatus == null) return false;
      final current = ctx.ref.read(postGenStatusProvider);
      // Prefer identical-object check to prevent older runs overwriting newer
      // ones. Fall back to logical check (same session+task+running phase) so
      // a state replacement by Riverpod internals or an auto-dismiss timer
      // does not strand the status at "running" forever.
      return current.sessionId == sessionId &&
          current.task == ownedRunningStatus!.task &&
          current.phase == PostGenTaskPhase.running;
    }

    void finishOwnedStatus(PostGenStatusState status) {
      if (!ownsRunningStatus() || status.sessionId != sessionId) return;
      ctx.ref.read(postGenStatusProvider.notifier).state = status;
      ownedRunningStatus = null;
    }

    void clearOwnedStatus() {
      if (!ownsRunningStatus()) return;
      ctx.ref.read(postGenStatusProvider.notifier).state =
          const PostGenStatusState.idle();
      ownedRunningStatus = null;
    }

    final isCurrent = isManualRerun
        ? () => ctx.ref.mounted
        : () => ctx.ref.mounted && ctx.abortHandler.isCurrentGen(genId);

    try {
      final turnConfig =
          studioTurnConfig ??
          await ctx.ref
              .read(studioTurnConfigResolverProvider)
              .resolve(sessionId);
      final pipeline = turnConfig.pipelineSettings;

      final studioConfigEnabled = turnConfig.enabled;
      final studioPreset = turnConfig.preset;
      if (!studioConfigEnabled) {
        await _recordDiag(
          sessionId: sessionId,
          targetMessage: targetMessage,
          reason: 'skipped, studio disabled',
        );
        return;
      }
      if (!turnConfig.ledgerEnabled) {
        await _recordDiag(
          sessionId: sessionId,
          targetMessage: targetMessage,
          reason: 'skipped, ledger disabled in active Studio preset',
        );
        return;
      }

      // Cadence only gates standalone Ledger outside Studio.
      final assistantTurnCount = messages
          .where((m) => m.role == 'assistant' && !m.isTyping)
          .length;
      final cadenceReason = studioConfigEnabled
          ? null
          : _resolveCadence(pipeline, assistantTurnCount, finalAssistantText);
      if (cadenceReason != null) {
        await _recordDiag(
          sessionId: sessionId,
          targetMessage: targetMessage,
          reason: cadenceReason,
        );
        return;
      }

      if (finalAssistantText.trim().isEmpty) {
        await _recordDiag(
          sessionId: sessionId,
          targetMessage: targetMessage,
          reason: 'skipped, empty assistant text',
        );
        return;
      }
      if (!isCurrent()) {
        await _recordDiag(
          sessionId: sessionId,
          targetMessage: targetMessage,
          reason: 'skipped, stale generation',
        );
        return;
      }

      // Always resolve the dedicated Ledger slot from the immutable turn
      // snapshot. A cleaner config must never override an explicit Ledger slot.
      final AuxApiConfig ledgerConfig;
      try {
        ledgerConfig = turnConfig.resolveLedgerConfig(
          errorLabel: 'studio-ledger',
        );
      } catch (e) {
        debugPrint('[StudioLedger] slot resolution failed: $e');
        await _recordDiag(
          sessionId: sessionId,
          targetMessage: targetMessage,
          reason: 'skipped, slot resolution failed: $e',
        );
        return;
      }

      final recentHistory = extractRecentHistoryText(messages, maxMessages: 10);

      final service = ctx.ref.read(studioLedgerServiceProvider);

      // Build MacroContext for resolving preset-block macros.
      final character = ctx.ref.read(characterByIdProvider(ctx.charId));
      final persona = ctx.ref.read(
        effectivePersonaForChatProvider((
          charId: ctx.charId,
          sessionId: sessionId,
        )),
      );
      final focalUserName = persona?.name.trim().isNotEmpty == true
          ? persona!.name
          : _personaName(messages);
      final ledgerMacroCtx = MacroContext(
        charName: character?.name ?? '',
        charDescription: character?.description,
        charScenario: character?.scenario,
        charPersonality: character?.personality,
        charMesExample: character?.mesExample,
        userName: focalUserName,
        macroName: character?.macroName,
        charId: ctx.charId,
        sessionId: sessionId,
      );

      LedgerRunResult? reconciliationResult;
      if (shouldRunAutomaticLedgerReconciliation(
        ledgerEnabled: turnConfig.ledgerEnabled,
        isManualRerun: isManualRerun,
      )) {
        final checkpointRepo = ctx.ref.read(
          ledgerReconciliationCheckpointRepoProvider,
        );
        final checkpoint = await checkpointRepo.get(sessionId);
        final reconciliationRunRepo = ctx.ref.read(
          ledgerReconciliationRunRepoProvider,
        );
        final previousRunHead = await reconciliationRunRepo.getHead(sessionId);
        final plan = const LedgerReconciliationPlanner().plan(
          messages: messages,
          currentAssistantMessageId: targetMessage.id,
          checkpoint: checkpoint,
          previousEndMessageId: previousRunHead?.endMessageId,
        );
        if (plan != null && isCurrent()) {
          await _recordReconciliationDiag(
            sessionId: sessionId,
            targetMessage: targetMessage,
            startMessageId: plan.startMessageId,
            endMessageId: plan.endMessage.id,
            result: LedgerRunResult(
              status: 'running',
              model: ledgerConfig.model,
            ),
          );
          startStatus(PostGenTask.ledgerReconciliation);
          reconciliationResult = await service.reconcile(
            sessionId: sessionId,
            settings: pipeline,
            config: ledgerConfig,
            plan: plan,
            ledgerBlocks: studioPreset?.blocks ?? const [],
            macroCtx: ledgerMacroCtx,
            isStillCurrent: isCurrent,
            cancelToken: cancelToken,
            operationIdentity: 'automatic:$genId',
          );
          await _recordReconciliationDiag(
            sessionId: sessionId,
            targetMessage: targetMessage,
            startMessageId: plan.startMessageId,
            endMessageId: plan.endMessage.id,
            result: reconciliationResult,
          );
          _recordOperation(
            sessionId: sessionId,
            targetMessage: targetMessage,
            result: reconciliationResult,
            kind: AgentOperationKind.studioLedgerReconciliation,
            idPrefix: 'studio-ledger-reconciliation',
            successSummary:
                'range=${plan.startMessageId}..${plan.endMessage.id}, '
                'ops=${reconciliationResult.opsApplied}',
            canRegenerate: false,
          );
          if (ctx.ref.mounted) {
            final detail =
                'Ledger reconciliation ${reconciliationResult.status} '
                '(ops=${reconciliationResult.opsApplied})';
            if (reconciliationResult.status == 'aborted') {
              clearOwnedStatus();
            } else {
              finishOwnedStatus(
                reconciliationResult.status == 'ok'
                    ? PostGenStatusState.done(
                        sessionId: sessionId,
                        task: PostGenTask.ledgerReconciliation,
                        detail: detail,
                      )
                    : PostGenStatusState.error(
                        sessionId: sessionId,
                        task: PostGenTask.ledgerReconciliation,
                        detail: detail,
                      ),
              );
            }
          }
          debugPrint(
            '[StudioLedger] reconciliation session=$sessionId '
            'range=${plan.startMessageId}..${plan.endMessage.id} '
            'status=${reconciliationResult.status} '
            'ops=${reconciliationResult.opsApplied} '
            'error=${reconciliationResult.error ?? "none"}',
          );
          if (reconciliationResult.status == 'ok' &&
              pipeline.cardRewriter.enabled &&
              isCurrent()) {
            final runHead = await reconciliationRunRepo.getHead(sessionId);
            if (runHead != null && isCurrent()) {
              final rewriteReviewAuthority =
                  captureAutomaticRewriteReviewAuthority(
                    charId: ctx.charId,
                    sessionId: sessionId,
                  );
              final rewriteOutcome = await ctx.ref
                  .read(automatedCardEvolutionServiceProvider)
                  .runAfterReconciliation(
                    runHead,
                    onStage: (stage) {
                      if (!ctx.ref.mounted || !isCurrent()) return;
                      startStatus(
                        stage == AutomatedCardEvolutionStage.observation
                            ? PostGenTask.cardEvolutionObservation
                            : PostGenTask.cardRewriter,
                      );
                    },
                  );
              debugPrint(
                '[StudioLedger] card rewriter session=$sessionId '
                'kind=${rewriteOutcome.kind} '
                'detail=${rewriteOutcome.detail ?? '-'}',
              );
              emitAutomaticRewriteReviewIntent(
                ctx.ref,
                outcome: rewriteOutcome,
                capturedAuthority: rewriteReviewAuthority,
              );
              if (ctx.ref.mounted && isCurrent()) {
                final isFailure = const {
                  'modelNotConfigured',
                  'cardModelFailed',
                  'lorebookModelFailed',
                  'invalidCardOutput',
                  'invalidLorebookOutput',
                  'snapshotUnavailable',
                  'snapshotTooLarge',
                  'staleEvidence',
                  'canonUnavailable',
                  'fieldMismatch',
                  'unexpectedFailure',
                  'failed',
                }.contains(rewriteOutcome.kind);
                final detail = rewriteOutcome.kind == 'persisted'
                    ? 'Card Rewriter created a review proposal'
                    : rewriteOutcome.kind == 'emptyModelProposal'
                    ? 'Card Rewriter found no durable card changes'
                    : 'Card Rewriter: ${rewriteOutcome.kind}'
                          '${rewriteOutcome.detail == null ? '' : ' — ${rewriteOutcome.detail}'}';
                finishOwnedStatus(
                  isFailure
                      ? PostGenStatusState.error(
                          sessionId: sessionId,
                          task: PostGenTask.cardRewriter,
                          detail: detail,
                        )
                      : PostGenStatusState.done(
                          sessionId: sessionId,
                          task: PostGenTask.cardRewriter,
                          detail: detail,
                        ),
                );
              }
              if (!isCurrent()) return;
            }
          }
          if (!isCurrent()) return;
        }
      }

      startStatus(PostGenTask.ledger);

      final result = await service.run(
        sessionId: sessionId,
        settings: pipeline,
        config: ledgerConfig,
        finalAssistantText: finalAssistantText,
        recentHistoryText: recentHistory,
        messageId: targetMessage.id,
        swipeId: targetMessage.swipeId,
        agentSwipeId: targetMessage.agentSwipeId,
        forceEnabled: true,
        isStillCurrent: isCurrent,
        cancelToken: cancelToken,
        ledgerBlocks: studioPreset?.blocks ?? const [],
        macroCtx: ledgerMacroCtx,
        engine: StudioLedgerEngine.currentReconciled,
        operationIdentity: 'automatic:$genId',
      );

      await _recordDiag(
        sessionId: sessionId,
        targetMessage: targetMessage,
        reason:
            '${reconciliationResult == null ? '' : 'reconcile=${reconciliationResult.status} '
                      '(ops=${reconciliationResult.opsApplied}); '}'
            'ran, ${result.status} '
            '(ops=${result.opsApplied})'
            '${result.error == null ? '' : ': ${result.error}'}',
      );

      _recordOperation(
        sessionId: sessionId,
        targetMessage: targetMessage,
        result: result,
      );

      if (ctx.ref.mounted) {
        final detail = 'Ledger ${result.status} (ops=${result.opsApplied})';
        if (result.status == 'aborted') {
          clearOwnedStatus();
        } else {
          finishOwnedStatus(
            result.status == 'ok'
                ? PostGenStatusState.done(
                    sessionId: sessionId,
                    task: PostGenTask.ledger,
                    detail: detail,
                  )
                : PostGenStatusState.error(
                    sessionId: sessionId,
                    task: PostGenTask.ledger,
                    detail: detail,
                  ),
          );
        }
      }

      if (ledgerStatusToOp(result.status).isFailure) {
        GlazeToast.showWithoutContext(
          'Studio Ledger failed. Open Agentic Ops -> Last turn to inspect or rerun.',
          duration: 5000,
          position: ToastPosition.top,
          isError: true,
        );
      } else if (result.status == 'ok' && result.opsApplied > 0) {
        GlazeToast.showWithoutContext(
          'Studio Ledger ok (ops=${result.opsApplied})',
          duration: 3500,
          position: ToastPosition.top,
        );
      }

      debugPrint(
        '[StudioLedger] result session=$sessionId status=${result.status} '
        'opsApplied=${result.opsApplied} '
        'elapsedMs=${result.elapsedMs} '
        'error=${result.error ?? "none"}',
      );

      await _syncGameTimeToMessage(
        sessionId: sessionId,
        targetMessage: targetMessage,
        isCurrent: isCurrent,
      );
    } catch (e) {
      debugPrint(
        '[StudioLedger] pipeline trigger failed session=$sessionId: $e',
      );
      await _recordDiag(
        sessionId: sessionId,
        targetMessage: targetMessage,
        reason: 'skipped, trigger error: $e',
      );
      _recordOperation(
        sessionId: sessionId,
        targetMessage: targetMessage,
        result: LedgerRunResult(status: 'error', error: 'trigger error: $e'),
      );
      if (ownedRunningStatus != null) {
        finishOwnedStatus(
          PostGenStatusState.error(
            sessionId: sessionId,
            task: ownedRunningStatus!.task,
            detail: 'Studio Ledger stopped: $e',
          ),
        );
      }
      GlazeToast.showWithoutContext(
        'Studio Ledger failed. Open Agentic Ops -> Last turn to inspect or rerun.',
        duration: 5000,
        position: ToastPosition.top,
        isError: true,
      );
    } finally {
      _invalidateAgentOpsViews(sessionId);
      // Covers cancellation and exceptions in catch-side diagnostics. Identity
      // plus session/task checks ensure an older run cannot clear a newer one.
      if (ownedRunningStatus != null && ownsRunningStatus()) {
        finishOwnedStatus(
          PostGenStatusState.error(
            sessionId: sessionId,
            task: ownedRunningStatus!.task,
            detail: 'Studio Ledger stopped before completion',
          ),
        );
      }
    }
  }

  void _invalidateAgentOpsViews(String sessionId) {
    if (!ctx.ref.mounted) return;
    ctx.ref.invalidate(reconcilerViewProvider(sessionId));
    ctx.ref.invalidate(
      currentLedgerInjectionPreviewProvider((
        sessionId: sessionId,
        characterId: ctx.charId,
      )),
    );
    ctx.ref.invalidate(collectorViewProvider(sessionId));
    ctx.ref.invalidate(promptCaptureViewsProvider(sessionId));
    ctx.ref.invalidate(cardRewriteDebugRunsProvider(sessionId));
    ctx.ref.invalidate(cardRewriterRecoveryViewsProvider(sessionId));
  }

  /// Best-effort: stamps the current ledger game clock (world:time/date/day)
  /// onto the assistant message as a display-only field. The value is never
  /// injected into the main prompt — the clock reaches the model through the
  /// ledger state block — but auxiliary systems (memory/summary history) read
  /// it so their outputs stay time-anchored.
  Future<void> _syncGameTimeToMessage({
    required String sessionId,
    required ChatMessage targetMessage,
    required bool Function() isCurrent,
  }) async {
    try {
      final trackers = await ctx.ref
          .read(trackerRepoProvider)
          .getBySessionAndScope(sessionId, 'ledger');
      final display = GameTimeState.fromTrackers(trackers).format();
      if (display == null || display == targetMessage.time) return;
      if (!isCurrent()) return;

      final updated = await ctx.ref
          .read(chatRepoProvider)
          .mutateMessage(
            sessionId: sessionId,
            messageId: targetMessage.id,
            updatedAt: currentTimestampSeconds(),
            mutate: (message) => message.copyWith(time: display),
          );
      if (updated == null) return;
      ChatSessionService.updateCache(updated);
      final liveState = ctx.getState().value;
      if (liveState == null || liveState.session?.id != updated.id) return;
      ctx.setState(AsyncData(liveState.copyWith(session: updated)));
    } catch (e) {
      debugPrint('[StudioLedger] game time sync failed session=$sessionId: $e');
    }
  }

  String _personaName(Iterable<ChatMessage> messages) {
    for (final message in messages.toList().reversed) {
      final name = message.personaName?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return 'User';
  }

  /// Returns a non-null skip reason when the cadence should suppress the
  /// ledger run, or null when the run should proceed. Applies the
  /// per-component run mode, interval, and conditional flags (plan §Model
  /// Cadence). The Studio forces the ledger on, but the user can opt into
  /// a lower-power cadence.
  String? _resolveCadence(
    PipelineSettings pipeline,
    int assistantTurnCount,
    String finalAssistantText,
  ) {
    switch (pipeline.ledger.studioLedgerRunMode) {
      case 'disabled':
        return 'skipped, runMode=disabled';
      case 'manual':
        return 'skipped, runMode=manual';
      case 'every_n':
        final n = pipeline.ledger.studioLedgerIntervalN < 1
            ? 1
            : pipeline.ledger.studioLedgerIntervalN;
        if (n > 1 && assistantTurnCount % n != 0) {
          return 'skipped, runMode=every_n interval=$n turn=$assistantTurnCount';
        }
        return null;
      case 'conditional':
        final reasons = <String>[];
        if (pipeline.ledger.studioLedgerRunWhenMentionedEntitiesChanged &&
            !finalAssistantText.trim().isNotEmpty) {
          reasons.add('no entities changed');
        }
        if (reasons.isNotEmpty) {
          return 'skipped, conditional: ${reasons.join(', ')}';
        }
        return null;
      case 'every_turn':
      default:
        return null;
    }
  }

  /// Stores the last run/skip reason for the Studio Ledger as a
  /// `_ledger_diag:<component>` tracker row so the diagnostics sheet can
  /// show it (plan §Model Cadence: "Diagnostics should show why a component
  /// ran or skipped"). The key is the message id, so the latest run
  /// overwrites prior rows.
  Future<void> _recordDiag({
    required String sessionId,
    required ChatMessage targetMessage,
    required String reason,
  }) async {
    if (!ctx.ref.mounted) return;
    try {
      final repo = ctx.ref.read(trackerRepoProvider);
      await repo.upsertValue(
        sessionId,
        '_ledger_diag:studio_ledger',
        'turn=${targetMessage.id} • $reason',
        scope: 'ledger_diagnostic',
        provenance:
            'message=${targetMessage.id}|swipe=${targetMessage.swipeId}|'
            'agentSwipe=${targetMessage.agentSwipeId}',
      );
    } catch (_) {}
  }

  Future<void> _recordReconciliationDiag({
    required String sessionId,
    required ChatMessage targetMessage,
    required String startMessageId,
    required String endMessageId,
    required LedgerRunResult result,
  }) async {
    if (!ctx.ref.mounted) return;
    final attempts = result.attempts.isEmpty
        ? 'none'
        : result.attempts
              .map(
                (attempt) =>
                    '${attempt.attempt}:${attempt.status}'
                    '/http=${attempt.statusCode}'
                    '/ms=${attempt.elapsedMs}'
                    '${attempt.error == null ? '' : '/error=${attempt.error}'}',
              )
              .join(',');
    final value =
        'trigger=${targetMessage.id} • range=$startMessageId..$endMessageId '
        '• status=${result.status} • ops=${result.opsApplied} '
        '• elapsedMs=${result.elapsedMs} • model=${result.model ?? 'unknown'} '
        '• attempts=$attempts'
        '${result.error == null ? '' : ' • error=${result.error}'}';
    try {
      await ctx.ref
          .read(trackerRepoProvider)
          .upsertValue(
            sessionId,
            '_ledger_diag:studio_ledger_reconciliation',
            value,
            scope: 'ledger_diagnostic',
            provenance:
                'message=${targetMessage.id}|swipe=${targetMessage.swipeId}|'
                'agentSwipe=${targetMessage.agentSwipeId}|range=$startMessageId..$endMessageId',
          );
    } catch (e) {
      debugPrint(
        '[StudioLedger] reconciliation diagnostic write failed '
        'session=$sessionId: $e',
      );
    }
  }

  void _recordOperation({
    required String sessionId,
    required ChatMessage targetMessage,
    required LedgerRunResult result,
    AgentOperationKind kind = AgentOperationKind.studioLedger,
    String idPrefix = 'studio-ledger',
    String? successSummary,
    bool? canRegenerate,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final startedAt = result.attempts.isNotEmpty
        ? result.attempts.first.startedAtMs
        : now - result.elapsedMs;
    final finishedAt = result.attempts.isNotEmpty
        ? result.attempts.last.startedAtMs + result.attempts.last.elapsedMs
        : now;
    final status = ledgerStatusToOp(result.status);
    ctx.ref.read(agentOperationsLogProvider.notifier).state = ctx.ref
        .read(agentOperationsLogProvider)
        .append(
          AgentOperationRecord(
            id: '$idPrefix-${targetMessage.id}-${DateTime.now().microsecondsSinceEpoch}',
            kind: kind,
            status: status,
            sessionId: sessionId,
            messageId: targetMessage.id,
            attempts: result.attempts,
            totalElapsedMs: result.elapsedMs,
            model: result.model,
            summary: status.isOk
                ? successSummary ?? 'ops=${result.opsApplied}'
                : result.error ?? result.status,
            startedAtMs: startedAt,
            finishedAtMs: finishedAt,
            canRegenerate: canRegenerate ?? status.isFailure,
          ),
        );
  }
}

/// Automatic reconciliation belongs to the Studio Ledger. Card Rewriter may
/// consume successful runs, but does not own their execution.
@visibleForTesting
bool shouldRunAutomaticLedgerReconciliation({
  required bool ledgerEnabled,
  required bool isManualRerun,
}) => !isManualRerun && ledgerEnabled;
