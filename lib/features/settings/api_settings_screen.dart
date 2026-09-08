import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/llm/transport/llm_protocol.dart';
import '../../core/llm/transport/transport_factory.dart';
import '../../core/services/api_connection_tester.dart';
import '../../core/models/api_config.dart';
import '../../core/models/extra_request_parameter.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_tab_bar.dart';
import '../../shared/widgets/swipe_tab_switcher.dart';
import '../../shared/widgets/tab_slide_switcher.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/sheet_view.dart';
import 'api_config_draft.dart';
import 'api_list_provider.dart';
import 'widgets/connection_status.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/extra_request_parameters_editor.dart';

class ApiSettingsScreen extends ConsumerStatefulWidget {
  final bool startExpanded;
  const ApiSettingsScreen({super.key, this.startExpanded = false});

  @override
  ConsumerState<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends ConsumerState<ApiSettingsScreen> {
  int _tab = 0; // 0 = LLM, 1 = Embeddings

  bool _showApiKey = false;
  bool _isLoadingModels = false;
  ApiConnectionStatus _llmStatus = ApiConnectionStatus.idle;
  String _llmError = '';
  ApiConnectionStatus _embStatus = ApiConnectionStatus.idle;
  List<Map<String, dynamic>> _fetchedModels = [];

  // Text controllers
  final _nameCtrl = TextEditingController();
  final _endpointCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _maxTokensCtrl = TextEditingController();
  final _contextSizeCtrl = TextEditingController();
  final _firstChunkTimeoutCtrl = TextEditingController();
  final _reasoningHistoryCountCtrl = TextEditingController();
  final _embEndpointCtrl = TextEditingController();
  final _embApiKeyCtrl = TextEditingController();
  final _embModelCtrl = TextEditingController();
  final _embChunkTokensCtrl = TextEditingController();

  // Non-text form state
  double _temperature = 0.7;
  double _topP = 0.9;
  double _frequencyPenalty = 0.0;
  double _presencePenalty = 0.0;
  int _topK = 0;
  bool _stream = true;
  bool _requestReasoning = false;
  bool _useResponsesApi = false;
  bool _showNativeReasoning = true;
  String _reasoningEffort = 'medium';
  bool _omitTemperature = false;
  bool _omitTopP = false;
  bool _omitTopK = false;
  bool _omitFrequencyPenalty = false;
  bool _omitPresencePenalty = false;
  bool _omitReasoning = false;
  bool _omitReasoningEffort = false;
  bool _embeddingEnabled = false;
  bool _embeddingUseSame = true;
  String _cacheControlTtl = 'off';
  String _cacheBreakpointMode = 'depth';
  String _sessionIdMode = 'openrouter';
  String _protocol = LlmProtocol.openai;
  List<ExtraRequestParameter> _extraRequestParameters = const [];

  String? _loadedPresetId;
  // Each tab owns its own scroll controller. During a slide transition both
  // tab bodies are briefly alive at once, so they must never share a single
  // controller (a controller attached to two scroll views throws). The sheet
  // is pointed at whichever controller belongs to the active tab.
  final _llmScrollController = ScrollController();
  final _embScrollController = ScrollController();
  Timer? _saveTimer;
  bool _loading = false;

  /// WidgetRef captured in initState for safe use in dispose() (where the
  /// widget is already unmounted and ref.read/watch throw
  /// "Using ref when a widget is about to or has been unmounted is unsafe").
  late final WidgetRef _ref;

  List<TextEditingController> get _ctrls => [
    _nameCtrl,
    _endpointCtrl,
    _keyCtrl,
    _modelCtrl,
    _maxTokensCtrl,
    _contextSizeCtrl,
    _firstChunkTimeoutCtrl,
    _reasoningHistoryCountCtrl,
    _embEndpointCtrl,
    _embApiKeyCtrl,
    _embModelCtrl,
    _embChunkTokensCtrl,
  ];

  @override
  void initState() {
    super.initState();
    _ref = ref;
    for (final c in _ctrls) {
      c.addListener(_scheduleSave);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadActivePreset());
  }

  @override
  void deactivate() {
    // This screen is presented two ways: a fullscreen route (Tools → API) and
    // a modal bottom sheet (chat magic-drawer → API). The route path flushes
    // via the back button (_goBack), but a bottom sheet dismissed by swipe or
    // barrier-tap never calls _goBack — only dispose() runs, and by then the
    // captured ref is unmounted so the flush silently fails. That is why a
    // toggle like Streaming was lost when changed from the sheet. deactivate()
    // runs while the widget is still mounted (ref valid), so flushing the
    // pending debounced save here makes it reliable on every exit path.
    _flushSave();
    super.deactivate();
  }

  @override
  void dispose() {
    _flushSave();
    _llmScrollController.dispose();
    _embScrollController.dispose();
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _flushSave() {
    if (_saveTimer?.isActive == true) {
      _saveTimer!.cancel();
      _save();
    }
  }

  void _goBack() {
    _flushSave();
    // Back navigation depends on how this screen is *presented*, not on whether
    // it starts expanded. Presented as the Tools route (a page, not a modal
    // sheet) it belongs to the /tools branch, so back returns there. Presented
    // as a modal bottom sheet (chat magic-drawer, onboarding) it must simply
    // pop, otherwise `go('/tools')` would tear the host flow (e.g. onboarding)
    // down. This mirrors SheetView's own modal-vs-route detection so the sheet
    // can be opened expanded from a modal without hijacking navigation.
    final isModalSheet = ModalRoute.of(context) is ModalBottomSheetRoute;
    if (isModalSheet) {
      Navigator.of(context).maybePop();
    } else {
      context.go('/tools');
    }
  }

  void _scheduleSave() {
    if (_loading) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  void _persistActiveId(String? id) async {
    final prefs = ref.read(sharedPreferencesProvider).value;
    if (prefs == null) return;
    if (id != null) {
      await prefs.setString('activeApiConfigId', id);
    } else {
      await prefs.remove('activeApiConfigId');
    }
  }

  void _loadActivePreset() {
    final config = ref.read(activeApiConfigProvider);
    if (config != null) _loadFromConfig(config);
  }

  void _loadFromConfig(ApiConfig config) {
    if (config.id == _loadedPresetId) return;
    _loadedPresetId = config.id;
    _loading = true;
    final draft = ApiConfigDraft.fromConfig(config);
    final values = draft.values;

    _nameCtrl.text = draft.name;
    _endpointCtrl.text = draft.endpoint;
    _keyCtrl.text = draft.apiKey;
    _modelCtrl.text = draft.model;
    _maxTokensCtrl.text = draft.maxTokens;
    _contextSizeCtrl.text = draft.contextSize;
    _firstChunkTimeoutCtrl.text = draft.firstChunkTimeoutSeconds;
    _reasoningHistoryCountCtrl.text = draft.reasoningHistoryCount;
    _embEndpointCtrl.text = draft.embeddingEndpoint;
    _embApiKeyCtrl.text = draft.embeddingApiKey;
    _embModelCtrl.text = draft.embeddingModel;
    _embChunkTokensCtrl.text = draft.embeddingMaxChunkTokens;

    setState(() {
      _temperature = values.temperature;
      _topP = values.topP;
      _topK = values.topK;
      _frequencyPenalty = values.frequencyPenalty;
      _presencePenalty = values.presencePenalty;
      _stream = values.stream;
      _requestReasoning = values.requestReasoning;
      _useResponsesApi = values.useResponsesApi;
      _showNativeReasoning = values.showNativeReasoning;
      _reasoningEffort = values.reasoningEffort;
      _omitTemperature = values.omitTemperature;
      _omitTopP = values.omitTopP;
      _omitTopK = values.omitTopK;
      _omitFrequencyPenalty = values.omitFrequencyPenalty;
      _omitPresencePenalty = values.omitPresencePenalty;
      _omitReasoning = values.omitReasoning;
      _omitReasoningEffort = values.omitReasoningEffort;
      _embeddingEnabled = values.embeddingEnabled;
      _embeddingUseSame = values.embeddingUseSame;
      _cacheControlTtl = values.cacheControlTtl;
      _cacheBreakpointMode = values.cacheBreakpointMode;
      _sessionIdMode = values.sessionIdMode;
      _protocol = values.protocol;
      _extraRequestParameters = values.extraRequestParameters;
      _fetchedModels = [];
    });

    _loading = false;
  }

  Future<void> _save() async {
    final config = _ref.read(activeApiConfigProvider);
    if (config == null) return;
    final draft = ApiConfigDraft(
      values: config.copyWith(
        temperature: _temperature,
        topP: _topP,
        topK: _topK,
        frequencyPenalty: _frequencyPenalty,
        presencePenalty: _presencePenalty,
        stream: _stream,
        requestReasoning: _requestReasoning,
        useResponsesApi: _useResponsesApi,
        showNativeReasoning: _showNativeReasoning,
        reasoningEffort: _reasoningEffort,
        omitTemperature: _omitTemperature,
        omitTopP: _omitTopP,
        omitTopK: _omitTopK,
        omitFrequencyPenalty: _omitFrequencyPenalty,
        omitPresencePenalty: _omitPresencePenalty,
        omitReasoning: _omitReasoning,
        omitReasoningEffort: _omitReasoningEffort,
        embeddingEnabled: _embeddingEnabled,
        embeddingUseSame: _embeddingUseSame,
        cacheControlTtl: _cacheControlTtl,
        cacheBreakpointMode: _cacheBreakpointMode,
        sessionIdMode: _sessionIdMode,
        protocol: _protocol,
        extraRequestParameters: _extraRequestParameters,
      ),
      name: _nameCtrl.text,
      endpoint: _endpointCtrl.text,
      apiKey: _keyCtrl.text,
      model: _modelCtrl.text,
      maxTokens: _maxTokensCtrl.text,
      contextSize: _contextSizeCtrl.text,
      firstChunkTimeoutSeconds: _firstChunkTimeoutCtrl.text,
      reasoningHistoryCount: _reasoningHistoryCountCtrl.text,
      embeddingEndpoint: _embEndpointCtrl.text,
      embeddingApiKey: _embApiKeyCtrl.text,
      embeddingModel: _embModelCtrl.text,
      embeddingMaxChunkTokens: _embChunkTokensCtrl.text,
    );
    await _ref.read(apiListProvider.notifier).put(draft.toConfig(config));
  }

  bool get _supportsTemperature => true;

  bool get _supportsTopP => true;

  bool get _supportsTopK =>
      _protocol == LlmProtocol.openai ||
      _protocol == LlmProtocol.openrouter ||
      _protocol == LlmProtocol.anthropic ||
      _protocol == LlmProtocol.gemini;

  bool get _supportsFrequencyPenalty =>
      _protocol == LlmProtocol.openai || _protocol == LlmProtocol.openrouter;

  bool get _supportsPresencePenalty =>
      _protocol == LlmProtocol.openai || _protocol == LlmProtocol.openrouter;

  bool get _supportsPromptCache =>
      _protocol == LlmProtocol.anthropic || _protocol == LlmProtocol.openai;

  bool get _supportsReasoning => true;

  bool get _showsOmitSamplingControls =>
      _protocol == LlmProtocol.openai || _protocol == LlmProtocol.openrouter;

  bool get _hideSamplingWhileReasoningAnthropic =>
      _protocol == LlmProtocol.anthropic && _requestReasoning;

  List<String> get _reasoningEffortOptions =>
      ApiConfigDraft.reasoningEffortOptions(_protocol);

  void _applyProtocolUiPolicy(String protocol) {
    final normalized = ApiConfigDraft.normalizeValues(
      ApiConfig(
        id: '',
        protocol: protocol,
        reasoningEffort: _reasoningEffort,
        omitTemperature: _omitTemperature,
        omitTopP: _omitTopP,
        omitReasoning: _omitReasoning,
        omitReasoningEffort: _omitReasoningEffort,
        frequencyPenalty: _frequencyPenalty,
        presencePenalty: _presencePenalty,
        cacheControlTtl: _cacheControlTtl,
      ),
    );
    _protocol = normalized.protocol;
    _reasoningEffort = normalized.reasoningEffort;
    _omitTemperature = normalized.omitTemperature;
    _omitTopP = normalized.omitTopP;
    _omitReasoning = normalized.omitReasoning;
    _omitReasoningEffort = normalized.omitReasoningEffort;
    _frequencyPenalty = normalized.frequencyPenalty;
    _presencePenalty = normalized.presencePenalty;
    _cacheControlTtl = normalized.cacheControlTtl;
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final asyncList = ref.watch(apiListProvider);
    final activeConfig = ref.watch(activeApiConfigProvider);

    if (activeConfig != null && activeConfig.id != _loadedPresetId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadFromConfig(activeConfig);
      });
    }

    final list = asyncList.value ?? [];
    final activeName = _activeName(activeConfig, list);

    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: 'menu_app_settings'.tr(),
      showBack: true,
      onBack: _goBack,
      scrollController: _tab == 0 ? _llmScrollController : _embScrollController,
      // The LLM/Embeddings switcher stays fixed in the header so it never
      // slides with the tab bodies — a single segmented control that keeps its
      // own pill animation while the content swipes beneath it.
      headerBottom: list.isEmpty ? null : _buildTabBar(),
      body: asyncList.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
        data: (list) => list.isEmpty
            ? _buildEmptyState()
            : SwipeTabSwitcher(
                index: _tab,
                length: 2,
                onChanged: (i) => setState(() => _tab = i),
                child: TabSlideSwitcher(
                  index: _tab,
                  child: _tab == 0
                      ? _buildLlmTab(list, activeName)
                      : _buildEmbeddingsTab(list, activeName),
                ),
              ),
      ),
    );
  }

  String _activeName(ApiConfig? config, List<ApiConfig> list) {
    if (config == null) {
      return list.isEmpty ? 'no_active_connections'.tr() : 'unnamed_entry'.tr();
    }
    if (config.name.isNotEmpty) return config.name;
    if (config.model.isNotEmpty) return config.model;
    return 'unnamed_entry'.tr();
  }

  // The fixed LLM/Embeddings segmented control. Lives in the sheet header so it
  // stays put (and keeps its own pill animation) while the tab bodies slide.
  Widget _buildTabBar() {
    return GlazeTabBar(
      tabs: [
        GlazeTabItem(label: 'LLM', icon: Icons.chat_bubble_outline_rounded),
        GlazeTabItem(label: 'tab_embeddings'.tr(), icon: Icons.layers_outlined),
      ],
      activeIndex: _tab,
      onChanged: (i) => setState(() => _tab = i),
    );
  }

  Widget _buildTopControls(List<ApiConfig> list, String activeName) {
    // Preset selector pill (tab-specific — slides with the body content).
    return _tab == 0
        ? ConnectionStatus(
            status: _llmStatus,
            errorMessage: _llmError,
            onRetry: _testLlmConnection,
            child: _buildPresetPill(context, list, activeName),
          )
        : _buildPresetPill(context, list, activeName);
  }

  Widget _buildPresetPill(
    BuildContext context,
    List<ApiConfig> list,
    String activeName,
  ) {
    return GestureDetector(
      onTap: list.isEmpty ? null : () => _showPresetSheet(context, list),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                activeName,
                style: TextStyle(
                  color: context.cs.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              color: context.cs.primary,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud, size: 64, color: context.cs.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            'settings_no_api_configs'.tr(),
            style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 15),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => _createNewPreset([]),
            child: Text('settings_add_api_config'.tr()),
          ),
        ],
      ),
    );
  }

  // ── LLM tab ───────────────────────────────────────────────────────────────────

  Widget _buildLlmTab(List<ApiConfig> list, String activeName) {
    return Builder(
      builder: (context) => ListView(
        controller: _llmScrollController,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 12,
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _buildTopControls(list, activeName),
          ),
          MenuGroup(
            compact: true,
            header: 'onboarding_connection'.tr(),
            helpTerm: 'api',
            items: [
              MenuFieldItem(
                label: 'settings_config_name'.tr(),
                controller: _nameCtrl,
                placeholder: 'My OpenAI',
              ),
              MenuSelectorItem(
                label: 'settings_protocol'.tr(),
                currentValue: LlmProtocol.labels[_protocol] ?? _protocol,
                onTap: _openProtocolSelector,
              ),
              if (_protocol != LlmProtocol.openrouter)
                MenuFieldItem(
                  label: 'onboarding_label_endpoint'.tr(),
                  controller: _endpointCtrl,
                  placeholder: 'https://your-endpoint.example',
                ),
              MenuFieldItem(
                label: 'onboarding_label_model'.tr(),
                controller: _modelCtrl,
                placeholder: 'gemini-3-pro-preview',
                suffix: _isLoadingModels
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: context.cs.onSurfaceVariant,
                          size: 22,
                        ),
                        tooltip: _fetchedModels.isEmpty
                            ? 'settings_fetch_models'.tr()
                            : 'settings_select_model'.tr(),
                        onPressed: _openModelSelector,
                      ),
              ),
              MenuFieldItem(
                label: 'onboarding_label_key'.tr(),
                helpTerm: 'apikey',
                controller: _keyCtrl,
                placeholder: 'sk-...',
                obscure: !_showApiKey,
                suffix: IconButton(
                  icon: Icon(
                    _showApiKey
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: context.cs.onSurfaceVariant,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _showApiKey = !_showApiKey),
                ),
              ),
              MenuSwitchItem(
                label: 'label_stream'.tr(),
                helpTerm: 'streaming',
                description: 'desc_stream'.tr(),
                value: _stream,
                onChanged: (v) {
                  setState(() => _stream = v);
                  _scheduleSave();
                },
              ),
            ],
          ),
          MenuGroup(
            compact: true,
            header: 'section_gen_params'.tr(),
            helpTerm: 'guided',
            items: [
              if (_supportsTemperature && !_hideSamplingWhileReasoningAnthropic)
                MenuRangeItem(
                  label: 'label_temperature'.tr(),
                  helpTerm: 'temperature',
                  value: _temperature,
                  min: 0,
                  max: 2,
                  divisions: 200,
                  editableValue: true,
                  included: _showsOmitSamplingControls
                      ? !_omitTemperature
                      : null,
                  onIncludedChanged: _showsOmitSamplingControls
                      ? (v) {
                          setState(() => _omitTemperature = !v);
                          _scheduleSave();
                        }
                      : null,
                  onChanged: (v) {
                    setState(() => _temperature = v);
                    _scheduleSave();
                  },
                ),
              if (_supportsTopP && !_hideSamplingWhileReasoningAnthropic)
                MenuRangeItem(
                  label: 'label_top_p'.tr(),
                  helpTerm: 'top-p',
                  value: _topP,
                  min: 0,
                  max: 1,
                  divisions: 100,
                  editableValue: true,
                  included: _showsOmitSamplingControls ? !_omitTopP : null,
                  onIncludedChanged: _showsOmitSamplingControls
                      ? (v) {
                          setState(() => _omitTopP = !v);
                          _scheduleSave();
                        }
                      : null,
                  onChanged: (v) {
                    setState(() => _topP = v);
                    _scheduleSave();
                  },
                ),
              if (_supportsTopK && !_hideSamplingWhileReasoningAnthropic)
                MenuRangeItem(
                  label: 'label_top_k_sampling'.tr(),
                  helpTerm: 'top-k',
                  value: _topK.toDouble(),
                  min: 0,
                  max: 200,
                  divisions: 200,
                  editableValue: true,
                  decimalPlaces: 0,
                  included: !_omitTopK,
                  onIncludedChanged: (v) {
                    setState(() => _omitTopK = !v);
                    _scheduleSave();
                  },
                  onChanged: (v) {
                    setState(() => _topK = v.round());
                    _scheduleSave();
                  },
                ),
              if (_supportsFrequencyPenalty)
                MenuRangeItem(
                  label: 'label_frequency_penalty'.tr(),
                  helpTerm: 'frequency-penalty',
                  value: _frequencyPenalty,
                  min: -2,
                  max: 2,
                  divisions: 80,
                  editableValue: true,
                  included: !_omitFrequencyPenalty,
                  onIncludedChanged: (v) {
                    setState(() => _omitFrequencyPenalty = !v);
                    _scheduleSave();
                  },
                  onChanged: (v) {
                    setState(() => _frequencyPenalty = v);
                    _scheduleSave();
                  },
                ),
              if (_supportsPresencePenalty)
                MenuRangeItem(
                  label: 'label_presence_penalty'.tr(),
                  helpTerm: 'presence-penalty',
                  value: _presencePenalty,
                  min: -2,
                  max: 2,
                  divisions: 80,
                  editableValue: true,
                  included: !_omitPresencePenalty,
                  onIncludedChanged: (v) {
                    setState(() => _omitPresencePenalty = !v);
                    _scheduleSave();
                  },
                  onChanged: (v) {
                    setState(() => _presencePenalty = v);
                    _scheduleSave();
                  },
                ),
              MenuFieldItem(
                label: 'label_max_tokens'.tr(),
                helpTerm: 'max-tokens',
                controller: _maxTokensCtrl,
                placeholder: '8000',
                keyboardType: TextInputType.number,
              ),
              MenuFieldItem(
                label: 'label_context_size'.tr(),
                helpTerm: 'context-size',
                controller: _contextSizeCtrl,
                placeholder: '32000',
                keyboardType: TextInputType.number,
              ),
              MenuFieldItem(
                label: 'label_first_chunk_timeout'.tr(),
                helpTerm: 'first-chunk-timeout',
                controller: _firstChunkTimeoutCtrl,
                placeholder: '60',
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          MenuGroup(
            compact: true,
            header: 'label_reasoning_settings'.tr(),
            helpTerm: 'preset-reasoning',
            items: [
              if (_protocol == LlmProtocol.openai)
                MenuSwitchItem(
                  label: 'label_use_responses_api'.tr(),
                  description: 'desc_use_responses_api'.tr(),
                  value: _useResponsesApi,
                  onChanged: (value) {
                    setState(() => _useResponsesApi = value);
                    _scheduleSave();
                  },
                ),
              if (_supportsReasoning)
                MenuSwitchItem(
                  label: 'label_reasoning'.tr(),
                  helpTerm: 'reasoning-native',
                  description: 'desc_reasoning'.tr(),
                  value: _showNativeReasoning,
                  onChanged: (v) {
                    setState(() => _showNativeReasoning = v);
                    _scheduleSave();
                  },
                ),
              if (_supportsReasoning)
                MenuSelectorItem(
                  label: 'label_reasoning_effort'.tr(),
                  helpTerm: 'reasoning-effort',
                  currentValue: _reasoningEffortLabel(_reasoningEffort),
                  included: _requestReasoning,
                  onIncludedChanged: (v) {
                    setState(() {
                      _requestReasoning = v;
                      _omitReasoning = !v;
                      _omitReasoningEffort = !v;
                    });
                    _scheduleSave();
                  },
                  onTap: _openReasoningEffortSelector,
                ),
              if (_supportsReasoning)
                MenuFieldItem(
                  label: 'label_include_last_reasoning'.tr(),
                  controller: _reasoningHistoryCountCtrl,
                  placeholder: '0',
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                ),
              if (_supportsPromptCache)
                MenuSelectorItem(
                  label: 'label_prompt_cache_ttl'.tr(),
                  currentValue: _cacheControlTtlLabel(_cacheControlTtl),
                  onTap: _openCacheControlTtlSelector,
                ),
              if (_supportsPromptCache)
                MenuSelectorItem(
                  label: 'label_prompt_cache_breakpoint'.tr(),
                  currentValue: _cacheBreakpointModeLabel(_cacheBreakpointMode),
                  onTap: _openCacheBreakpointModeSelector,
                ),
              MenuSelectorItem(
                label: 'label_session_id_mode'.tr(),
                currentValue: _sessionIdModeLabel(_sessionIdMode),
                onTap: _openSessionIdModeSelector,
              ),
            ],
          ),
          ExtraRequestParametersEditor(
            key: ValueKey('api-extra-parameters-$_loadedPresetId'),
            parameters: _extraRequestParameters,
            title: 'extra_request_parameters'.tr(),
            description: 'extra_request_parameters_desc'.tr(),
            keyLabel: 'extra_request_parameter_key'.tr(),
            valueLabel: 'extra_request_parameter_value'.tr(),
            addLabel: 'extra_request_parameter_add'.tr(),
            onChanged: (parameters) {
              _extraRequestParameters = parameters;
              _scheduleSave();
            },
          ),
        ],
      ),
    );
  }

  // ── Embeddings tab ────────────────────────────────────────────────────────────

  Widget _buildEmbeddingsTab(List<ApiConfig> list, String activeName) {
    return Builder(
      builder: (context) => ListView(
        controller: _embScrollController,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 12,
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _buildTopControls(list, activeName),
          ),
          MenuGroup(
            compact: true,
            header: 'tab_embeddings'.tr(),
            helpTerm: 'embeddings',
            items: [
              MenuSwitchItem(
                label: 'search_type_vector'.tr(),
                description: 'settings_enable_vector_desc'.tr(),
                value: _embeddingEnabled,
                onChanged: (v) {
                  setState(() => _embeddingEnabled = v);
                  final config = ref.read(activeApiConfigProvider);
                  if (config != null) {
                    ref
                        .read(apiListProvider.notifier)
                        .setEmbeddingEnabled(config.id, v);
                  }
                  _scheduleSave();
                },
              ),
              if (_embeddingEnabled) ...[
                MenuSwitchItem(
                  label: 'settings_use_llm_api'.tr(),
                  description: 'settings_use_llm_api_desc'.tr(),
                  value: _embeddingUseSame,
                  onChanged: (v) {
                    setState(() => _embeddingUseSame = v);
                    _scheduleSave();
                  },
                ),
                if (!_embeddingUseSame) ...[
                  MenuFieldItem(
                    label: 'settings_embedding_endpoint'.tr(),
                    controller: _embEndpointCtrl,
                    placeholder: 'http://127.0.0.1:11434/v1',
                  ),
                  MenuFieldItem(
                    label: 'settings_embedding_model'.tr(),
                    controller: _embModelCtrl,
                    placeholder: 'text-embedding-3-small',
                  ),
                  MenuFieldItem(
                    label: 'onboarding_label_key'.tr(),
                    controller: _embApiKeyCtrl,
                    placeholder: 'sk-...',
                    obscure: true,
                  ),
                ],
                if (_embeddingUseSame)
                  MenuFieldItem(
                    label: 'settings_embedding_model'.tr(),
                    controller: _embModelCtrl,
                    placeholder: 'text-embedding-3-small',
                  ),
                MenuFieldItem(
                  label: 'settings_max_tokens_chunk'.tr(),
                  controller: _embChunkTokensCtrl,
                  placeholder: '512',
                  keyboardType: TextInputType.number,
                ),
              ],
            ],
          ),
          if (_embeddingEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.cs.primary,
                  side: BorderSide(
                    color: context.cs.primary.withValues(alpha: 0.4),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _embStatus == ApiConnectionStatus.connecting
                    ? null
                    : _testEmbConnection,
                icon: _embStatus == ApiConnectionStatus.connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find_rounded),
                label: Text(
                  _embStatus == ApiConnectionStatus.connecting
                      ? 'settings_testing'.tr()
                      : 'settings_test_connection'.tr(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Sheet actions ─────────────────────────────────────────────────────────────

  Future<void> _showPresetSheet(
    BuildContext context,
    List<ApiConfig> list,
  ) async {
    final activeId =
        ref.read(activeApiPresetIdProvider) ??
        (list.isNotEmpty ? list.first.id : null);
    await GlazeBottomSheet.show<void>(
      context,
      title: 'settings_api_configs_title'.tr(),
      headerAction: IconButton(
        icon: Icon(Icons.add_circle_outline_rounded, color: context.cs.primary),
        tooltip: 'settings_new_config_tooltip'.tr(),
        onPressed: () {
          Navigator.of(context, rootNavigator: true).pop();
          _createNewPreset(list);
        },
      ),
      cardItems: list.map((config) {
        final isActive = config.id == activeId;
        final name = config.name.isNotEmpty
            ? config.name
            : config.model.isNotEmpty
            ? config.model
            : 'unnamed_entry'.tr();

        String? faviconUrl;
        if (config.endpoint.isNotEmpty) {
          try {
            final uri = Uri.parse(config.endpoint);
            if (uri.host.isNotEmpty &&
                !uri.host.contains('127.0.0.1') &&
                !uri.host.contains('localhost')) {
              faviconUrl =
                  'https://www.google.com/s2/favicons?domain=${uri.host}&sz=128';
            }
          } catch (_) {}
        }

        return BottomSheetCardItem(
          label: name,
          sublabel: config.endpoint.isNotEmpty
              ? config.endpoint
                    .replaceAll(RegExp(r'https?://'), '')
                    .split('/')
                    .first
              : null,
          icon: isActive
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded,
          faviconUrl: faviconUrl,
          isActive: isActive,
          actions: [
            if (list.length > 1)
              BottomSheetAction(
                icon: Icons.delete_outline_rounded,
                color: context.cs.onSurfaceVariant,
                onTap: () async {
                  Navigator.of(context, rootNavigator: true).pop();
                  await ref.read(apiListProvider.notifier).remove(config.id);
                  if (activeId == config.id) {
                    ref.read(activeApiPresetIdProvider.notifier).state = null;
                    _persistActiveId(null);
                    _loadedPresetId = null;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _loadActivePreset();
                    });
                  }
                },
              ),
          ],
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _saveTimer?.cancel();
            ref.read(activeApiPresetIdProvider.notifier).state = config.id;
            _persistActiveId(config.id);
            _loadedPresetId = null;
            _loadFromConfig(config);
          },
        );
      }).toList(),
    );
  }

  Future<void> _createNewPreset(List<ApiConfig> existing) async {
    await GlazeBottomSheet.show<void>(
      context,
      title: 'settings_new_config_title'.tr(),
      input: BottomSheetInput(
        placeholder: 'My OpenAI',
        confirmLabel: 'btn_create'.tr(),
        onConfirm: (name) async {
          Navigator.of(context, rootNavigator: true).pop();
          final trimmed = name.trim();
          if (trimmed.isEmpty) return;

          final newConfig = ApiConfig(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: trimmed,
          );
          ref.read(activeApiPresetIdProvider.notifier).state = newConfig.id;
          _persistActiveId(newConfig.id);
          _loadedPresetId = null;
          _loadFromConfig(newConfig);
          await ref.read(apiListProvider.notifier).put(newConfig);
        },
      ),
    );
  }

  Future<void> _openModelSelector() async {
    if (_fetchedModels.isEmpty) {
      await _fetchModels();
      if (_fetchedModels.isEmpty) return;
    }
    if (!mounted) return;
    final models = _fetchedModels.map((m) => m['id'] as String).toList()
      ..sort();
    final current = _modelCtrl.text;
    if (current.isNotEmpty && !models.contains(current)) {
      models.insert(0, current);
    }
    final selectedIndex = models.indexOf(current);
    await GlazeBottomSheet.show<void>(
      context,
      title: 'onboarding_select_model'.tr(),
      scrollToIndex: selectedIndex >= 0 ? selectedIndex : null,
      items: models
          .map(
            (m) => BottomSheetItem(
              label: m,
              icon: m == current ? Icons.check : null,
              iconColor: context.cs.primary,
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                _modelCtrl.text = m;
              },
            ),
          )
          .toList(),
    );
  }

  String _reasoningEffortLabel(String effort) {
    return switch (effort) {
      'auto' => 'reasoning_effort_auto'.tr(),
      'min' => 'reasoning_effort_min'.tr(),
      'low' => 'reasoning_effort_low'.tr(),
      'medium' => 'reasoning_effort_medium'.tr(),
      'high' => 'reasoning_effort_high'.tr(),
      'max' => 'reasoning_effort_max'.tr(),
      _ => effort,
    };
  }

  void _openReasoningEffortSelector() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'label_reasoning_effort'.tr(),
      items: _reasoningEffortOptions.map((e) {
        final label = _reasoningEffortLabel(e);
        final active = e == _reasoningEffort;
        return BottomSheetItem(
          label: label,
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _reasoningEffort = e);
            _scheduleSave();
          },
        );
      }).toList(),
    );
  }

  String _cacheControlTtlLabel(String ttl) {
    return switch (ttl) {
      '5min' => 'prompt_cache_ttl_5min'.tr(),
      '1h' => 'prompt_cache_ttl_1h'.tr(),
      _ => 'prompt_cache_ttl_off'.tr(),
    };
  }

  String _cacheBreakpointModeLabel(String mode) {
    return switch (mode) {
      'stable_prefix' => 'prompt_cache_breakpoint_stable'.tr(),
      _ => 'prompt_cache_breakpoint_depth'.tr(),
    };
  }

  String _sessionIdModeLabel(String mode) {
    return switch (mode) {
      'always' => 'session_id_mode_always'.tr(),
      'off' => 'session_id_mode_off'.tr(),
      _ => 'session_id_mode_openrouter'.tr(),
    };
  }

  void _openCacheControlTtlSelector() {
    const options = ['off', '5min', '1h'];
    GlazeBottomSheet.show<void>(
      context,
      title: 'label_prompt_cache_ttl'.tr(),
      items: options.map((e) {
        final label = _cacheControlTtlLabel(e);
        final active = e == _cacheControlTtl;
        return BottomSheetItem(
          label: label,
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _cacheControlTtl = e);
            _scheduleSave();
          },
        );
      }).toList(),
    );
  }

  void _openCacheBreakpointModeSelector() {
    const options = ['depth', 'stable_prefix'];
    GlazeBottomSheet.show<void>(
      context,
      title: 'label_prompt_cache_breakpoint'.tr(),
      items: options.map((e) {
        final label = _cacheBreakpointModeLabel(e);
        final active = e == _cacheBreakpointMode;
        return BottomSheetItem(
          label: label,
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _cacheBreakpointMode = e);
            _scheduleSave();
          },
        );
      }).toList(),
    );
  }

  void _openSessionIdModeSelector() {
    const options = ['openrouter', 'always', 'off'];
    GlazeBottomSheet.show<void>(
      context,
      title: 'label_session_id_mode'.tr(),
      items: options.map((e) {
        final label = _sessionIdModeLabel(e);
        final active = e == _sessionIdMode;
        return BottomSheetItem(
          label: label,
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _sessionIdMode = e);
            _scheduleSave();
          },
        );
      }).toList(),
    );
  }

  void _openProtocolSelector() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'settings_protocol'.tr(),
      items: LlmProtocol.all.map((p) {
        final label = LlmProtocol.labels[p] ?? p;
        final active = p == _protocol;
        return BottomSheetItem(
          label: label,
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() {
              _protocol = p;
              _applyProtocolUiPolicy(_protocol);
              _fetchedModels = [];
            });
            _scheduleSave();
          },
        );
      }).toList(),
    );
  }

  Future<void> _fetchModels() async {
    final endpoint = _endpointCtrl.text.trim();
    final apiKey = _keyCtrl.text.trim();
    final endpointRequired = _protocol != LlmProtocol.openrouter;
    if ((endpointRequired && endpoint.isEmpty) || apiKey.isEmpty) {
      GlazeToast.show(context, 'settings_err_endpoint_key'.tr());
      return;
    }
    setState(() => _isLoadingModels = true);
    try {
      final models = await pickChatTransport(
        _protocol,
      ).fetchModels(endpoint: endpoint, apiKey: apiKey);
      if (!mounted) return;
      setState(() {
        _fetchedModels = models;
        _isLoadingModels = false;
      });
      if (models.isEmpty) {
        GlazeToast.show(context, 'settings_err_no_models'.tr());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingModels = false);
        GlazeErrorDialog.show(context, e, prefix: 'settings_err_failed'.tr());
      }
    }
  }

  Future<void> _testLlmConnection() async {
    final endpoint = _endpointCtrl.text.trim();
    final apiKey = _keyCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final endpointRequired = _protocol != LlmProtocol.openrouter;
    // Model is optional here: tapping the status should let the user verify the
    // provider connection even before a model has been picked.
    if ((endpointRequired && endpoint.isEmpty) || apiKey.isEmpty) {
      GlazeToast.show(context, 'settings_err_endpoint_key'.tr());
      return;
    }
    setState(() {
      _llmStatus = ApiConnectionStatus.connecting;
      _llmError = '';
    });
    final result = await ApiConnectionTester().testLlm(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      protocol: _protocol,
      useResponsesApi: _useResponsesApi,
    );
    if (!mounted) return;
    switch (result) {
      case ApiTestSuccess(:final message):
        setState(() => _llmStatus = ApiConnectionStatus.connected);
        GlazeToast.show(context, message);
      case ApiTestFailure(:final error):
        setState(() {
          _llmStatus = ApiConnectionStatus.failed;
          _llmError = error.toString();
        });
        GlazeErrorDialog.show(
          context,
          error,
          prefix: 'settings_err_conn_failed'.tr(),
        );
    }
  }

  Future<void> _testEmbConnection() async {
    final String endpoint, apiKey, model;
    if (_embeddingUseSame) {
      endpoint = _endpointCtrl.text.trim();
      apiKey = _keyCtrl.text.trim();
      model = _embModelCtrl.text.trim().isNotEmpty
          ? _embModelCtrl.text.trim()
          : _modelCtrl.text.trim();
    } else {
      endpoint = _embEndpointCtrl.text.trim();
      apiKey = _embApiKeyCtrl.text.trim();
      model = _embModelCtrl.text.trim();
    }
    if (endpoint.isEmpty) {
      GlazeToast.show(context, 'settings_err_fill_endpoint'.tr());
      return;
    }
    setState(() {
      _embStatus = ApiConnectionStatus.connecting;
    });
    final result = await ApiConnectionTester().testEmbedding(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
    );
    if (!mounted) return;
    switch (result) {
      case ApiTestSuccess(:final message):
        setState(() => _embStatus = ApiConnectionStatus.connected);
        GlazeToast.show(context, message);
      case ApiTestFailure(:final error):
        setState(() => _embStatus = ApiConnectionStatus.failed);
        GlazeErrorDialog.show(
          context,
          error,
          prefix: 'settings_err_conn_failed'.tr(),
        );
    }
  }
}
