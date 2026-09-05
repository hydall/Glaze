import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../../core/models/api_config.dart';
import '../services/prompt_preview_post_processor.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../settings/api_list_provider.dart';
import '../chat_provider.dart';
import '../state/cached_token_breakdown.dart';
import 'requests/inspector_message.dart';
import 'requests/inspector_toolbar.dart';
import 'requests/next_turn_coverage_block.dart';
import 'requests/request_body_view.dart';

/// The markdown and attachment renderers moved next to the rest of the
/// inspector's message chrome, where a captured request reaches them too. Kept
/// visible from here because this is the file they were named after.
export 'requests/prompt_attachment_preview.dart'
    show PromptAttachmentPreview, PromptMarkdownPreview;

@visibleForTesting
List<Map<String, dynamic>> buildPreviewApiMessages(
  List<PromptMessage> messages, {
  int reasoningHistoryCount = 0,
}) => buildApiMessages(messages, reasoningHistoryCount: reasoningHistoryCount);

/// The request that would go out next, built for real and rendered the way the
/// inspector renders every request: budget bar, parameters, coverage, messages.
///
/// There is only one of these in the Requests timeline. Coverage of the next
/// turn used to be a second row beside it, which put the same request on screen
/// twice; it is now the [NextTurnCoverageBlock] between the parameters and the
/// messages — the slot a captured request keeps its own coverage in.
class PromptPreviewScreen extends ConsumerStatefulWidget {
  final String charId;

  /// When true, render only the body content (no SheetView chrome) for
  /// embedding inside the Prompt Inspector's tabbed shell.
  final bool embedded;

  /// Set when the screen is a drill-down (the Requests tab opens it as "the
  /// request that would go out next"): the embedded toolbar then leads with a
  /// back button instead of relying on a tab strip that is hidden.
  final VoidCallback? onBack;

  /// Opens with the coverage block unfolded — where the context card under the
  /// chat header deep-links to.
  final bool coverageExpanded;

  const PromptPreviewScreen({
    super.key,
    required this.charId,
    this.embedded = false,
    this.onBack,
    this.coverageExpanded = false,
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

  /// The same rows in the shape the shared request body renders, mapped once
  /// per prompt build rather than once per frame.
  List<InspectorMessage> _messages = const [];

  bool _loading = true;
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
          _messages = [
            for (final row in _previewMessages)
              InspectorMessage.fromPreview(row),
          ];
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

    // "What would go out next" has to answer for the connection as it is right
    // now: switching the trim mode changes where the history starts, so the
    // built prompt is stale the moment the setting is saved.
    ref.listen(
      activeApiConfigProvider.select(
        (config) => config?.contextBudgetSignature ?? '',
      ),
      (previous, next) {
        if (previous == null || previous == next || _loading) return;
        _build();
      },
    );
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
              InspectorToolbar(
                title: 'magic_request_preview'.tr(),
                onBack: widget.onBack,
                actions: _toolbarActions(context),
              ),
              // Same 12 px gutter the body's plaques sit in — the strip used
              // to run edge to edge over an inset body.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: GlazeTabBar(
                  tabs: _dataTabs(),
                  activeIndex: _dataTabIndex,
                  onChanged: (i) => setState(() => _dataTabIndex = i),
                ),
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
          ..._toolbarActions(context),
        ],
      ),
      showBack: true,
      onBack: () => Navigator.of(context).maybePop(),
      headerBottom: GlazeTabBar(
        tabs: _dataTabs(),
        activeIndex: _dataTabIndex,
        onChanged: (i) => setState(() => _dataTabIndex = i),
      ),
      body: _buildBody(),
    );
  }

  List<GlazeTabItem> _dataTabs() => [
    GlazeTabItem(label: 'tab_request'.tr(), icon: Icons.upload_rounded),
    GlazeTabItem(label: 'tab_response'.tr(), icon: Icons.download_rounded),
  ];

  List<Widget> _toolbarActions(BuildContext context) => [
    if (_previewTabIndex == 1) ...[
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.copy, size: 20, color: context.cs.primary),
        tooltip: 'action_copy'.tr(),
        onPressed: _copyContent,
      ),
      const SizedBox(width: 4),
    ],
    InspectorViewToggle(
      isRaw: _previewTabIndex == 1,
      onChanged: (isRaw) => setState(() => _previewTabIndex = isRaw ? 1 : 0),
    ),
  ];

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
                return _empty(context);
              }
              if (_previewTabIndex == 1) {
                return _buildRawView(_getRawPromptJson(), topPad);
              }
              return RequestBodyView(
                topInset: topPad,
                tokens: _result!.breakdown.totalTokens,
                contextSize: _apiConfig?.contextSize ?? 0,
                paramsTitle: _protocolLabel,
                params: _requestBody == null
                    ? const []
                    : _paramsFromBody(_requestBody!),
                messages: _messages,
                coverage: NextTurnCoverageBlock(
                  charId: widget.charId,
                  sessionId: _sessionId,
                  initiallyExpanded: widget.coverageExpanded,
                ),
              );
            } else {
              final chatState = ref.watch(chatProvider(widget.charId)).value;
              final raw = chatState?.lastRawResponse;
              if (raw == null || raw.isEmpty) {
                return _empty(context);
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

  Widget _empty(BuildContext context) => Center(
    child: Text(
      'no_preview_available'.tr(),
      style: TextStyle(color: context.cs.onSurfaceVariant),
    ),
  );

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

  /// Reads the request parameters straight from the protocol-specific body so
  /// the grid always matches what's actually sent. Nested config maps
  /// (`generationConfig`, `thinking`, `cache_control`, …) are flattened into
  /// individual tiles.
  List<InspectorParam> _paramsFromBody(Map<String, dynamic> body) {
    final items = <InspectorParam>[];

    // Model lives in the URL (not the body) for Gemini, so surface it from the
    // config to keep it visible across every protocol.
    final model = _apiConfig?.model;
    if (model != null && model.isNotEmpty) {
      items.add(InspectorParam(label: 'label_model'.tr(), value: model));
    }

    // Post-processing reshapes the conversation without leaving a trace in the
    // body, so the message list would otherwise be the only hint it ran. Shown
    // only when it is on — every other connection would carry a "None" tile.
    if (_postProcessingMode != PromptPostProcessing.none) {
      final base = PromptPostProcessing.baseOf(_postProcessingMode);
      items.add(
        InspectorParam(
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
        // not meaningful as a single tile — skip.
      } else {
        items.add(InspectorParam(label: label, value: '$value'));
      }
    }

    body.forEach((key, value) {
      if (_bulkBodyKeys.contains(key) || key == 'model') return;
      // Hoist Gemini's generationConfig children to top-level tiles.
      if (key == 'generationConfig' && value is Map) {
        value.forEach((k, v) => add('$k', v));
      } else {
        add(key, value);
      }
    });

    return items;
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
