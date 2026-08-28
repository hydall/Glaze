import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_db.dart'
    show CardEvolutionWriterCallRow, RewriteJobRow;
import '../../core/db/repositories/card_evolution_repo.dart'
    show CardEvolutionFinalizeOutcome;
import '../../core/llm/model_fetcher.dart';
import '../../core/models/api_config.dart';
import '../../core/models/card_rewriter_settings.dart';
import '../../core/state/card_rewriter_providers.dart';
import '../../core/state/active_studio_preset_provider.dart';
import '../../core/state/pipeline_settings_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/utils/time_formatter.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_text_field.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../settings/api_list_provider.dart';
import 'card_rewriter_recovery_view_service.dart';

/// Studio sub-screen for the review-only automated Card Rewriter.
class CardRewriterStudioSheet extends ConsumerStatefulWidget {
  const CardRewriterStudioSheet({
    super.key,
    required this.charId,
    required this.sessionId,
  });

  final String charId;
  final String sessionId;

  static Future<String?> show(
    BuildContext context, {
    required String charId,
    required String sessionId,
  }) {
    return GlazeBottomSheet.show<String>(
      context,
      title: 'card_rewriter_studio_title'.tr(),
      child: CardRewriterStudioSheet(charId: charId, sessionId: sessionId),
    );
  }

  @override
  ConsumerState<CardRewriterStudioSheet> createState() =>
      _CardRewriterStudioSheetState();
}

