import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_db.dart'
    show CardEvolutionWriterCallRow, RewriteJobRow;
import '../../core/models/api_config.dart';
import '../../core/models/card_rewriter_settings.dart';
import '../../core/state/card_rewriter_providers.dart';
import '../../core/state/active_studio_preset_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/utils/time_formatter.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_expansion_tile.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_text_field.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../settings/api_list_provider.dart';
import '../studio/widgets/studio_preset_options_sheet.dart'
    show confirmStudioDelete;
import 'card_rewriter_labels.dart';
import 'card_rewriter_recovery_view_service.dart';
import 'widgets/card_rewriter_recovery_tile.dart';
import '../chat/state/agent_ops_jobs_provider.dart';

/// The Card Rewriter lane's management surface — the Agent Ops tab of the same
/// name.
///
/// **Management only.** What the lane *is* — whether it runs, on which
/// connection, with which model and timeout — is configured per Studio preset:
/// the switch and the lane settings live in the agentic preset editor's
/// pipeline, the connection and model in the Agents tab of the API sheet. This
/// screen drives what has already been configured: run a batch now, recover an
/// interrupted writer chain, read what the last calls returned, and open a
/// proposal for review.
class CardRewriterStudioSheet extends ConsumerStatefulWidget {
  const CardRewriterStudioSheet({
    super.key,
    required this.charId,
    required this.sessionId,
  });

  final String charId;
  final String sessionId;

  @override
  ConsumerState<CardRewriterStudioSheet> createState() =>
      _CardRewriterStudioSheetState();
}

