import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/list_controls.dart';
import '../chat_provider.dart';
import '../services/prompt_capture_view_service.dart';

enum _CaptureViewMode { messages, response, raw, metadata }

class StudioPromptCaptureTab extends ConsumerStatefulWidget {
  const StudioPromptCaptureTab({super.key, required this.charId});

  final String charId;

  @override
  ConsumerState<StudioPromptCaptureTab> createState() =>
      _StudioPromptCaptureTabState();
}

class _StudioPromptCaptureTabState
    extends ConsumerState<StudioPromptCaptureTab> {
  int? _selectedId;
  _CaptureViewMode _mode = _CaptureViewMode.messages;

  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(
      chatProvider(widget.charId).select((state) => state.value?.session?.id),
    );
    if (sessionId == null) {
      return Center(child: Text('prompt_inspector_studio_open_chat'.tr()));
    }
    final captures = ref.watch(promptCaptureViewsProvider(sessionId));
    return captures.when(
      loading: () => const Center(child: GlazeSpinner()),
      error: (error, _) => _EmptyState(
        icon: Icons.error_outline,
        text: 'prompt_inspector_studio_load_failed'.tr(
          namedArgs: {'error': '$error'},
        ),
      ),
      data: (items) => _buildContent(context, sessionId, items),
    );
  }

  Widget _buildContent(
    BuildContext context,
    String sessionId,
    List<PromptCaptureView> items,
  ) {
    if (items.isEmpty) {
      return _EmptyState(
        icon: Icons.manage_search,
        text: 'prompt_inspector_studio_empty'.tr(),
        onRefresh: () => ref.invalidate(promptCaptureViewsProvider(sessionId)),
      );
    }
    final selected = items.firstWhere(
      (item) => item.row.id == _selectedId,
      orElse: () => items.first,
    );
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: GlazeDropdownChip(
                      label: _captureLabel(selected),
                      onTap: () => _showCapturePicker(context, items),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'action_refresh'.tr(),
                  onPressed: () =>
                      ref.invalidate(promptCaptureViewsProvider(sessionId)),
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: 'action_copy'.tr(),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _copyText(selected)));
                    GlazeToast.show(context, 'chat_copied'.tr());
                  },
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
          GlazeFilterChipBar<_CaptureViewMode>(
            current: _mode,
            options: _CaptureViewMode.values,
            labelBuilder: (mode) => switch (mode) {
              _CaptureViewMode.messages =>
                'prompt_inspector_studio_messages'.tr(),
              _CaptureViewMode.response =>
                'prompt_inspector_studio_response'.tr(),
              _CaptureViewMode.raw =>
                'prompt_inspector_studio_raw_request'.tr(),
              _CaptureViewMode.metadata =>
                'prompt_inspector_studio_metadata'.tr(),
            },
            onSelected: (mode) => setState(() => _mode = mode),
          ),
          Expanded(child: _buildSelected(context, selected)),
        ],
      ),
    );
  }

  Widget _buildSelected(BuildContext context, PromptCaptureView selected) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (selected.row.truncated)
          _InfoCard(
            text: 'prompt_inspector_studio_truncated'.tr(),
            color: context.cs.tertiary,
          ),
        if (_mode == _CaptureViewMode.messages)
          if (selected.messages.isEmpty)
            _InfoCard(text: 'prompt_inspector_studio_no_messages'.tr())
          else
            for (final message in selected.messages)
              _MessageCard(message: message),
        if (_mode == _CaptureViewMode.raw)
          _CodeCard(text: selected.formattedJson),
        if (_mode == _CaptureViewMode.response)
          _ResponsePanel(capture: selected),
        if (_mode == _CaptureViewMode.metadata) ...[
          _MetadataCard(capture: selected),
          const SizedBox(height: 10),
          _InfoCard(text: 'prompt_inspector_studio_wire_json_note'.tr()),
        ],
      ],
    );
  }

  void _showCapturePicker(BuildContext context, List<PromptCaptureView> items) {
    final selectedId = _selectedId ?? items.first.row.id;
    showGlazePickerSheet(
      context,
      title: 'prompt_inspector_studio_captured_requests'.tr(),
      items: [
        for (final item in items)
          GlazePickerItem(
            label: _captureLabel(item),
            hint:
                '${item.row.protocol ?? 'prompt_inspector_studio_unknown_protocol'.tr()} · '
                '${DateTime.fromMillisecondsSinceEpoch(item.row.createdAtMs).toLocal()}',
            value: item.row.id,
            isActive: item.row.id == selectedId,
            icon: _stageIcon(item.row.stage),
          ),
      ],
      onSelect: (value) => setState(() => _selectedId = value as int),
    );
  }

  String _copyText(PromptCaptureView selected) => switch (_mode) {
    _CaptureViewMode.messages =>
      selected.messages
          .map(
            (message) =>
                '${message['role'] ?? 'unknown'}:\n${message['content'] ?? ''}',
          )
          .join('\n\n'),
    _CaptureViewMode.raw => selected.formattedJson,
    _CaptureViewMode.response => _responseText(selected),
    _CaptureViewMode.metadata => _metadataText(selected),
  };

  static String _captureLabel(PromptCaptureView item) {
    final suffix = item.row.attempt == null
        ? ''
        : ' · ${'prompt_inspector_studio_attempt'.tr(namedArgs: {'attempt': '${item.row.attempt}'})}';
    return '${_stageLabel(item.row.stage)}$suffix';
  }

  static String _metadataText(PromptCaptureView item) => [
    _field(
      'prompt_inspector_studio_field_stage',
      item.row.stage ?? 'unclassified',
    ),
    _field(
      'prompt_inspector_studio_field_model',
      item.request['model'] ?? 'unknown',
    ),
    _field(
      'prompt_inspector_studio_field_protocol',
      item.row.protocol ?? 'unknown',
    ),
    _field(
      'prompt_inspector_studio_field_created',
      DateTime.fromMillisecondsSinceEpoch(item.row.createdAtMs).toLocal(),
    ),
    if (item.row.messageId != null)
      _field('prompt_inspector_studio_field_message', item.row.messageId),
    if (item.row.pipelineRunId != null)
      _field(
        'prompt_inspector_studio_field_pipeline_run',
        item.row.pipelineRunId,
      ),
    if (item.row.callId != null)
      _field('prompt_inspector_studio_field_call', item.row.callId),
    if (item.row.logicalCallId != null)
      _field(
        'prompt_inspector_studio_field_logical_call',
        item.row.logicalCallId,
      ),
    if (item.row.agentId != null)
      _field('prompt_inspector_studio_field_agent', item.row.agentId),
    if (item.row.stageOrdinal != null)
      _field(
        'prompt_inspector_studio_field_stage_ordinal',
        item.row.stageOrdinal,
      ),
    if (item.row.attempt != null)
      _field('prompt_inspector_studio_field_attempt', item.row.attempt),
  ].join('\n');

  static String _responseText(PromptCaptureView item) {
    if (item.callEvents.isEmpty) {
      return 'prompt_inspector_studio_no_outcome'.tr();
    }
    return item.callEvents.map(_callEventText).join('\n\n');
  }

  static String _callEventText(LlmCallEventRow event) => <String>[
    '${event.kind} · ${'prompt_inspector_studio_attempt'.tr(namedArgs: {'attempt': '${event.attempt ?? '-'}'})}',
    if (event.status != null)
      _field('prompt_inspector_studio_field_status', event.status),
    if (event.responseText != null) event.responseText!,
    if (event.error != null)
      _field('prompt_inspector_studio_field_error', event.error),
    if (event.parserName != null)
      _field('prompt_inspector_studio_field_parser', event.parserName),
    if (event.parserCode != null)
      _field('prompt_inspector_studio_field_verdict', event.parserCode),
    if (event.parserDetail != null)
      _field('prompt_inspector_studio_field_detail', event.parserDetail),
  ].join('\n');

  static String _field(String key, Object? value) =>
      key.tr(namedArgs: {'value': '$value'});

  static String _stageLabel(String? stage) => switch (stage) {
    null || '' => 'prompt_inspector_studio_stage_unclassified'.tr(),
    'studio.controller' => 'prompt_inspector_studio_stage_controller'.tr(),
    'studio.post_processing' =>
      'prompt_inspector_studio_stage_post_processor'.tr(),
    'studio.final' => 'prompt_inspector_studio_stage_final_writer'.tr(),
    'cleaner.audit' => 'prompt_inspector_studio_stage_cleaner_audit'.tr(),
    'cleaner.rewrite' => 'prompt_inspector_studio_stage_post_cleaner'.tr(),
    'ledger.turn' => 'prompt_inspector_studio_stage_ledger'.tr(),
    'ledger.turn_repair' => 'prompt_inspector_studio_stage_ledger_repair'.tr(),
    'ledger.reconciliation' =>
      'prompt_inspector_studio_stage_reconciliation'.tr(),
    'ledger.reconciliation_repair' =>
      'prompt_inspector_studio_stage_reconciliation_repair'.tr(),
    'card.collector' => 'prompt_inspector_studio_stage_collector'.tr(),
    'card.history_consolidation' =>
      'prompt_inspector_studio_stage_history_consolidation'.tr(),
    'card.writer' => 'prompt_inspector_studio_stage_card_writer'.tr(),
    'card.writer_repair' =>
      'prompt_inspector_studio_stage_card_writer_repair'.tr(),
    'card.lorebook_writer' =>
      'prompt_inspector_studio_stage_lorebook_writer'.tr(),
    'card.manual_writer' =>
      'prompt_inspector_studio_stage_manual_card_writer'.tr(),
    'summary' => 'prompt_inspector_studio_stage_summary'.tr(),
    _ => stage,
  };

  static IconData _stageIcon(String? stage) {
    if (stage?.startsWith('ledger.') == true) {
      return Icons.account_tree_outlined;
    }
    if (stage?.startsWith('card.') == true) return Icons.auto_fix_high_outlined;
    if (stage?.startsWith('cleaner.') == true) {
      return Icons.cleaning_services_outlined;
    }
    return Icons.data_object_rounded;
  }
}

