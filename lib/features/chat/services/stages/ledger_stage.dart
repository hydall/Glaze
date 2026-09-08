import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/llm/aux_llm_client.dart' show AuxApiConfig;
import '../../../../core/llm/macro_engine.dart';
import '../../../../core/llm/studio_ledger_service.dart';
import '../../../../core/llm/studio_ledger_reconciliation.dart';
import '../../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../../core/models/agent_operation_record.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/pipeline_settings.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/memory_agent_providers.dart';
import '../../../../core/state/character_provider.dart';
import '../../../../core/state/studio_turn_config_resolver.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../state/agent_operations_log_provider.dart';
import '../../state/post_gen_status_provider.dart';
import '../pipeline_utils.dart';
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
    AuxApiConfig? resolvedConfig,
    CancelToken? cancelToken,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    if (!ctx.ref.mounted) return;

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

      // Ledger is always-on when Studio is enabled. We check
      // StudioConfig.enabled to decide whether the ledger should run.
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

      // Cadence (plan §Model Cadence). Studio Ledger is mandatory while Studio
      // is enabled, so cadence only gates standalone Ledger outside Studio.
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

      // Resolve the LLM config. When the caller provides a pre-resolved
      // config (e.g. the cleaner stage passes its own resolved config so
      // the ledger inherits the same model without re-resolving), use it
      // directly. Otherwise resolve from the Studio cleaner slot.
      final AuxApiConfig ledgerConfig;
      if (resolvedConfig != null) {
        ledgerConfig = resolvedConfig;
      } else {
        try {
          ledgerConfig = turnConfig.resolveCleanerConfig(
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
      }

      final recentHistory = extractRecentHistoryText(messages, maxMessages: 10);

      final service = ctx.ref.read(studioLedgerServiceProvider);

      // Build MacroContext for resolving preset-block macros.
      final character = ctx.ref.read(characterByIdProvider(ctx.charId));
      final ledgerMacroCtx = MacroContext(
        charName: character?.name ?? '',
        charDescription: character?.description,
        charScenario: character?.scenario,
        charPersonality: character?.personality,
        charMesExample: character?.mesExample,
        userName: 'User',
        macroName: character?.macroName,
        charId: ctx.charId,
        sessionId: sessionId,
      );

      LedgerRunResult? reconciliationResult;
      if (!isManualRerun) {
        final checkpointRepo = ctx.ref.read(
          ledgerReconciliationCheckpointRepoProvider,
        );
        final checkpoint = await checkpointRepo.get(sessionId);
        final plan = const LedgerReconciliationPlanner().plan(
          messages: messages,
          currentAssistantMessageId: targetMessage.id,
          checkpoint: checkpoint,
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
          if (ctx.ref.mounted) {
            ctx.ref
                .read(postGenStatusProvider.notifier)
                .state = PostGenStatusState.running(
              sessionId: sessionId,
              task: PostGenTask.ledgerReconciliation,
            );
          }
          reconciliationResult = await service.reconcile(
            sessionId: sessionId,
            settings: pipeline,
            config: ledgerConfig,
            plan: plan,
            ledgerBlocks: studioPreset?.blocks ?? const [],
            macroCtx: ledgerMacroCtx,
            isStillCurrent: isCurrent,
            cancelToken: cancelToken,
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
            ctx.ref
                .read(postGenStatusProvider.notifier)
                .state = reconciliationResult.status == 'ok'
                ? PostGenStatusState.done(
                    sessionId: sessionId,
                    task: PostGenTask.ledgerReconciliation,
                    detail: detail,
                  )
                : PostGenStatusState.error(
                    sessionId: sessionId,
                    task: PostGenTask.ledgerReconciliation,
                    detail: detail,
                  );
          }
          debugPrint(
            '[StudioLedger] reconciliation session=$sessionId '
            'range=${plan.startMessageId}..${plan.endMessage.id} '
            'status=${reconciliationResult.status} '
            'ops=${reconciliationResult.opsApplied} '
            'error=${reconciliationResult.error ?? "none"}',
          );
          if (!isCurrent()) return;
        }
      }

      if (ctx.ref.mounted) {
        ctx.ref
            .read(postGenStatusProvider.notifier)
            .state = PostGenStatusState.running(
          sessionId: sessionId,
          task: PostGenTask.ledger,
        );
      }

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
        ctx.ref
            .read(postGenStatusProvider.notifier)
            .state = result.status == 'ok'
            ? PostGenStatusState.done(
                sessionId: sessionId,
                task: PostGenTask.ledger,
                detail: detail,
              )
            : PostGenStatusState.error(
                sessionId: sessionId,
                task: PostGenTask.ledger,
                detail: detail,
              );
      }

      if (ledgerStatusToOp(result.status).isFailure) {
        GlazeToast.showWithoutContext(
          'Studio Ledger failed. Open Agentic Ops -> Last turn to inspect or rerun.',
          duration: 5000,
          position: ToastPosition.top,
          isError: true,
        );
      }

      debugPrint(
        '[StudioLedger] result session=$sessionId status=${result.status} '
        'opsApplied=${result.opsApplied} '
        'elapsedMs=${result.elapsedMs} '
        'error=${result.error ?? "none"}',
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
      GlazeToast.showWithoutContext(
        'Studio Ledger failed. Open Agentic Ops -> Last turn to inspect or rerun.',
        duration: 5000,
        position: ToastPosition.top,
        isError: true,
      );
    }
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
