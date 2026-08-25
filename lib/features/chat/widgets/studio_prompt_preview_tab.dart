import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/list_controls.dart';
import '../chat_provider.dart';
import '../services/studio_prompt_preview_service.dart';

enum _PreviewViewMode { messages, raw, metadata }

/// Kept under its original class name so callers outside Prompt Inspector do
/// not break. The content is a live, read-only Studio prompt catalog.
class StudioPromptPreviewTab extends ConsumerStatefulWidget {
  const StudioPromptPreviewTab({super.key, required this.charId});

  final String charId;

  @override
  ConsumerState<StudioPromptPreviewTab> createState() =>
      _StudioPromptPreviewTabState();
}

class _StudioPromptPreviewTabState
    extends ConsumerState<StudioPromptPreviewTab> {
  String? _selectedId;
  _PreviewViewMode _mode = _PreviewViewMode.messages;

  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(
      chatProvider(widget.charId).select((state) => state.value?.session?.id),
    );
    if (sessionId == null) {
      return Center(child: Text('prompt_inspector_studio_open_chat'.tr()));
    }
    final catalog = ref.watch(
      studioPromptPreviewCatalogProvider(widget.charId),
    );
    return catalog.when(
      loading: () => const Center(child: GlazeSpinner()),
      error: (error, _) => _EmptyState(
        icon: Icons.error_outline,
        text: 'prompt_inspector_studio_load_failed'.tr(
          namedArgs: {'error': '$error'},
        ),
        onRefresh: _refresh,
      ),
      data: (value) => _buildContent(context, value),
    );
  }

  Widget _buildContent(
    BuildContext context,
    StudioPromptPreviewCatalog catalog,
  ) {
    if (catalog.entries.isEmpty) {
      return _EmptyState(
        icon: Icons.manage_search,
        text: 'prompt_inspector_studio_empty'.tr(),
        onRefresh: _refresh,
      );
    }
    final selected = catalog.entries.firstWhere(
      (entry) => entry.id == _selectedId,
      orElse: () => catalog.entries.first,
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
                      label: _entryLabel(selected),
                      onTap: () => _showStagePicker(context, catalog.entries),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'action_refresh'.tr(),
                  onPressed: _refresh,
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
          GlazeFilterChipBar<_PreviewViewMode>(
            current: _mode,
            options: _PreviewViewMode.values,
            labelBuilder: (mode) => switch (mode) {
              _PreviewViewMode.messages =>
                'prompt_inspector_studio_messages'.tr(),
              _PreviewViewMode.raw =>
                'prompt_inspector_studio_raw_request'.tr(),
              _PreviewViewMode.metadata =>
                'prompt_inspector_studio_metadata'.tr(),
            },
            onSelected: (mode) => setState(() => _mode = mode),
          ),
          Expanded(child: _buildSelected(selected)),
        ],
      ),
    );
  }

  Widget _buildSelected(StudioPromptPreviewEntry selected) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _InfoCard(
          text: selected.isFuture
              ? 'prompt_inspector_studio_future'.tr()
              : 'prompt_inspector_studio_current'.tr(),
          color: selected.isFuture ? context.cs.tertiary : context.cs.primary,
        ),
        if (!selected.isAvailable)
          _InfoCard(
            text: _unavailableText(selected.unavailableReason!),
            color: context.cs.tertiary,
          )
        else if (_mode == _PreviewViewMode.messages)
          if (selected.messages.isEmpty)
            _InfoCard(text: 'prompt_inspector_studio_no_messages'.tr())
          else
            for (final message in selected.messages)
              _MessageCard(message: message),
        if (_mode == _PreviewViewMode.raw && selected.isAvailable) ...[
          _InfoCard(text: 'prompt_inspector_studio_pre_protocol_note'.tr()),
          _CodeCard(text: selected.formattedRawRequest),
        ],
        if (_mode == _PreviewViewMode.metadata)
          _CodeCard(text: _metadataText(selected)),
      ],
    );
  }

  void _showStagePicker(
    BuildContext context,
    List<StudioPromptPreviewEntry> entries,
  ) {
    final selectedId = _selectedId ?? entries.first.id;
    showGlazePickerSheet(
      context,
      title: 'prompt_inspector_studio_stages'.tr(),
      items: [
        for (final entry in entries)
          GlazePickerItem(
            label: _entryLabel(entry),
            hint: entry.isAvailable
                ? 'prompt_inspector_studio_available'.tr()
                : _unavailableText(entry.unavailableReason!),
            value: entry.id,
            isActive: entry.id == selectedId,
            icon: _stageIcon(entry.stage),
          ),
      ],
      onSelect: (value) => setState(() => _selectedId = value as String),
    );
  }

  void _refresh() {
    ref.invalidate(studioPromptPreviewCatalogProvider(widget.charId));
  }

  String _copyText(StudioPromptPreviewEntry selected) => switch (_mode) {
    _PreviewViewMode.messages =>
      selected.isAvailable
          ? selected.messages
                .map(
                  (message) =>
                      '${message['role'] ?? 'unknown'}:\n${_contentText(message['content'])}',
                )
                .join('\n\n')
          : _unavailableText(selected.unavailableReason!),
    _PreviewViewMode.raw =>
      selected.isAvailable
          ? selected.formattedRawRequest
          : _unavailableText(selected.unavailableReason!),
    _PreviewViewMode.metadata => _metadataText(selected),
  };

  static String _contentText(dynamic content) => content is String
      ? content
      : const JsonEncoder.withIndent('  ').convert(content);

  static String _entryLabel(StudioPromptPreviewEntry entry) {
    final stage = _stageLabel(entry.stage);
    return entry.stage == StudioPromptPreviewStage.controller ||
            entry.stage == StudioPromptPreviewStage.controllerBatch ||
            entry.stage == StudioPromptPreviewStage.postProcessor
        ? '$stage · ${entry.title}'
        : stage;
  }

  static String _metadataText(StudioPromptPreviewEntry entry) => [
    ...entry.metadata.entries.map((item) => '${item.key}: ${item.value}'),
    'availability: ${entry.isAvailable ? 'available' : 'unavailable'}',
    if (!entry.isAvailable)
      'reason: ${_unavailableText(entry.unavailableReason!)}',
  ].join('\n');

  static String _unavailableText(StudioPromptPreviewUnavailableReason reason) =>
      switch (reason) {
        StudioPromptPreviewUnavailableReason.studioInactive =>
          'prompt_inspector_studio_unavailable_inactive'.tr(),
        StudioPromptPreviewUnavailableReason.noTransportRequest =>
          'prompt_inspector_studio_unavailable_no_request'.tr(),
        StudioPromptPreviewUnavailableReason.controllerOutputsRequired =>
          'prompt_inspector_studio_unavailable_controller_outputs'.tr(),
        StudioPromptPreviewUnavailableReason.finalResponseRequired =>
          'prompt_inspector_studio_unavailable_final_response'.tr(),
        StudioPromptPreviewUnavailableReason.auditOutputRequired =>
          'prompt_inspector_studio_unavailable_audit_output'.tr(),
        StudioPromptPreviewUnavailableReason.malformedOutputRequired =>
          'prompt_inspector_studio_unavailable_malformed_output'.tr(),
        StudioPromptPreviewUnavailableReason.pureBuilderUnavailable =>
          'prompt_inspector_studio_unavailable_pure_builder'.tr(),
        StudioPromptPreviewUnavailableReason.claimSafeSelectionRequired =>
          'prompt_inspector_studio_unavailable_claim_selection'.tr(),
        StudioPromptPreviewUnavailableReason.upstreamOutputRequired =>
          'prompt_inspector_studio_unavailable_upstream_output'.tr(),
        StudioPromptPreviewUnavailableReason.configurationUnavailable =>
          'prompt_inspector_studio_unavailable_configuration'.tr(),
      };

  static String _stageLabel(StudioPromptPreviewStage stage) => switch (stage) {
    StudioPromptPreviewStage.controller =>
      'prompt_inspector_studio_stage_controller'.tr(),
    StudioPromptPreviewStage.controllerBatch =>
      'prompt_inspector_studio_stage_controller_batch'.tr(),
    StudioPromptPreviewStage.finalWriter =>
      'prompt_inspector_studio_stage_final_writer'.tr(),
    StudioPromptPreviewStage.postProcessor =>
      'prompt_inspector_studio_stage_post_processor'.tr(),
    StudioPromptPreviewStage.cleanerAudit =>
      'prompt_inspector_studio_stage_cleaner_audit'.tr(),
    StudioPromptPreviewStage.cleanerRewrite =>
      'prompt_inspector_studio_stage_post_cleaner'.tr(),
    StudioPromptPreviewStage.ledgerTurn =>
      'prompt_inspector_studio_stage_ledger'.tr(),
    StudioPromptPreviewStage.ledgerRepair =>
      'prompt_inspector_studio_stage_ledger_repair'.tr(),
    StudioPromptPreviewStage.reconciliation =>
      'prompt_inspector_studio_stage_reconciliation'.tr(),
    StudioPromptPreviewStage.reconciliationRepair =>
      'prompt_inspector_studio_stage_reconciliation_repair'.tr(),
    StudioPromptPreviewStage.collector =>
      'prompt_inspector_studio_stage_collector'.tr(),
    StudioPromptPreviewStage.consolidation =>
      'prompt_inspector_studio_stage_history_consolidation'.tr(),
    StudioPromptPreviewStage.cardWriter =>
      'prompt_inspector_studio_stage_card_writer'.tr(),
    StudioPromptPreviewStage.cardWriterRepair =>
      'prompt_inspector_studio_stage_card_writer_repair'.tr(),
    StudioPromptPreviewStage.lorebookWriter =>
      'prompt_inspector_studio_stage_lorebook_writer'.tr(),
  };

  static IconData _stageIcon(StudioPromptPreviewStage stage) {
    if (stage.name.startsWith('ledger') ||
        stage == StudioPromptPreviewStage.reconciliation ||
        stage == StudioPromptPreviewStage.reconciliationRepair) {
      return Icons.account_tree_outlined;
    }
    if (stage == StudioPromptPreviewStage.collector ||
        stage == StudioPromptPreviewStage.consolidation ||
        stage == StudioPromptPreviewStage.cardWriter ||
        stage == StudioPromptPreviewStage.cardWriterRepair ||
        stage == StudioPromptPreviewStage.lorebookWriter) {
      return Icons.auto_fix_high_outlined;
    }
    if (stage == StudioPromptPreviewStage.cleanerAudit ||
        stage == StudioPromptPreviewStage.cleanerRewrite) {
      return Icons.cleaning_services_outlined;
    }
    return Icons.data_object_rounded;
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message});

  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) => Padding(
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
            SelectableText(
              _StudioPromptPreviewTabState._contentText(message['content']),
            ),
          ],
        ),
      ),
    ),
  );
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