class _ResponsePanel extends StatelessWidget {
  const _ResponsePanel({required this.capture});

  final PromptCaptureView capture;

  @override
  Widget build(BuildContext context) {
    if (capture.row.callId == null) {
      return _InfoCard(text: 'prompt_inspector_studio_legacy_no_call_id'.tr());
    }
    if (capture.callEvents.isEmpty) {
      return _InfoCard(text: 'prompt_inspector_studio_no_response'.tr());
    }
    return Column(
      children: [
        for (final event in capture.callEvents) ...[
          _CodeCard(text: _StudioPromptCaptureTabState._callEventText(event)),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message});

  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (message['role'] ?? 'unknown').toString().toUpperCase(),
                style: TextStyle(
                  color: context.cs.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText('${message['content'] ?? ''}'),
            ],
          ),
        ),
      ),
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => GlassSurface(
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    ),
  );
}

class _MetadataCard extends StatelessWidget {
  const _MetadataCard({required this.capture});

  final PromptCaptureView capture;

  @override
  Widget build(BuildContext context) =>
      _CodeCard(text: _StudioPromptCaptureTabState._metadataText(capture));
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: GlassSurface(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: (color ?? context.cs.outline).withValues(alpha: 0.3),
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: Text(text)),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text, this.onRefresh});

  final IconData icon;
  final String text;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: context.cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (onRefresh != null) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: Text('action_refresh'.tr()),
            ),
          ],
        ],
      ),
    ),
  );
}