class _CardRewriterStudioSheetState
    extends ConsumerState<CardRewriterStudioSheet> {
  List<String> _models = const [];
  bool _loadingModels = false;
  bool _running = false;
  String? _recoveringCallId;

  Future<void> _save(CardRewriterSettings Function(CardRewriterSettings) edit) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref
        .read(pipelineSettingsProvider.notifier)
        .save(pipeline.copyWith(cardRewriter: edit(pipeline.cardRewriter)));
  }

  Future<void> _selectApi(CardRewriterSettings settings) async {
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    if (configs.isEmpty) {
      GlazeToast.show(context, 'card_rewriter_studio_no_api_configs'.tr());
      return;
    }
    await GlazeBottomSheet.show<void>(
      context,
      title: 'card_rewriter_studio_api_title'.tr(),
      items: [
        for (final config in configs)
          BottomSheetItem(
            label: _apiLabel(config),
            hint: config.endpoint,
            icon: config.id == settings.apiConfigId ? Icons.check : Icons.api,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              unawaited(
                _save(
                  (value) =>
                      value.copyWith(apiConfigId: config.id, modelOverride: ''),
                ),
              );
              setState(() => _models = const []);
            },
          ),
      ],
    );
  }

  Future<void> _fetchModels(ApiConfig? config) async {
    if (config == null || _loadingModels) return;
    setState(() => _loadingModels = true);
    try {
      final models = await ModelFetcher.fetchModelIds(config);
      if (!mounted) return;
      setState(() => _models = models);
    } catch (error) {
      if (mounted) {
        GlazeToast.show(
          context,
          'card_rewriter_studio_fetch_models_failed'.tr(
            namedArgs: {'error': '$error'},
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
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
    setState(() => _running = true);
    try {
      final service = ref.read(automatedCardEvolutionServiceProvider);
      final outcome = recovery == null
          ? await service.runOneBatch(widget.sessionId)
          : await service.resumeFailedWriter(recovery.claim.id);
      if (!mounted) return;
      _refreshRecovery();
      if (outcome.isPersisted && outcome.job != null) {
        Navigator.of(
          context,
          rootNavigator: true,
        ).pop('/character/${widget.charId}/rewrite/${outcome.job!.id}');
        return;
      }
      GlazeToast.show(
        context,
        _runMessage(outcome),
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
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _retryWriterCall(CardEvolutionWriterCallRow call) async {
    if (_running || _recoveringCallId != null) return;
    setState(() => _recoveringCallId = call.id);
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .retryFailedWriterCall(call.id);
      if (!mounted) return;
      _refreshRecovery();
      if (outcome.isPersisted && outcome.job != null) {
        Navigator.of(
          context,
          rootNavigator: true,
        ).pop('/character/${widget.charId}/rewrite/${outcome.job!.id}');
        return;
      }
      GlazeToast.show(context, _runMessage(outcome));
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
      if (mounted) setState(() => _recoveringCallId = null);
    }
  }

  Future<void> _correctWriterCall(CardEvolutionWriterCallRow call) async {
    if (_running || _recoveringCallId != null) return;
    final controller = TextEditingController(text: call.responseText ?? '');
    String? response;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'card_rewriter_studio_correct_title'.tr(
        namedArgs: {'stage': _writerStageLabel(call.stage)},
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('card_rewriter_studio_correct_body'.tr()),
            const SizedBox(height: 12),
            GlazeTextField(controller: controller, maxLines: 14),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                response = controller.text.trim();
                Navigator.of(context, rootNavigator: true).pop();
              },
              child: Text('card_rewriter_studio_validate_continue'.tr()),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || response == null || response!.isEmpty) return;
    setState(() => _recoveringCallId = call.id);
    try {
      final outcome = await ref
          .read(automatedCardEvolutionServiceProvider)
          .correctFailedWriterCall(call.id, response: response!);
      if (!mounted) return;
      _refreshRecovery();
      if (outcome.isPersisted && outcome.job != null) {
        Navigator.of(
          context,
          rootNavigator: true,
        ).pop('/character/${widget.charId}/rewrite/${outcome.job!.id}');
        return;
      }
      GlazeToast.show(context, _runMessage(outcome));
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
      if (mounted) setState(() => _recoveringCallId = null);
    }
  }

  Future<void> _deleteWriterRecovery(CardRewriterRecoveryView recovery) async {
    if (_running || _recoveringCallId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('card_rewriter_studio_delete_chain_title'.tr()),
        content: Text('card_rewriter_studio_delete_chain_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('common_cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('rewrite_delete'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _recoveringCallId = recovery.claim.id);
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
      if (mounted) setState(() => _recoveringCallId = null);
    }
  }

  void _refreshRecovery() {
    ref.invalidate(cardRewriterRecoveryViewsProvider(widget.sessionId));
    ref.invalidate(cardRewriteDebugRunsProvider(widget.sessionId));
  }

  String _runMessage(
    CardEvolutionFinalizeOutcome outcome,
  ) => switch (outcome.kind) {
    'notEligible' => 'card_rewriter_studio_outcome_not_eligible'.tr(),
    'busy' => 'card_rewriter_studio_outcome_busy'.tr(),
    'activeJob' => 'card_rewriter_studio_outcome_active_job'.tr(),
    'modelNotConfigured' =>
      'card_rewriter_studio_outcome_model_not_configured'.tr(),
    'cardModelFailed' => 'card_rewriter_studio_outcome_card_model_failed'.tr(
      namedArgs: {'error': outcome.detail ?? 'unknown'},
    ),
    'lorebookModelFailed' =>
      'card_rewriter_studio_outcome_lorebook_model_failed'.tr(
        namedArgs: {'error': outcome.detail ?? 'unknown'},
      ),
    'invalidCardOutput' => 'card_rewriter_studio_outcome_invalid_card'.tr(
      namedArgs: {'error': outcome.detail ?? 'unknown'},
    ),
    'invalidOperation' => 'card_rewriter_studio_outcome_invalid_operation'.tr(
      namedArgs: {'error': outcome.detail ?? 'unknown'},
    ),
    'invalidLorebookOperation' =>
      'card_rewriter_studio_outcome_invalid_lorebook_operation'.tr(),
    'invalidLorebookOutput' =>
      'card_rewriter_studio_outcome_invalid_lorebook_output'.tr(),
    'emptyModelProposal' => 'card_rewriter_studio_outcome_empty_proposal'.tr(),
    'snapshotUnavailable' ||
    'stale' ||
    'staleEvidence' => 'card_rewriter_studio_outcome_stale'.tr(),
    'snapshotTooLarge' =>
      outcome.detail ?? 'card_rewriter_studio_outcome_too_large'.tr(),
    'disabled' => 'card_rewriter_studio_outcome_disabled'.tr(),
    'cancelled' => 'card_rewriter_studio_outcome_cancelled'.tr(),
    'writerCallNotFound' => 'card_rewriter_studio_outcome_call_not_found'.tr(),
    'writerCallNotFailed' ||
    'writerNotFailed' => 'card_rewriter_studio_outcome_not_failed'.tr(),
    'writerCallNotFrontier' => 'card_rewriter_studio_outcome_not_frontier'.tr(),
    'writerCallRetryFailed' ||
    'leaseLost' => 'card_rewriter_studio_outcome_lease_lost'.tr(),
    'claimMissing' => 'card_rewriter_studio_outcome_claim_missing'.tr(),
    _ => 'card_rewriter_studio_outcome_skipped'.tr(
      namedArgs: {'kind': outcome.kind},
    ),
  };

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      pipelineSettingsProvider.select((value) => value.cardRewriter),
    );
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final config = configs
        .where((item) => item.id == settings.apiConfigId)
        .firstOrNull;
    final models = <String>{
      ..._models,
      if (settings.modelOverride.isNotEmpty) settings.modelOverride,
      if (config?.model.isNotEmpty == true) config!.model,
    }.toList()..sort();
    final configured = settings.apiConfigId.isNotEmpty && config != null;
    final jobs = ref.watch(cardRewriteJobsBySessionProvider(widget.sessionId));
    final lorebookOverlays = ref.watch(
      cardRewriteLorebookOverlaysProvider(widget.sessionId),
    );
    final debugRuns = ref.watch(cardRewriteDebugRunsProvider(widget.sessionId));
    final recoveryViews = ref.watch(
      cardRewriterRecoveryViewsProvider(widget.sessionId),
    );
    final firstRecovery = recoveryViews.value?.firstOrNull;
    final recoveryLoading = recoveryViews.isLoading;
    final studioPreset = ref.watch(studioPresetProvider).value;
    final ledgerEnabled =
        studioPreset != null && studioPreset.agentEnabled['ledger'] != false;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('card_rewriter_studio_enabled'.tr()),
              subtitle: Text('card_rewriter_studio_enabled_description'.tr()),
              value: settings.enabled,
              onChanged: (enabled) =>
                  _save((value) => value.copyWith(enabled: enabled)),
            ),
          ),
          if (!ledgerEnabled) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'card_rewriter_studio_ledger_required'.tr(),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('card_rewriter_studio_rewrite_lorebook'.tr()),
              subtitle: Text(
                'card_rewriter_studio_rewrite_lorebook_description'.tr(),
              ),
              value: settings.lorebookEvolutionEnabled,
              onChanged: settings.enabled
                  ? (enabled) => _save(
                      (value) =>
                          value.copyWith(lorebookEvolutionEnabled: enabled),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey('timeout-${settings.timeoutMs}'),
            initialValue: '${settings.timeoutMs ~/ 1000}',
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'card_rewriter_studio_timeout'.tr(),
              helperText: 'card_rewriter_studio_timeout_description'.tr(),
              isDense: true,
            ),
            onChanged: (raw) {
              final seconds = int.tryParse(raw);
              if (seconds == null || seconds <= 0) return;
              final timeoutMs = seconds * 1000;
              if (timeoutMs == settings.timeoutMs) return;
              unawaited(_save((value) => value.copyWith(timeoutMs: timeoutMs)));
            },
          ),
          const SizedBox(height: 16),
          Text(
            'card_rewriter_studio_model'.tr(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'card_rewriter_studio_model_description'.tr(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _selectApi(settings),
              icon: const Icon(Icons.api, size: 16),
              label: Text(
                config == null
                    ? 'card_rewriter_studio_select_api'.tr()
                    : 'card_rewriter_studio_api'.tr(
                        namedArgs: {'api': _apiLabel(config)},
                      ),
              ),
            ),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('${settings.apiConfigId}:${settings.modelOverride}'),
            initialValue: models.contains(settings.modelOverride)
                ? settings.modelOverride
                : null,
            isExpanded: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              helperText: _loadingModels
                  ? 'card_rewriter_studio_loading_models'.tr()
                  : configured
                  ? 'card_rewriter_studio_empty_uses_api_model'.tr()
                  : 'card_rewriter_studio_select_api_first'.tr(),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text('card_rewriter_studio_use_api_model'.tr()),
              ),
              for (final model in models)
                DropdownMenuItem(value: model, child: Text(model)),
            ],
            onTap: () => unawaited(_fetchModels(config)),
            onChanged: configured
                ? (model) => _save(
                    (value) => value.copyWith(modelOverride: model ?? ''),
                  )
                : null,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed:
                !_running &&
                    !recoveryLoading &&
                    (firstRecovery != null ||
                        (settings.enabled && ledgerEnabled && configured))
                ? () => _run(settings, recovery: firstRecovery)
                : null,
            icon: _running
                ? const SizedBox.square(dimension: 16, child: GlazeSpinner())
                : const Icon(Icons.auto_fix_high_outlined),
            label: Text(
              _running
                  ? firstRecovery == null
                        ? 'card_rewriter_studio_preparing'.tr()
                        : 'card_rewriter_studio_continuing'.tr()
                  : firstRecovery == null
                  ? 'card_rewriter_studio_run_now'.tr()
                  : 'card_rewriter_studio_continue_chain'.tr(),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'card_rewriter_studio_interrupted_chains'.tr(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          recoveryViews.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: GlazeSpinner()),
            ),
            error: (_, _) =>
                Text('card_rewriter_studio_interrupted_load_failed'.tr()),
            data: (items) => items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('card_rewriter_studio_no_interrupted'.tr()),
                  )
                : Column(
                    children: [
                      for (final recovery in items)
                        _WriterRecoveryTile(
                          recovery: recovery,
                          busy: _running || _recoveringCallId != null,
                          onContinue: () => _run(settings, recovery: recovery),
                          onRetry: _retryWriterCall,
                          onCorrect: _correctWriterCall,
                          onDelete: () => _deleteWriterRecovery(recovery),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          Text(
            'card_rewriter_studio_diagnostics'.tr(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          debugRuns.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: GlazeSpinner()),
            ),
            error: (_, _) =>
                Text('card_rewriter_studio_diagnostics_load_failed'.tr()),
            data: (items) => items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text('card_rewriter_studio_no_calls'.tr()),
                  )
                : Column(
                    children: [
                      for (final run in items)
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          leading: Icon(
                            run.status == 'ok'
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            color: run.status == 'ok'
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                          title: Text(
                            '${_debugStageLabel(run.stage)} · ${_debugStatusLabel(run.status)}',
                          ),
                          subtitle: Text(
                            run.model.isEmpty
                                ? 'card_rewriter_studio_model_unavailable'.tr()
                                : run.model,
                          ),
                          childrenPadding: const EdgeInsets.only(bottom: 12),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              run.output ??
                                  'card_rewriter_studio_raw_output_unavailable'
                                      .tr(),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'card_rewriter_studio_legacy_stage_note'.tr(),
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          Text(
            'card_rewriter_studio_past_diffs'.tr(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          lorebookOverlays.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (items) => items.isEmpty
                ? const SizedBox.shrink()
                : Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: Text(
                        'card_rewriter_studio_active_lorebook_changes'.tr(
                          namedArgs: {'count': '${items.length}'},
                        ),
                      ),
                      subtitle: Text(
                        'card_rewriter_studio_synced_history_note'.tr(),
                      ),
                    ),
                  ),
          ),
          jobs.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: GlazeSpinner()),
            ),
            error: (_, _) =>
                Text('card_rewriter_studio_history_load_failed'.tr()),
            data: (items) {
              final automated = items.where(_isAutomated).toList();
              if (automated.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    lorebookOverlays.value?.isNotEmpty == true
                        ? 'card_rewriter_studio_no_local_proposals'.tr()
                        : 'card_rewriter_studio_no_proposals'.tr(),
                  ),
                );
              }
              return Column(
                children: [
                  for (final job in automated)
                    Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.compare_arrows_outlined),
                        title: Text(_statusLabel(job.status)),
                        subtitle: Text(
                          formatRelativeTimeFromSeconds(job.updatedAt),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(
                          context,
                          rootNavigator: true,
                        ).pop('/character/${widget.charId}/rewrite/${job.id}'),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _WriterRecoveryTile extends StatelessWidget {
  const _WriterRecoveryTile({
    required this.recovery,
    required this.busy,
    required this.onContinue,
    required this.onRetry,
    required this.onCorrect,
    required this.onDelete,
  });

  final CardRewriterRecoveryView recovery;
  final bool busy;
  final VoidCallback onContinue;
  final ValueChanged<CardEvolutionWriterCallRow> onRetry;
  final ValueChanged<CardEvolutionWriterCallRow> onCorrect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final frontier = recovery.frontier;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(Icons.pause_circle_outline, color: context.cs.error),
        title: Text(
          frontier == null
              ? recovery.calls.isEmpty
                    ? 'card_rewriter_studio_resume_chain'.tr()
                    : 'card_rewriter_studio_finalize_chain'.tr()
              : 'card_rewriter_studio_stage_failed'.tr(
                  namedArgs: {'stage': _writerStageLabel(frontier.stage)},
                ),
        ),
        subtitle: Text(
          'card_rewriter_studio_requests_completed'.tr(
            namedArgs: {
              'completed': '${recovery.completedCount}',
              'total': '${recovery.calls.length}',
            },
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RecoveryDetail(
            label: 'card_rewriter_studio_claim'.tr(),
            value: recovery.claim.id,
          ),
          if (recovery.claim.failureCode != null)
            _RecoveryDetail(
              label: 'card_rewriter_studio_failure'.tr(),
              value: recovery.claim.failureCode!,
            ),
          if (recovery.claim.failureDetail != null)
            _RecoveryDetail(
              label: 'card_rewriter_studio_failure_detail'.tr(),
              value: recovery.claim.failureDetail!,
            ),
          const SizedBox(height: 6),
          for (final call in recovery.calls)
            _WriterCallTile(call: call, isFrontier: call.id == frontier?.id),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onContinue,
                icon: const Icon(Icons.play_arrow_outlined),
                label: Text('card_rewriter_studio_continue_chain'.tr()),
              ),
              if (frontier?.status == 'failed') ...[
                OutlinedButton.icon(
                  onPressed: busy ? null : () => onRetry(frontier!),
                  icon: const Icon(Icons.refresh),
                  label: Text('card_rewriter_studio_retry_request'.tr()),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : () => onCorrect(frontier!),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text('card_rewriter_studio_correct_response'.tr()),
                ),
              ],
              OutlinedButton.icon(
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text('rewrite_delete'.tr()),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.cs.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WriterCallTile extends StatelessWidget {
  const _WriterCallTile({required this.call, required this.isFrontier});

  final CardEvolutionWriterCallRow call;
  final bool isFrontier;

  @override
  Widget build(BuildContext context) {
    final color = switch (call.status) {
      'completed' => context.cs.primary,
      'failed' => context.cs.error,
      _ => Colors.orange,
    };
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 10),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      leading: Icon(switch (call.status) {
        'completed' => Icons.check_circle_outline,
        'failed' => Icons.error_outline,
        'prepared' => Icons.pause_circle_outline,
        _ => Icons.hourglass_top,
      }, color: color),
      title: Text(
        '${call.ordinal}. ${_writerStageLabel(call.stage)}'
        '${call.stageOrdinal > 1 ? ' ${call.stageOrdinal}' : ''}',
      ),
      subtitle: Text(
        isFrontier
            ? 'card_rewriter_studio_call_current'.tr(
                namedArgs: {'status': _writerCallStatusLabel(call.status)},
              )
            : _writerCallStatusLabel(call.status),
      ),
      children: [
        _RecoveryDetail(
          label: 'card_rewriter_studio_prompt_hash'.tr(),
          value: call.promptHash,
        ),
        if (call.failureCode != null)
          _RecoveryDetail(
            label: 'card_rewriter_studio_failure'.tr(),
            value: call.failureCode!,
          ),
        if (call.failureDetail != null)
          _RecoveryDetail(
            label: 'card_rewriter_studio_failure_detail'.tr(),
            value: call.failureDetail!,
          ),
        if (call.parserCode != null)
          _RecoveryDetail(
            label: 'card_rewriter_studio_parser'.tr(),
            value: call.parserCode!,
          ),
        if (call.parserDetail != null)
          _RecoveryDetail(
            label: 'card_rewriter_studio_parser_detail'.tr(),
            value: call.parserDetail!,
          ),
        const SizedBox(height: 6),
        Text(
          'card_rewriter_studio_prompt'.tr(),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        SelectableText(
          call.prompt,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        const SizedBox(height: 8),
        Text(
          'card_rewriter_studio_response'.tr(),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        SelectableText(
          call.responseText ?? 'card_rewriter_studio_no_response'.tr(),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ],
    );
  }
}

class _RecoveryDetail extends StatelessWidget {
  const _RecoveryDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: SelectableText('$label: $value'),
  );
}

bool _isAutomated(RewriteJobRow job) {
  try {
    final request = jsonDecode(job.requestJson);
    return request is Map && request['provenance'] == 'automatedEvolution';
  } catch (_) {
    return false;
  }
}

String _apiLabel(ApiConfig config) {
  if (config.name.isNotEmpty) return config.name;
  if (config.model.isNotEmpty) return config.model;
  return config.endpoint.isNotEmpty ? config.endpoint : config.id;
}

String _statusLabel(String status) => switch (status) {
  'pending' => 'card_rewriter_studio_status_review'.tr(),
  'applied' => 'card_rewriter_studio_status_applied'.tr(),
  'failed' => 'card_rewriter_studio_status_failed'.tr(),
  'cancelled' => 'card_rewriter_studio_status_cancelled'.tr(),
  _ => 'card_rewriter_studio_status_generating'.tr(),
};

String _writerStageLabel(String stage) => switch (stage) {
  'history_consolidation' =>
    'card_rewriter_studio_stage_history_consolidation'.tr(),
  'card_writer' => 'card_rewriter_studio_stage_card_writer'.tr(),
  'card_repair' => 'card_rewriter_studio_stage_card_repair'.tr(),
  'lorebook_writer' => 'card_rewriter_studio_stage_lorebook_writer'.tr(),
  _ => stage,
};

String _writerCallStatusLabel(String status) => switch (status) {
  'completed' => 'card_rewriter_studio_status_completed'.tr(),
  'failed' => 'card_rewriter_studio_status_failed'.tr(),
  // Recovery chains only render failed claims, so a prepared call is always
  // a checkpoint of an interrupted attempt — never an in-flight request.
  'prepared' => 'card_rewriter_studio_status_prepared'.tr(),
  _ => 'card_rewriter_studio_status_pending'.tr(),
};

String _debugStageLabel(String stage) => switch (stage) {
  'card' || 'card_writer' => 'card_rewriter_studio_stage_card_writer'.tr(),
  'card_repair' => 'card_rewriter_studio_stage_card_repair'.tr(),
  'history_consolidation' =>
    'card_rewriter_studio_stage_history_consolidation'.tr(),
  'lorebook' ||
  'lorebook_writer' => 'card_rewriter_studio_stage_lorebook_writer'.tr(),
  _ => stage,
};

String _debugStatusLabel(String status) => switch (status) {
  'ok' || 'completed' => 'card_rewriter_studio_status_completed'.tr(),
  'failed' || 'error' => 'card_rewriter_studio_status_failed'.tr(),
  _ => status,
};
