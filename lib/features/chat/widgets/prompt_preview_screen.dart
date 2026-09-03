import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'dart:convert';

import '../../../core/llm/converters/prompt_post_processing.dart';
import '../../../core/llm/history_assembler.dart';
import '../../../core/llm/prompt_builder.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../../../core/llm/raw_response_text.dart';
import '../../../core/llm/prompt_worker.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../providers/prompt_build_providers.dart';
import '../../../core/llm/transport/anthropic_chat_transport.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/gemini_chat_transport.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/llm/transport/openai_chat_transport.dart';
import '../../../core/llm/transport/openai_responses_transport.dart';
import '../../../core/llm/transport/openrouter_chat_transport.dart';
import '../../../core/llm/transport/post_processing_chat_transport.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/models/api_config.dart';
import '../services/prompt_preview_post_processor.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../chat_provider.dart';
import '../state/cached_token_breakdown.dart';

@visibleForTesting
List<Map<String, dynamic>> buildPreviewApiMessages(
  List<PromptMessage> messages, {
  int reasoningHistoryCount = 0,
}) => buildApiMessages(messages, reasoningHistoryCount: reasoningHistoryCount);

class PromptPreviewScreen extends ConsumerStatefulWidget {
  final String charId;

  /// When true, render only the body content (no SheetView chrome) for
  /// embedding inside the Prompt Inspector's tabbed shell.
  final bool embedded;

  /// Set when the screen is a drill-down (the Requests tab opens it as "the
  /// request that would go out next"): the embedded toolbar then leads with a
  /// back button instead of relying on a tab strip that is hidden.
  final VoidCallback? onBack;

  const PromptPreviewScreen({
    super.key,
    required this.charId,
    this.embedded = false,
    this.onBack,
  });

  @override
  ConsumerState<PromptPreviewScreen> createState() =>
      _PromptPreviewScreenState();
}

class _PromptPreviewScreenState extends ConsumerState<PromptPreviewScreen> {
  PromptResult? _result;
  ApiConfig? _apiConfig;
  String? _sessionId;
  String? _charName;
  String? _userName;
  Map<String, dynamic>? _requestBody;

  /// The built prompt after the connection's post-processing mode, computed
  /// once per build rather than per frame. Empty until the first prompt lands.
  List<PreviewMessage> _previewMessages = const [];
  bool _loading = true;
  _SectionFilter _filter = _SectionFilter.all;
  int _dataTabIndex = 0;
  int _previewTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    setState(() => _loading = true);

