import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_db.dart' show RewriteJobRow;
import '../../core/db/repositories/card_evolution_repo.dart'
    show CardEvolutionFinalizeOutcome;
import '../../core/llm/model_fetcher.dart';
import '../../core/models/api_config.dart';
import '../../core/models/card_rewriter_settings.dart';
import '../../core/state/card_rewriter_providers.dart';
import '../../core/state/active_studio_preset_provider.dart';
import '../../core/state/pipeline_settings_provider.dart';
import '../../shared/utils/time_formatter.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../settings/api_list_provider.dart';

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
      title: 'Card Rewriter',
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

  Future<void> _save(CardRewriterSettings Function(CardRewriterSettings) edit) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref
        .read(pipelineSettingsProvider.notifier)
        .save(pipeline.copyWith(cardRewriter: edit(pipeline.cardRewriter)));
  }

  Future<void> _selectApi(CardRewriterSettings settings) async {
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    if (configs.isEmpty) {
      GlazeToast.show(context, 'No API configs found.');
      return;
    }
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Card Rewriter API',
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
      if (mounted) GlazeToast.show(context, 'Failed to fetch models: $error');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _run(CardRewriterSettings settings) async {
    if (!settings.enabled || settings.apiConfigId.isEmpty || _running) return;
    setState(() => _running = true);
    final outcome = await ref
        .read(automatedCardEvolutionServiceProvider)
        .runOneBatch(widget.sessionId);
    if (!mounted) return;
    setState(() => _running = false);
    if (outcome.isPersisted && outcome.job != null) {
      Navigator.of(
        context,
        rootNavigator: true,
      ).pop('/character/${widget.charId}/rewrite/${outcome.job!.id}');
      return;
    }
    GlazeToast.show(context, _runMessage(outcome), position: ToastPosition.top);
  }

  String _runMessage(
    CardEvolutionFinalizeOutcome outcome,
  ) => switch (outcome.kind) {
    'notEligible' =>
      'At least one user and one assistant message are required.',
    'busy' => 'Card Rewriter is already running for this session.',
    'activeJob' => 'Review or close the current Card Rewriter proposal first.',
    'modelNotConfigured' => 'Choose a valid dedicated API preset and model.',
    'cardModelFailed' =>
      'Card model failed: ${outcome.detail ?? 'unknown transport error'}',
    'lorebookModelFailed' =>
      'Lorebook model failed: ${outcome.detail ?? 'unknown transport error'}',
    'invalidCardOutput' =>
      'Invalid card patch: ${outcome.detail ?? 'unknown response format'}',
    'invalidOperation' =>
      'Card patch no longer matches the current card: ${outcome.detail ?? 'validation failed'}',
    'invalidLorebookOperation' =>
      'Lorebook patch no longer matches the injected entry.',
    'invalidLorebookOutput' =>
      'The lorebook model returned an invalid patch response.',
    'emptyModelProposal' =>
      'The model returned no patches despite the supplied evidence. Check the saved debug response.',
    'snapshotUnavailable' || 'stale' || 'staleEvidence' =>
      'The chat or Ledger changed while the snapshot was being prepared. Try again.',
    'snapshotTooLarge' =>
      outcome.detail ??
          'The Card Rewriter snapshot exceeds its safe size limit.',
    'disabled' => 'Enable Card Rewriter first.',
    'cancelled' => 'Card Rewriter was cancelled.',
    _ => 'Card Rewriter skipped: ${outcome.kind}',
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
    final studioPreset = ref.watch(studioPresetProvider).value;
    final ledgerEnabled =
        studioPreset != null && studioPreset.agentEnabled['ledger'] != false;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text(
              'Collects Card Rewriter observations from successful Ledger reconciliation runs. Ledger and reconciliation are controlled by the active Studio preset.',
            ),
            value: settings.enabled,
            onChanged: (enabled) =>
                _save((value) => value.copyWith(enabled: enabled)),
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
                      'Card Rewriter does not work without Studio Ledger and its reconciliation runs. Enable Ledger in the active Studio preset first.',
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Rewrite injected lorebook entries'),
            subtitle: const Text(
              'Uses a separate model call only for lorebook entries injected into this session. Turn this off when you do not use lorebooks.',
            ),
            value: settings.lorebookEvolutionEnabled,
            onChanged: settings.enabled
                ? (enabled) => _save(
                    (value) =>
                        value.copyWith(lorebookEvolutionEnabled: enabled),
                  )
                : null,
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey('timeout-${settings.timeoutMs}'),
            initialValue: '${settings.timeoutMs ~/ 1000}',
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Writer timeout (seconds)',
              helperText:
                  'Idle timeout for each card or lorebook model call. Default: 180 seconds.',
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
          Text('Model', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Uses a dedicated API preset. It never falls back to the chat model.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _selectApi(settings),
              icon: const Icon(Icons.api, size: 16),
              label: Text(
                config == null
                    ? 'Select API preset'
                    : 'API: ${_apiLabel(config)}',
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
                  ? 'Loading models...'
                  : configured
                  ? 'Empty uses the selected API preset model.'
                  : 'Select an API preset first.',
            ),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('Use API preset model'),
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
                settings.enabled && ledgerEnabled && configured && !_running
                ? () => _run(settings)
                : null,
            icon: _running
                ? const SizedBox.square(dimension: 16, child: GlazeSpinner())
                : const Icon(Icons.auto_fix_high_outlined),
            label: Text(_running ? 'Preparing proposal...' : 'Run now'),
          ),
          const SizedBox(height: 20),
          Text('Past diffs', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          jobs.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: GlazeSpinner()),
            ),
            error: (_, _) => const Text('Could not load rewrite history.'),
            data: (items) {
              final automated = items.where(_isAutomated).toList();
              if (automated.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No automated Card Rewriter proposals yet.'),
                );
              }
              return Column(
                children: [
                  for (final job in automated)
                    ListTile(
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
                ],
              );
            },
          ),
        ],
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

String _apiLabel(ApiConfig config) {
  if (config.name.isNotEmpty) return config.name;
  if (config.model.isNotEmpty) return config.model;
  return config.endpoint.isNotEmpty ? config.endpoint : config.id;
}

String _statusLabel(String status) => switch (status) {
  'pending' => 'Ready for review',
  'applied' => 'Applied',
  'failed' => 'Failed',
  'cancelled' => 'Cancelled',
  _ => 'Generating',
};
