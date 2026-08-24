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
import '../services/prompt_capture_view_service.dart';

enum _CaptureViewMode { messages, raw, metadata }

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
      return const Center(
        child: Text('Open a chat to inspect Studio requests.'),
      );
    }
    final captures = ref.watch(promptCaptureViewsProvider(sessionId));
    return captures.when(
      loading: () => const Center(child: GlazeSpinner()),
      error: (error, _) => _EmptyState(
        icon: Icons.error_outline,
        text: 'Could not load request captures: $error',
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
        text:
            'No captured Studio requests yet. Run a Studio generation, '
            'Ledger reconciliation, Collector, or Card Rewriter.',
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
                  tooltip: 'Refresh',
                  onPressed: () =>
                      ref.invalidate(promptCaptureViewsProvider(sessionId)),
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: 'Copy',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _copyText(selected)));
                    GlazeToast.show(context, 'Copied');
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
              _CaptureViewMode.messages => 'Messages',
              _CaptureViewMode.raw => 'Raw request',
              _CaptureViewMode.metadata => 'Metadata',
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
            text: 'This capture was truncated before storage.',
            color: context.cs.tertiary,
          ),
        if (_mode == _CaptureViewMode.messages)
          if (selected.messages.isEmpty)
            const _InfoCard(text: 'No message payload is available.')
          else
            for (final message in selected.messages)
              _MessageCard(message: message),
        if (_mode == _CaptureViewMode.raw)
          _CodeCard(text: selected.formattedJson),
        if (_mode == _CaptureViewMode.metadata) ...[
          _MetadataCard(capture: selected),
          const SizedBox(height: 10),
          const _InfoCard(
            text:
                'Wire JSON is not captured yet. This is the sanitized, '
                'post-processed transport request observed before protocol encoding.',
          ),
        ],
      ],
    );
  }

  void _showCapturePicker(BuildContext context, List<PromptCaptureView> items) {
    final selectedId = _selectedId ?? items.first.row.id;
    showGlazePickerSheet(
      context,
      title: 'Captured requests',
      items: [
        for (final item in items)
          GlazePickerItem(
            label: _captureLabel(item),
            hint:
                '${item.row.protocol ?? 'unknown protocol'} · '
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
    _CaptureViewMode.metadata => _metadataText(selected),
  };

  static String _captureLabel(PromptCaptureView item) {
    final suffix = item.row.attempt == null
        ? ''
        : ' · attempt ${item.row.attempt}';
    return '${item.label}$suffix';
  }

  static String _metadataText(PromptCaptureView item) => [
    'Stage: ${item.row.stage ?? 'unclassified'}',
    'Model: ${item.request['model'] ?? 'unknown'}',
    'Protocol: ${item.row.protocol ?? 'unknown'}',
    'Created: ${DateTime.fromMillisecondsSinceEpoch(item.row.createdAtMs).toLocal()}',
    if (item.row.messageId != null) 'Message: ${item.row.messageId}',
    if (item.row.pipelineRunId != null)
      'Pipeline run: ${item.row.pipelineRunId}',
    if (item.row.logicalCallId != null)
      'Logical call: ${item.row.logicalCallId}',
    if (item.row.agentId != null) 'Agent: ${item.row.agentId}',
    if (item.row.stageOrdinal != null)
      'Stage ordinal: ${item.row.stageOrdinal}',
    if (item.row.attempt != null) 'Attempt: ${item.row.attempt}',
  ].join('\n');

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
              label: const Text('Refresh'),
            ),
          ],
        ],
      ),
    ),
  );
}
