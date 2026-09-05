import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/tokenizer.dart';
import '../../../../core/llm/transport/llm_protocol.dart';
import '../../../../features/settings/api_list_provider.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../services/prompt_capture_view_service.dart';
import '../../state/request_timeline.dart';
import 'inspector_message.dart';
import 'request_stage_label.dart';
import 'inspector_toolbar.dart';
import 'request_body_view.dart';
import 'request_coverage_block.dart';

/// One captured request, opened from the Requests list.
///
/// It wears the Request Preview's layout — budget bar, parameters, coverage,
/// then the messages behind a filter bar — because it answers the same question
/// about a request that already happened. The two used to be different screens,
/// which made one feature look like two.
///
/// The inspector hides its tab strip while this is open, so the body gets the
/// full sheet height.
class RequestDetailView extends ConsumerStatefulWidget {
  const RequestDetailView({
    super.key,
    required this.charId,
    required this.capture,
    required this.onBack,
  });

  final String charId;
  final PromptCaptureView capture;
  final VoidCallback onBack;

  @override
  ConsumerState<RequestDetailView> createState() => _RequestDetailViewState();
}

class _RequestDetailViewState extends ConsumerState<RequestDetailView> {
  bool _raw = false;

  /// Parameters worth a tile, in the order a request is read: what model, over
  /// what protocol, with what limits — then how the call actually went.
  static const _paramKeys = [
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
    final messages = [
      for (final message in capture.messages)
        InspectorMessage.fromCapture(message),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InspectorToolbar(
          title: '${requestFamilyLabel(family)} · $title',
          subtitle:
              '${formatRequestTime(time)} · ${capture.messages.length} '
              '${'requests_messages_short'.tr()}',
          titleColor: color,
          onBack: widget.onBack,
          actions: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.copy, size: 20, color: context.cs.primary),
              tooltip: 'action_copy'.tr(),
              onPressed: () => _copy(capture.formattedJson),
            ),
            const SizedBox(width: 4),
            InspectorViewToggle(
              isRaw: _raw,
              onChanged: (raw) => setState(() => _raw = raw),
            ),
          ],
        ),
        Expanded(
          child: _raw
              ? _json(context, capture)
              : RequestBodyView(
                  tokens: _tokens(messages),
                  contextSize: _contextSize(),
                  paramsTitle: _protocolLabel(capture),
                  params: _params(capture),
                  messages: messages,
                  // A record, not a rendering: the capture shows what went out
                  // verbatim rather than markdown-formatting it.
                  renderMarkdown: false,
                  coverage: RequestCoverageBlock(
                    charId: widget.charId,
                    messageId: capture.row.messageId,
                  ),
                  footer: capture.row.truncated
                      ? Text(
                          'requests_truncated_note'.tr(),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.cs.onSurfaceVariant,
                          ),
                        )
                      : null,
                ),
        ),
      ],
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    GlazeToast.show(context, 'chat_copied'.tr());
  }

  int _tokens(List<InspectorMessage> messages) => messages.fold(
    0,
    (total, message) => total + estimateTokens(message.content),
  );

  /// The window the request had to fit into. The capture does not record it, so
  /// it comes from the connection that is active now — and when there is none,
  /// 0 drops the meter rather than measuring against a guess.
  int _contextSize() => ref.watch(activeApiConfigProvider)?.contextSize ?? 0;

  String _protocolLabel(PromptCaptureView capture) {
    final protocol = capture.row.protocol ?? '';
    if (protocol.isEmpty) return 'label_generation_params'.tr();
    return LlmProtocol.labels[protocol] ?? protocol;
  }

  List<InspectorParam> _params(PromptCaptureView capture) {
    final request = capture.request;
    return [
      for (final key in _paramKeys)
        if (request[key] != null)
          InspectorParam(label: key, value: '${request[key]}'),
      if (capture.row.protocol != null)
        InspectorParam(label: 'protocol', value: '${capture.row.protocol}'),
      if (capture.row.attempt != null)
        InspectorParam(label: 'attempt', value: '${capture.row.attempt}'),
      if (capture.transportOutcome != null)
        InspectorParam(label: 'outcome', value: capture.transportOutcome!.kind),
      for (final verdict in capture.parserVerdicts)
        InspectorParam(
          label: verdict.parserName ?? verdict.kind,
          value: verdict.parserCode ?? '—',
        ),
    ];
  }

  Widget _json(BuildContext context, PromptCaptureView capture) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
}
