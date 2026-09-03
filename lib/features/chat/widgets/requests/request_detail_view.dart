import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../services/prompt_capture_view_service.dart';
import '../../state/request_timeline.dart';
import 'request_message_card.dart';
import 'request_stage_label.dart';

enum _DetailMode { messages, params, json }

/// One captured request, opened from the Requests list.
///
/// This is the screen the Requests tab used to be: the exact payload that went
/// out, only for a request that actually happened rather than for the next one
/// that might. The inspector hides its tab strip while it is open, so the body
/// gets the full sheet height.
class RequestDetailView extends StatefulWidget {
  const RequestDetailView({
    super.key,
    required this.capture,
    required this.onBack,
  });

  final PromptCaptureView capture;
  final VoidCallback onBack;

  @override
  State<RequestDetailView> createState() => _RequestDetailViewState();
}

class _RequestDetailViewState extends State<RequestDetailView> {
  _DetailMode _mode = _DetailMode.messages;

  @override
  Widget build(BuildContext context) {
    final capture = widget.capture;
    final family = requestStageFamily(capture.row.stage);
    final color = requestFamilyColor(context, family);
    final title = requestStepLabel(
      stage: capture.row.stage,
      agentId: capture.row.agentId,
    );
    final time = DateTime.fromMillisecondsSinceEpoch(capture.row.createdAtMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
          child: Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                tooltip: 'requests_back_to_list'.tr(),
                onPressed: widget.onBack,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${requestFamilyLabel(family)} · $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                    Text(
                      '${formatRequestTime(time)} · ${capture.messages.length} '
                      '${'requests_messages_short'.tr()}',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_all_rounded, size: 18),
                tooltip: 'action_copy'.tr(),
                onPressed: () => _copy(capture.formattedJson),
              ),
            ],
          ),
        ),
        GlazeFilterChipBar<_DetailMode>(
          current: _mode,
          options: _DetailMode.values.toList(),
          labelBuilder: (mode) => switch (mode) {
            _DetailMode.messages => 'requests_view_messages'.tr(),
            _DetailMode.params => 'requests_view_params'.tr(),
            _DetailMode.json => 'requests_view_json'.tr(),
          },
          onSelected: (mode) => setState(() => _mode = mode),
        ),
        Expanded(
          child: switch (_mode) {
            _DetailMode.messages => _messages(context, capture),
            _DetailMode.params => _params(context, capture),
            _DetailMode.json => _json(context, capture),
          },
        ),
      ],
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    GlazeToast.show(context, 'chat_copied'.tr());
  }

  Widget _messages(BuildContext context, PromptCaptureView capture) {
    final messages = capture.messages;
    if (messages.isEmpty) {
      return _empty(context, 'requests_detail_no_messages'.tr());
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: messages.length,
      itemBuilder: (_, i) => RequestMessageCard(index: i, message: messages[i]),
    );
  }

  Widget _params(BuildContext context, PromptCaptureView capture) {
    final request = capture.request;
    const keys = [
      'model',
      'protocolEndpoint',
      'stream',
      'maxTokens',
      'temperature',
      'topP',
      'topK',
      'frequencyPenalty',
      'presencePenalty',
      'reasoningEffort',
      'requestReasoning',
      'cacheControlTtl',
      'cacheBreakpointMode',
      'toolCount',
      'toolChoice',
    ];
    final rows = <(String, String)>[
      for (final key in keys)
        if (request[key] != null) (key, '${request[key]}'),
      if (capture.row.protocol != null)
        ('protocol', '${capture.row.protocol}'),
      if (capture.row.attempt != null) ('attempt', '${capture.row.attempt}'),
      if (capture.transportOutcome != null)
        ('outcome', capture.transportOutcome!.kind),
      for (final verdict in capture.parserVerdicts)
        (verdict.parserName ?? verdict.kind, verdict.parserCode ?? '—'),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      children: [
        GlassSurface(
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.$1,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            row.$2,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: context.cs.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (capture.row.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'requests_truncated_note'.tr(),
              style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _json(BuildContext context, PromptCaptureView capture) =>
      ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          SelectableText(
            capture.formattedJson,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              fontFamily: 'monospace',
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ],
      );

  Widget _empty(BuildContext context, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 13),
      ),
    ),
  );

}