    try {
      final chatState = ref.read(chatProvider(widget.charId)).value;
      final session = chatState?.session;
      if (session == null) {
        setState(() => _loading = false);
        return;
      }

      final builder = ref.read(promptPayloadBuilderProvider);
      final payload = await builder.buildFromSession(
        charId: widget.charId,
        session: session,
      );
      _apiConfig = payload.apiConfig;
      _sessionId = session.id;
      _charName = payload.character.name;
      _userName = payload.persona?.name ?? 'User';

      final result = await buildPromptInIsolate(
        payload,
        priority: PromptWorkerPriority.background,
      );

      ref.read(cachedTokenBreakdownProvider(widget.charId).notifier).state =
          result.breakdown;
      if (mounted) {
        setState(() {
          _result = result;
          _previewMessages = buildPreviewMessages(
            result.messages,
            _apiConfig?.promptPostProcessing ?? PromptPostProcessing.none,
            charName: _charName,
            userName: _userName,
          );
          _requestBody = _buildRequestBody();
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Prompt preview error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider(widget.charId), (prev, next) {
      final prevSession = prev?.value?.session;
      final nextSession = next.value?.session;
      if (prevSession != nextSession && !_loading) {
        _build();
      }
    });
    if (widget.embedded) {
      // The Prompt Inspector injects the floating-header height as the body's
      // top inset. Offset the whole embedded column (toolbar + tab bar) by it,
      // then strip the inset from descendants so _buildBody — which also reads
      // padding.top — doesn't add the gap a second time.
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.onBack == null ? 16 : 4,
                  widget.onBack == null ? 8 : 4,
                  8,
                  4,
                ),
                child: Row(
                  children: [
                    if (widget.onBack != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.arrow_back_rounded, size: 20),
                        tooltip: 'requests_back_to_list'.tr(),
                        onPressed: widget.onBack,
                      ),
                    Text(
                      'magic_request_preview'.tr(),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    if (_previewTabIndex == 1) ...[
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.copy,
                          size: 20,
                          color: context.cs.primary,
                        ),
                        tooltip: 'action_copy'.tr(),
                        onPressed: _copyContent,
                      ),
                      const SizedBox(width: 4),
                    ],
                    _SegmentedToggle(
                      isRaw: _previewTabIndex == 1,
                      onChanged: (isRaw) =>
                          setState(() => _previewTabIndex = isRaw ? 1 : 0),
                    ),
                  ],
                ),
              ),
              GlazeTabBar(
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
                activeIndex: _dataTabIndex,
                onChanged: (i) => setState(() => _dataTabIndex = i),
              ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      );
    }

    return SheetView(
      titleWidget: Row(
        children: [
          Expanded(
            child: Text(
              'magic_request_preview'.tr(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
          ),
          if (_previewTabIndex == 1) ...[
            Material(
              color: Colors.white.withValues(alpha: 0.06),
              shape: const CircleBorder(),
              child: Tooltip(
                message: 'action_copy'.tr(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _copyContent,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Icon(
                        Icons.copy,
                        size: 20,
                        color: context.cs.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          _SegmentedToggle(
            isRaw: _previewTabIndex == 1,
            onChanged: (isRaw) =>
                setState(() => _previewTabIndex = isRaw ? 1 : 0),
          ),
        ],
      ),
      showBack: true,
      onBack: () => Navigator.of(context).maybePop(),
      headerBottom: GlazeTabBar(
        tabs: [
          GlazeTabItem(label: 'tab_request'.tr(), icon: Icons.upload_rounded),
          GlazeTabItem(
            label: 'tab_response'.tr(),
            icon: Icons.download_rounded,
          ),
        ],
        activeIndex: _dataTabIndex,
        onChanged: (i) => setState(() => _dataTabIndex = i),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return SwipeTabSwitcher(
      index: _dataTabIndex,
      length: 2,
      onChanged: (i) => setState(() => _dataTabIndex = i),
      child: TabSlideSwitcher(
        index: _dataTabIndex,
        child: Builder(
          builder: (context) {
            final topPad = MediaQuery.paddingOf(context).top;

            if (_dataTabIndex == 0) {
              if (_loading) {
                return const Center(child: GlazeSpinner());
              }
              if (_result == null) {
                return Center(
                  child: Text(
                    'no_preview_available'.tr(),
                    style: TextStyle(color: context.cs.onSurfaceVariant),
                  ),
                );
              }
              if (_previewTabIndex == 1) {
                return _buildRawView(_getRawPromptJson(), topPad);
              }
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: topPad)),
                  if (_apiConfig != null) ...[
                    SliverToBoxAdapter(
                      child: _SummaryBar(
                        result: _result!,
                        contextSize: _apiConfig!.contextSize,
                        tokenOverride: null,
                        messageCountOverride: _previewMessages.length,
                      ),
                    ),
                    SliverToBoxAdapter(child: _SectionTitle(_protocolLabel)),
                    if (_requestBody != null)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverToBoxAdapter(
                          child: _buildParamsGrid(_requestBody!),
                        ),
                      ),
                  ],
                  SliverToBoxAdapter(
                    child: _SectionTitle(
                      'label_messages_count'.tr(
                        args: ['${_previewMessages.length}'],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GlazeFilterChipBar<_SectionFilter>(
                        current: _filter,
                        options: _SectionFilter.values.toList(),
                        labelBuilder: _labelForFilter,
                        onSelected: (f) => setState(() => _filter = f),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) =>
                            _PromptMessageCard(row: _filteredMessages[i]),
                        childCount: _filteredMessages.length,
                      ),
                    ),
                  ),
                ],
              );
            } else {
              final chatState = ref.watch(chatProvider(widget.charId)).value;
              final raw = chatState?.lastRawResponse;
              if (raw == null || raw.isEmpty) {
                return Center(
                  child: Text(
                    'no_preview_available'.tr(),
                    style: TextStyle(color: context.cs.onSurfaceVariant),
                  ),
                );
              }
              String displayString = raw;
              if (_previewTabIndex == 1) {
                // Raw/code view: pretty-print the full JSON so fields like
                // completion_tokens, usage, etc. are visible and readable.
                try {
                  final decoded = jsonDecode(raw);
                  displayString = const JsonEncoder.withIndent(
                    '  ',
                  ).convert(decoded);
                } catch (_) {}
              } else {
                // Pretty/preview view: just the assistant text, whichever
                // protocol shape the payload came back in. Falls through to
                // the raw JSON when nothing could be extracted.
                displayString = extractAssistantText(raw) ?? raw;
              }
              return _buildRawView(displayString, topPad);
            }
          },
        ),
      ),
    );
  }

  Widget _buildRawView(String text, double topPad) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: topPad + 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(
              text,
              style: TextStyle(
                color: context.cs.onSurface,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders the request parameters straight from the protocol-specific body
  /// so the grid always matches what's actually sent. Bulk message-carrying
  /// keys are skipped; nested config maps (`generationConfig`, `thinking`,
  /// `cache_control`, …) are flattened into individual chips.
  Widget _buildParamsGrid(Map<String, dynamic> body) {
    final items = _paramItemsFromBody(body);
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: items
              .map((w) => SizedBox(width: itemWidth, child: w))
              .toList(),
        );
      },
    );
  }

  /// Keys whose values are bulky message payloads, not tunable parameters —
  /// excluded from the parameter grid (they're shown in the Messages list /
  /// raw view instead).
  static const Set<String> _bulkBodyKeys = {
    'messages',
    'system',
    'contents',
    'systemInstruction',
    'safetySettings',
  };

  List<_ParamItem> _paramItemsFromBody(Map<String, dynamic> body) {
    final items = <_ParamItem>[];

    // Model lives in the URL (not the body) for Gemini, so surface it from the
    // config to keep it visible across every protocol.
    final model = _apiConfig?.model;
    if (model != null && model.isNotEmpty) {
      items.add(_ParamItem(label: 'label_model'.tr(), value: model));
    }

    // Post-processing reshapes the conversation without leaving a trace in the
    // body, so the message list would otherwise be the only hint it ran. Shown
    // only when it is on — every other connection would carry a "None" chip.
    if (_postProcessingMode != PromptPostProcessing.none) {
      final base = PromptPostProcessing.baseOf(_postProcessingMode);
      items.add(
        _ParamItem(
          label: 'section_prompt_post_processing'.tr(),
          value: 'prompt_post_processing_$base'.tr(),
        ),
      );
    }

    void add(String label, dynamic value) {
      if (value is Map) {
        value.forEach((k, v) => add('$label.$k', v));
      } else if (value is List) {
        // Lists here are nested structures (e.g. cache_control breakpoints);
        // not meaningful as a single chip — skip.
      } else {
        items.add(_ParamItem(label: label, value: '$value'));
      }
    }

    body.forEach((key, value) {
      if (_bulkBodyKeys.contains(key) || key == 'model') return;
      // Hoist Gemini's generationConfig children to top-level chips.
      if (key == 'generationConfig' && value is Map) {
        value.forEach((k, v) => add('$k', v));
      } else {
        add(key, value);
      }
    });

    return items;
  }

  /// Section filters read the post-processed message: a merged row carries the
  /// union of its sources' flags, so it still shows up under `history` or
  /// `lorebook` when one of the blocks folded into it was of that kind.
  List<PreviewMessage> get _filteredMessages {
    final rows = _previewMessages;
    return switch (_filter) {
      _SectionFilter.all => rows,
      _SectionFilter.system =>
        rows
            .where(
              (r) =>
                  r.message.role == 'system' &&
                  !r.message.isHistory &&
                  !r.message.isLorebook,
            )
            .toList(),
      _SectionFilter.lorebook =>
        rows.where((r) => r.message.isLorebook).toList(),
      _SectionFilter.history => rows.where((r) => r.message.isHistory).toList(),
      _SectionFilter.depth => rows.where((r) => r.message.isDepth).toList(),
    };
  }

  void _copyContent() {
    String textToCopy = '';
    if (_dataTabIndex == 0) {
      if (_previewTabIndex == 0) {
        if (_result == null) return;
        final json = _previewMessages.map((row) {
          final m = row.message;
          final map = <String, dynamic>{'role': m.role, 'content': m.content};
          if (m.isLorebook) map['lorebook'] = true;
          if (m.blockName != null) map['block'] = m.blockName;
          if (m.isDepth) map['depth'] = m.depth;
          return map;
        }).toList();
        textToCopy = jsonEncode(json);
      } else {
        textToCopy = _getRawPromptJson();
      }
    } else {
      final chatState = ref.read(chatProvider(widget.charId)).value;
      final raw = chatState?.lastRawResponse ?? '';
      if (_previewTabIndex == 1) {
        // Raw view: copy pretty-printed full JSON.
        try {
          final decoded = jsonDecode(raw);
          textToCopy = const JsonEncoder.withIndent('  ').convert(decoded);
        } catch (_) {
          textToCopy = raw;
        }
      } else {
        // Pretty view: copy just the assistant text — same extraction the
        // view uses, so what's copied matches what's on screen.
        textToCopy = extractAssistantText(raw) ?? raw;
      }
    }

    if (textToCopy.isEmpty) return;
    Clipboard.setData(ClipboardData(text: textToCopy));
    GlazeToast.show(context, 'chat_copied'.tr());
  }

  /// Builds the actual on-the-wire request body for the configured protocol by
  /// delegating to the same transport builders the live generation path uses
  /// (see `stream_generation_service.dart`). This keeps the preview faithful
  /// for Anthropic (`system` blocks, `thinking`), Gemini (`contents` /
  /// `generationConfig` / `safetySettings`) and OpenRouter (cache markers),
  /// instead of always emitting an OpenAI-shaped body. Returns `null` when the
  /// prompt/config isn't ready or building throws.
  Map<String, dynamic>? _buildRequestBody() {
    if (_result == null || _apiConfig == null) return null;
    try {
      final cfg = _apiConfig!;
      final apiMessages = buildPreviewApiMessages(
        _result!.messages,
        reasoningHistoryCount: cfg.reasoningHistoryCount,
      );

      // The live path applies post-processing in the transport decorator; the
      // preview builds bodies directly, so it applies the same pass itself —
      // otherwise the preview would show an unmerged prompt.
      final request = PostProcessingChatTransport.applyTo(
        ChatTransportRequest.fromApiConfig(
          cfg,
          messages: apiMessages,
          sessionId: _sessionId,
          charName: _charName,
          userName: _userName,
        ),
      );

      return switch (cfg.protocol) {
        LlmProtocol.anthropic => AnthropicChatTransport.buildRequest(
          request,
        ).body,
        LlmProtocol.gemini => GeminiChatTransport.buildRequest(request).body,
        LlmProtocol.openrouter => OpenAiChatTransport.buildBody(
          OpenRouterChatTransport.buildRouterRequest(request),
          protocol: LlmProtocol.openrouter,
        ),
        LlmProtocol.openaiResponses => OpenAiResponsesTransport.buildBody(
          request,
        ),
        LlmProtocol.openai => OpenAiChatTransport.buildBody(
          request,
          protocol: LlmProtocol.openai,
        ),
        LlmProtocol.customChatCompletion =>
          cfg.useResponsesApi
              ? OpenAiResponsesTransport.buildBody(request)
              : OpenAiChatTransport.buildBody(
                  request,
                  protocol: LlmProtocol.customChatCompletion,
                ),
        _ => OpenAiChatTransport.buildBody(
          request,
          protocol: LlmProtocol.customChatCompletion,
        ),
      };
    } catch (_) {
      return null;
    }
  }

  String _getRawPromptJson() {
    final body = _requestBody;
    if (body == null) return '';
    return const JsonEncoder.withIndent('  ').convert(body);
  }

  /// The connection's post-processing mode, normalized the same way the
  /// transport decorator normalizes it.
  String get _postProcessingMode =>
      PromptPostProcessing.normalize(_apiConfig?.promptPostProcessing);

  /// Human-readable name of the active protocol, used as the parameters
  /// section header.
  String get _protocolLabel {
    final protocol = _apiConfig?.protocol;
    if (protocol == null) return 'label_generation_params'.tr();
    return LlmProtocol.labels[protocol] ?? protocol;
  }
}

class _SummaryBar extends StatelessWidget {
  final PromptResult result;
  final int contextSize;
  final int? tokenOverride;
  final int? messageCountOverride;
  const _SummaryBar({
    required this.result,
    required this.contextSize,
    this.tokenOverride,
    this.messageCountOverride,
  });

  @override
  Widget build(BuildContext context) {
    final total = tokenOverride ?? result.breakdown.totalTokens;
    final pct = contextSize > 0
        ? (total / contextSize * 100).clamp(0, 100)
        : 0.0;
    final barColor = pct > 90
        ? Colors.red
        : pct > 75
        ? Colors.orange
        : Colors.green;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$total',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: barColor,
                ),
              ),
              Text(
                ' / $contextSize tokens',
                style: TextStyle(
                  fontSize: 14,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: barColor,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${messageCountOverride ?? result.messages.length} msgs',
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct / 100,
              backgroundColor: Colors.white10,
              color: barColor,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}

enum _SectionFilter { all, system, lorebook, history, depth }

String _labelForFilter(_SectionFilter f) => switch (f) {
  _SectionFilter.all => 'filter_all'.tr(),
  _SectionFilter.system => 'role_system'.tr(),
  _SectionFilter.lorebook => 'filter_lorebook'.tr(),
  _SectionFilter.history => 'filter_history'.tr(),
  _SectionFilter.depth => 'label_depth'.tr(),
};

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10, left: 16, right: 16),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ParamItem extends StatelessWidget {
  final String label;
  final String value;
  const _ParamItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              color: context.cs.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: context.cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _PromptMessageCard extends StatefulWidget {
  final PreviewMessage row;
  const _PromptMessageCard({required this.row});

  @override
  State<_PromptMessageCard> createState() => _PromptMessageCardState();
}

class _PromptMessageCardState extends State<_PromptMessageCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.row.message;
    final images = widget.row.imagePaths;
    final tokenCount = estimateTokens(msg.content);

    return Card(
      color: Colors.white.withValues(alpha: 0.05),
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildRoleChip(msg.role),
                  if (widget.row.isMerged) ...[
                    const SizedBox(width: 4),
                    _MergedBadge(count: widget.row.sources.length),
                  ],
                  if (msg.blockName != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        msg.blockName!,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: context.cs.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    '$tokenCount t',
                    style: TextStyle(
                      fontSize: 10,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                  if (msg.isDepth && msg.depth != null) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'd${msg.depth}',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.orange,
                        ),
                      ),
                    ),
                  ],
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: context.cs.onSurfaceVariant,
                  ),
                ],
              ),
              if (!_expanded && msg.content.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  msg.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.cs.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ],
              // A merge can pull several attachments into one message, so every
              // source image is listed rather than just the first.
              if (!_expanded)
                for (final path in images) ...[
                  const SizedBox(height: 8),
                  PromptAttachmentPreview(imagePath: path),
                ],
              if (_expanded) ...[
                const SizedBox(height: 8),
                for (final path in images) ...[
                  PromptAttachmentPreview(imagePath: path, expanded: true),
                  const SizedBox(height: 8),
                ],
                if (msg.content.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: SingleChildScrollView(
                      child: PromptMarkdownPreview(content: msg.content),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoleChip(String role) {
    Color bg = const Color(0xFF424242);
    Color fg = const Color(0xFFE0E0E0);
    if (role == 'system') {
      bg = const Color(0xFF1565C0);
      fg = const Color(0xFFE3F2FD);
    } else if (role == 'user') {
      bg = const Color(0xFF7B1FA2);
      fg = const Color(0xFFF3E5F5);
    } else if (role == 'assistant') {
      bg = const Color(0xFF2E7D32);
      fg = const Color(0xFFE8F5E9);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        role.toUpperCase(),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// How many built blocks post-processing folded into this one message.
/// Without it a merged card reads as one oversized block and nothing on screen
/// says the connection reshaped the prompt.
class _MergedBadge extends StatelessWidget {
  final int count;
  const _MergedBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'prompt_preview_merged_blocks'.tr(args: ['$count']),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.merge_rounded, size: 11, color: context.cs.primary),
            const SizedBox(width: 2),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: context.cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
class PromptMarkdownPreview extends StatelessWidget {
  final String content;

  const PromptMarkdownPreview({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      content,
      style: TextStyle(fontSize: 12, color: context.cs.onSurface),
      imageBuilder: (context, url, width, height) {
        final uri = Uri.tryParse(url);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          return const Icon(
            Icons.broken_image_outlined,
            key: ValueKey('prompt-markdown-image-unavailable'),
          );
        }
        return Image.network(
          url,
          key: const ValueKey('prompt-markdown-image'),
          width: width,
          height: height,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        );
      },
    );
  }
}

@visibleForTesting
class PromptAttachmentPreview extends StatefulWidget {
  final String imagePath;
  final bool expanded;

  const PromptAttachmentPreview({
    super.key,
    required this.imagePath,
    this.expanded = false,
  });

  @override
  State<PromptAttachmentPreview> createState() =>
      _PromptAttachmentPreviewState();
}

class _PromptAttachmentPreviewState extends State<PromptAttachmentPreview> {
  static const _maxEncodedLength = 8 * 1024 * 1024;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(PromptAttachmentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imagePath != oldWidget.imagePath) _decode();
  }

  void _decode() {
    final match = RegExp(
      r'^data:image/(?:png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=]+)$',
      caseSensitive: false,
    ).firstMatch(widget.imagePath);
    final encoded = match?.group(1);
    if (encoded == null || encoded.length > _maxEncodedLength) {
      _bytes = null;
      return;
    }
    try {
      _bytes = base64Decode(encoded);
    } on FormatException {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null || bytes.isEmpty) {
      return Container(
        key: const ValueKey('prompt-attachment-unavailable'),
        height: 56,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.broken_image_outlined,
          color: context.cs.onSurfaceVariant,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        bytes,
        key: const ValueKey('prompt-attachment-image'),
        width: double.infinity,
        height: widget.expanded ? 220 : 96,
        cacheWidth: widget.expanded ? 1024 : 480,
        cacheHeight: widget.expanded ? 640 : 288,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Container(
          key: const ValueKey('prompt-attachment-unavailable'),
          height: 56,
          alignment: Alignment.center,
          color: Colors.white.withValues(alpha: 0.04),
          child: Icon(
            Icons.broken_image_outlined,
            color: context.cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _SegmentedToggle extends StatelessWidget {
  final bool isRaw;
  final ValueChanged<bool> onChanged;

  const _SegmentedToggle({required this.isRaw, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!isRaw),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              left: isRaw ? 32 : 0,
              top: 0,
              bottom: 0,
              width: 32,
              child: Container(
                decoration: BoxDecoration(
                  color: context.cs.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 32,
                  child: Center(
                    child: Icon(
                      Icons.visibility,
                      size: 16,
                      color: !isRaw
                          ? Colors.white
                          : context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Center(
                    child: Icon(
                      Icons.code,
                      size: 16,
                      color: isRaw ? Colors.white : context.cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