class _CardRewriterStudioSheetState
    extends ConsumerState<CardRewriterStudioSheet> {
  AgentOpsJobsNotifier get _jobs => ref.read(agentOpsJobsProvider.notifier);

  String get _runKey => AgentOpsJobKeys.cardRewriter(widget.sessionId);
  String _recoveryKey(String callId) =>
      AgentOpsJobKeys.cardRewriterRecovery(widget.sessionId, callId);

  /// Held in a provider, not in this State: a rewriter run keeps going when
  /// the sheet is closed, so reopening it has to find the same spinner and the
  /// same guard against starting it twice. Read rather than watched — `build`
  /// watches the set once, which is what rebuilds them.
  bool get _running => _jobs.isRunning(_runKey);
  bool get _recovering => _jobs.isAnyRunning(
    AgentOpsJobKeys.cardRewriterRecoveryScope(widget.sessionId),
  );

  // ── Actions ────────────────────────────────────────────────────────────────

  /// Pops the sheet onto the review route when a run produced a proposal. The
  /// caller routes; a sheet cannot push a screen the drawer sits on top of.
  bool _popToReview(String? jobId) {
    if (jobId == null) return false;
    Navigator.of(
      context,
      rootNavigator: true,
    ).pop('/character/${widget.charId}/rewrite/$jobId');
    return true;
  }

  Future<void> _run(
    CardRewriterSettings settings, {
    CardRewriterRecoveryView? recovery,
  }) async {
    if (_running) return;
    if (recovery == null &&
        (!settings.enabled || settings.apiConfigId.isEmpty)) {
      return;
    }
    // Captured before the await: `ref` is unusable once the widget is gone,
    // and the job still has to be cleared when it finishes.
    final jobs = _jobs;
    if (!jobs.start(_runKey)) return;
    try {
      final service = ref.read(automatedCardEvolutionServiceProvider);
      final outcome = recovery == null
          ? await service.runOneBatch(widget.sessionId)
          : await service.resumeFailedWriter(recovery.claim.id);
      if (!mounted) return;
      _refreshRecovery();
      if (outcome.isPersisted && _popToReview(outcome.job?.id)) return;
      GlazeToast.show(
        context,
        cardRewriterRunMessage(outcome),
        position: ToastPosition.top,
      );
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'card_rewriter_studio_failed'.tr(namedArgs: {'error': '$error'}),
        );
      }
    } finally {
      jobs.finish(_runKey);
    }
  }

  Future<void> _retryWriterCall(CardEvolutionWriterCallRow call) async {
    if (_running || _recovering) return;
    final jobs = _jobs;
    final key = _recoveryKey(call.id);
    if (!jobs.start(key)) return;
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .retryFailedWriterCall(call.id);
      if (!mounted) return;
      _refreshRecovery();
      if (outcome.isPersisted && _popToReview(outcome.job?.id)) return;
      GlazeToast.show(context, cardRewriterRunMessage(outcome));
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'card_rewriter_studio_writer_retry_failed'.tr(
            namedArgs: {'error': '$error'},
          ),
        );
      }
    } finally {
      jobs.finish(key);
    }
  }

  Future<void> _correctWriterCall(CardEvolutionWriterCallRow call) async {
    if (_running || _recovering) return;
    final response = await _askForCorrectedResponse(call);
    if (!mounted || response == null || response.isEmpty) return;
    final jobs = _jobs;
    final key = _recoveryKey(call.id);
    if (!jobs.start(key)) return;
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .correctFailedWriterCall(call.id, response: response);
      if (!mounted) return;
      _refreshRecovery();
      if (outcome.isPersisted && _popToReview(outcome.job?.id)) return;
      GlazeToast.show(context, cardRewriterRunMessage(outcome));
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'card_rewriter_studio_writer_correction_failed'.tr(
            namedArgs: {'error': '$error'},
          ),
        );
      }
    } finally {
      jobs.finish(key);
    }
  }

  /// The hand-editing sheet for a response the parser rejected. What comes back
  /// still goes through the same parser and validation, so this is a correction
  /// of the model's output, not a way around the contract.
  Future<String?> _askForCorrectedResponse(
    CardEvolutionWriterCallRow call,
  ) async {
    final controller = TextEditingController(text: call.responseText ?? '');
    try {
      String? response;
      await GlazeBottomSheet.show<void>(
        context,
        title: 'card_rewriter_studio_correct_title'.tr(
          namedArgs: {'stage': cardRewriterStageLabel(call.stage)},
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'card_rewriter_studio_correct_body'.tr(),
                style: TextStyle(
                  fontSize: 13,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              GlazeTextField(controller: controller, maxLines: 14),
              const SizedBox(height: 12),
              GlazeActionButton(
                icon: Icons.check_rounded,
                label: 'card_rewriter_studio_validate_continue'.tr(),
                tone: GlazeActionTone.primary,
                expand: true,
                onTap: () {
                  response = controller.text.trim();
                  Navigator.of(context, rootNavigator: true).pop();
                },
              ),
            ],
          ),
        ),
      );
      return response;
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteWriterRecovery(CardRewriterRecoveryView recovery) async {
    if (_running || _recovering) return;
    final confirmed = await confirmStudioDelete(
      context,
      title: 'card_rewriter_studio_delete_chain_title'.tr(),
      description: 'card_rewriter_studio_delete_chain_body'.tr(),
    );
    if (!confirmed || !mounted) return;
    final jobs = _jobs;
    final key = _recoveryKey(recovery.claim.id);
    if (!jobs.start(key)) return;
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .deleteFailedWriter(recovery.claim.id);
      if (!mounted) return;
      _refreshRecovery();
      GlazeToast.show(
        context,
        (outcome.isDeleted
                ? 'card_rewriter_studio_delete_chain_done'
                : 'card_rewriter_studio_delete_chain_failed')
            .tr(namedArgs: {'result': outcome.kind}),
      );
    } finally {
      jobs.finish(key);
    }
  }

  void _refreshRecovery() {
    ref.invalidate(cardRewriterRecoveryViewsProvider(widget.sessionId));
    ref.invalidate(cardRewriteDebugRunsProvider(widget.sessionId));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Subscribes this sheet to the running-jobs set; the getters above read it.
    ref.watch(agentOpsJobsProvider);
    final settings = ref.watch(cardRewriterSettingsProvider);
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final configured =
        settings.apiConfigId.isNotEmpty &&
        configs.any((item) => item.id == settings.apiConfigId);
    final recoveryViews = ref.watch(
      cardRewriterRecoveryViewsProvider(widget.sessionId),
    );
    final firstRecovery = recoveryViews.value?.firstOrNull;
    final studioPreset = ref.watch(studioPresetProvider).value;
    final ledgerEnabled =
        studioPreset != null && studioPreset.agentEnabled['ledger'] != false;
    final blocker = _blocker(
      settings: settings,
      ledgerEnabled: ledgerEnabled,
      configured: configured,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (blocker != null) ...[
          _LaneNotice(message: blocker),
          const SizedBox(height: 12),
        ],
        GlazeActionButton(
          icon: Icons.auto_fix_high_outlined,
          tone: GlazeActionTone.primary,
          expand: true,
          busy: _running,
          label: _running
              ? firstRecovery == null
                    ? 'card_rewriter_studio_preparing'.tr()
                    : 'card_rewriter_studio_continuing'.tr()
              : firstRecovery == null
              ? 'card_rewriter_studio_run_now'.tr()
              : 'card_rewriter_studio_continue_chain'.tr(),
          onTap:
              !recoveryViews.isLoading &&
                  (firstRecovery != null || blocker == null)
              ? () => _run(settings, recovery: firstRecovery)
              : null,
        ),
        const SizedBox(height: 20),
        _SectionLabel('card_rewriter_studio_interrupted_chains'.tr()),
        recoveryViews.when(
          loading: _loading,
          error: (_, _) =>
              _empty('card_rewriter_studio_interrupted_load_failed'.tr()),
          data: (items) => items.isEmpty
              ? _empty('card_rewriter_studio_no_interrupted'.tr())
              : Column(
                  children: [
                    for (final recovery in items)
                      CardRewriterRecoveryTile(
                        recovery: recovery,
                        busy: _running || _recovering,
                        onContinue: () => _run(settings, recovery: recovery),
                        onRetry: _retryWriterCall,
                        onCorrect: _correctWriterCall,
                        onDelete: () => _deleteWriterRecovery(recovery),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 20),
        _SectionLabel('card_rewriter_studio_diagnostics'.tr()),
        _buildDiagnostics(),
        const SizedBox(height: 20),
        _SectionLabel('card_rewriter_studio_past_diffs'.tr()),
        _buildLorebookOverlays(),
        _buildProposals(),
      ],
    );
  }

  /// Why the run button is dead, or null when the lane is ready. Each line
  /// names the setting that is missing — all of which now live elsewhere.
  String? _blocker({
    required CardRewriterSettings settings,
    required bool ledgerEnabled,
    required bool configured,
  }) {
    if (!ledgerEnabled) return 'card_rewriter_studio_ledger_required'.tr();
    if (!settings.enabled) return 'card_rewriter_studio_outcome_disabled'.tr();
    if (!configured) return 'card_rewriter_studio_select_api_first'.tr();
    return null;
  }

  Widget _buildDiagnostics() {
    return ref
        .watch(cardRewriteDebugRunsProvider(widget.sessionId))
        .when(
          loading: _loading,
          error: (_, _) =>
              _empty('card_rewriter_studio_diagnostics_load_failed'.tr()),
          data: (items) => items.isEmpty
              ? _empty('card_rewriter_studio_no_calls'.tr())
              : Column(
                  children: [
                    for (final run in items)
                      GlazeExpansionTile(
                        showDivider: true,
                        leading: Icon(
                          run.status == 'ok'
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 18,
                          color: run.status == 'ok'
                              ? context.cs.primary
                              : context.cs.error,
                        ),
                        title: Text(
                          '${cardRewriterDebugStageLabel(run.stage)} · '
                          '${cardRewriterDebugStatusLabel(run.status)}',
                        ),
                        subtitle: Text(
                          run.model.isEmpty
                              ? 'card_rewriter_studio_model_unavailable'.tr()
                              : run.model,
                        ),
                        children: [
                          CardRewriterRawBlock(
                            label: cardRewriterDebugStageLabel(run.stage),
                            body:
                                run.output ??
                                'card_rewriter_studio_raw_output_unavailable'
                                    .tr(),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'card_rewriter_studio_legacy_stage_note'.tr(),
                            style: TextStyle(
                              fontSize: 11,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
        );
  }

  Widget _buildLorebookOverlays() {
    return ref
        .watch(cardRewriteLorebookOverlaysProvider(widget.sessionId))
        .when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          data: (items) => items.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _LaneNotice(
                    icon: Icons.menu_book_outlined,
                    message: 'card_rewriter_studio_active_lorebook_changes'.tr(
                      namedArgs: {'count': '${items.length}'},
                    ),
                    detail: 'card_rewriter_studio_synced_history_note'.tr(),
                  ),
                ),
        );
  }

  Widget _buildProposals() {
    final overlays = ref.watch(
      cardRewriteLorebookOverlaysProvider(widget.sessionId),
    );
    return ref
        .watch(cardRewriteJobsBySessionProvider(widget.sessionId))
        .when(
          loading: _loading,
          error: (_, _) =>
              _empty('card_rewriter_studio_history_load_failed'.tr()),
          data: (items) {
            final automated = items.where(_isAutomated).toList();
            if (automated.isEmpty) {
              return _empty(
                overlays.value?.isNotEmpty == true
                    ? 'card_rewriter_studio_no_local_proposals'.tr()
                    : 'card_rewriter_studio_no_proposals'.tr(),
              );
            }
            return Column(
              children: [
                for (final job in automated)
                  _ProposalRow(
                    status: cardRewriterJobStatusLabel(job.status),
                    updatedAt: formatRelativeTimeFromSeconds(job.updatedAt),
                    onTap: () => _popToReview(job.id),
                  ),
              ],
            );
          },
        );
  }

  Widget _loading() => const Padding(
    padding: EdgeInsets.all(12),
    child: Center(child: GlazeSpinner()),
  );

  Widget _empty(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      message,
      style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
    ),
  );
}

/// A caption above a block of rows.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: context.cs.onSurface,
      ),
    ),
  );
}

/// A standing note about the lane: what is blocking a run, or what the session
/// is already carrying. Not an error dialog — it belongs next to the action it
/// explains and stays on screen.
class _LaneNotice extends StatelessWidget {
  const _LaneNotice({
    required this.message,
    this.detail,
    this.icon = Icons.info_outline_rounded,
  });

  final String message;
  final String? detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: context.cs.onSurfaceVariant.withValues(alpha: 0.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: context.cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 13,
                      color: context.cs.onSurface,
                      height: 1.3,
                    ),
                  ),
                  if (detail case final caption?) ...[
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One stored proposal, opening the durable review route.
class _ProposalRow extends StatelessWidget {
  const _ProposalRow({
    required this.status,
    required this.updatedAt,
    required this.onTap,
  });

  final String status;
  final String updatedAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.cs.outlineVariant),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Icon(
                Icons.compare_arrows_outlined,
                size: 20,
                color: context.cs.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurface,
                      ),
                    ),
                    Text(
                      updatedAt,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 22,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isAutomated(RewriteJobRow job) {
  try {
    final request = jsonDecode(job.requestJson);
    return request is Map && request['provenance'] == 'automatedEvolution';
  } catch (_) {
    return false;
  }
}
