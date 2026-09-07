import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/raw_response_text.dart';
import '../../../../core/llm/tokenizer.dart';
import '../../../../core/llm/transport/llm_protocol.dart';
import '../../../../features/settings/api_list_provider.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_tab_bar.dart';
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
/// Its second tab is what came back. The response view used to hang off the
/// *next* request instead, where it could only ever show the last run's reply —
/// a preview of a request that has not been sent has no response of its own.
/// Here it is the response of the request you are actually looking at, read
/// from the call events that request recorded.
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

  /// 0 = what was sent, 1 = what came back.
  int _tab = 0;

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
              onPressed: () => _copy(_copyText(capture)),
            ),
            const SizedBox(width: 4),
            InspectorViewToggle(
              isRaw: _raw,
              onChanged: (raw) => setState(() => _raw = raw),
            ),
          ],
        ),
        // Same 12 px gutter the body's plaques sit in.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GlazeTabBar(
            tabs: [
              GlazeTabItem(
                label: 'tab_request'.tr(),
                icon: Icons.upload_rounded,
              ),
              GlazeTabItem(
                label: 'tab_response'.tr(),
                icon: Icons.download_rounded,
              ),
            ],
            activeIndex: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
        ),
        Expanded(
          child: _tab == 1
              ? _response(context, capture)
              : _raw
              ? _text(context, capture.formattedJson)
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
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    GlazeToast.show(context, 'chat_copied'.tr());
  }

  /// Whatever the open tab is showing, in the shape it is showing it.
  String _copyText(PromptCaptureView capture) =>
      _tab == 1 ? _responseText(capture) : capture.formattedJson;

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

  /// What came back for this request: the assistant's text in the pretty view,
  /// the whole payload (usage, finish reason, reasoning) in the raw one.
  Widget _response(BuildContext context, PromptCaptureView capture) {
    final text = _responseText(capture);
    if (text.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'requests_response_none'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
          ),
        ),
      );
    }
    return _text(context, text);
  }

  String _responseText(PromptCaptureView capture) {
    final raw = capture.responseText ?? '';
    if (raw.isEmpty) return capture.responseError ?? '';
    if (!_raw) return extractAssistantText(raw) ?? raw;
    // Raw view: pretty-print the payload so usage and finish reasons are
    // readable. A body that is not JSON (an error page, a stream aggregate)
    // stays as it came.
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  Widget _text(BuildContext context, String text) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
    children: [
      SelectableText(
        text,
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
