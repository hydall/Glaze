import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../core/llm/converters/reasoning_effort.dart';
import '../../core/llm/converters/prompt_post_processing.dart';
import '../../core/llm/transport/endpoint_normalizer.dart';
import '../../core/llm/transport/endpoint_preview.dart';
import '../../core/llm/transport/endpoint_resolution_cache.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/llm/transport/transport_factory.dart';
import '../../core/services/api_connection_tester.dart';
import '../../core/models/api_config.dart';
import '../../core/models/extra_request_parameter.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_tab_bar.dart';
import '../../shared/widgets/list_controls.dart';
import '../../shared/widgets/swipe_tab_switcher.dart';
import '../../shared/widgets/tab_slide_switcher.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/sheet_view.dart';
import 'api_config_draft.dart';
import '../studio/widgets/studio_slots_tab.dart';
import 'api_list_provider.dart';
import 'api_preset_selection_provider.dart';
import 'api_preset_sort.dart';
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
  int _tab = 0; // 0 = LLM, 1 = Embeddings, 2 = Studio agents

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
  final _embRequestsPerMinuteCtrl = TextEditingController();

  // Non-text form state
  double _temperature = 0.7;
  double _topP = 0.9;
  double _frequencyPenalty = 0.0;
  double _presencePenalty = 0.0;
  int _topK = 0;
  bool _stream = true;
  bool _requestReasoning = false;
  bool _customUseResponsesApi = false;
  bool _useSystemInstruction = true;
  bool _showNativeReasoning = true;
  bool _excludeReasoningFromContextBudget = false;
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
  String _promptPostProcessing = PromptPostProcessing.none;
  String _protocol = LlmProtocol.openai;
  List<ExtraRequestParameter> _extraRequestParameters = const [];

  String? _loadedPresetId;

  /// Whether the presets sheet is on screen. A bulk delete can outlive it, and
  /// closing "the sheet" once it is gone would pop whatever took its place.
  bool _presetSheetOpen = false;
  // Each tab owns its own scroll controller. During a slide transition both
  // tab bodies are briefly alive at once, so they must never share a single
  // controller (a controller attached to two scroll views throws). The sheet
  // is pointed at whichever controller belongs to the active tab.
  final _llmScrollController = ScrollController();
  final _embScrollController = ScrollController();
  final _agentsScrollController = ScrollController();
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
    _embRequestsPerMinuteCtrl,
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
    _agentsScrollController.dispose();
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
      closeExpandedToolScreen(context, ref);
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
    _embRequestsPerMinuteCtrl.text = draft.embeddingRequestsPerMinute;

    setState(() {
      _temperature = values.temperature;
      _topP = values.topP;
      _topK = values.topK;
      _frequencyPenalty = values.frequencyPenalty;
      _presencePenalty = values.presencePenalty;
      _stream = values.stream;
      _requestReasoning = values.requestReasoning;
      _customUseResponsesApi = values.useResponsesApi;
      _useSystemInstruction = values.useSystemInstruction;
      _showNativeReasoning = values.showNativeReasoning;
      _excludeReasoningFromContextBudget =
          values.excludeReasoningFromContextBudget;
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
      _promptPostProcessing = values.promptPostProcessing;
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
        useResponsesApi: _customUseResponsesApi,
        useSystemInstruction: _useSystemInstruction,
        showNativeReasoning: _showNativeReasoning,
        excludeReasoningFromContextBudget: _excludeReasoningFromContextBudget,
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
        promptPostProcessing: _promptPostProcessing,
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
      embeddingRequestsPerMinute: _embRequestsPerMinuteCtrl.text,
    );
    await _ref.read(apiListProvider.notifier).put(draft.toConfig(config));
  }

  bool get _supportsTemperature => true;

  bool get _supportsTopP => true;

  /// The Responses API has no `top_k` and no penalties, so those controls are
  /// hidden for it rather than shown and silently ignored.
  bool get _isResponses => _protocol == LlmProtocol.openaiResponses;

  bool get _supportsTopK =>
      _protocol == LlmProtocol.customChatCompletion ||
      _protocol == LlmProtocol.openrouter ||
      _protocol == LlmProtocol.anthropic ||
      _protocol == LlmProtocol.gemini;

  bool get _supportsFrequencyPenalty =>
      _protocol == LlmProtocol.openai ||
      _protocol == LlmProtocol.customChatCompletion ||
      _protocol == LlmProtocol.openrouter;

  bool get _supportsPresencePenalty =>
      _protocol == LlmProtocol.openai ||
      _protocol == LlmProtocol.customChatCompletion ||
      _protocol == LlmProtocol.openrouter;

  /// OpenRouter included: `buildRouterRequest` needs a live TTL to place
  /// `cache_control` markers for Claude-through-OR.
  bool get _supportsPromptCache =>
      _protocol == LlmProtocol.anthropic ||
      _protocol == LlmProtocol.customChatCompletion ||
      _protocol == LlmProtocol.openrouter;

  bool get _supportsReasoning => true;

  /// Only a custom endpoint has an unknown message-shape contract — see
  /// [_buildPromptPostProcessingGroup].
  bool get _supportsPromptPostProcessing =>
      _protocol == LlmProtocol.customChatCompletion;

  /// Protocols with a dedicated field for the leading system block. The field
  /// is named differently per provider, so the label carries its actual name.
  bool get _supportsSystemInstruction =>
      _protocol == LlmProtocol.gemini || _protocol == LlmProtocol.anthropic;

  String get _systemInstructionFieldName =>
      _protocol == LlmProtocol.anthropic ? 'system' : 'system_instruction';

  /// Official Responses is a protocol; Custom Chat Completion retains its
  /// endpoint-mode toggle for compatible custom backends.
  bool get _useResponsesApi =>
      _isResponses ||
      (_protocol == LlmProtocol.customChatCompletion && _customUseResponsesApi);

  // Every protocol accepts temperature and top_p, and every transport honors
  // the matching omit* flag, so the include toggles are shown unconditionally —
  // they used to be OpenAI-shaped only.

  bool get _hideSamplingWhileReasoningAnthropic =>
      _protocol == LlmProtocol.anthropic && _requestReasoning;

  /// Every protocol offers the same six steps, like SillyTavern — what a step
  /// becomes on the wire is decided at send time by `resolveReasoningEffort`,
  /// not by shrinking the dropdown.
  List<String> get _reasoningEffortOptions => reasoningEffortSteps;

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
      scrollController: switch (_tab) {
        0 => _llmScrollController,
        1 => _embScrollController,
        _ => _agentsScrollController,
      },
      // The LLM/Embeddings switcher stays fixed in the header so it never
      // slides with the tab bodies — a single segmented control that keeps its
      // own pill animation while the content swipes beneath it.
      headerBottom: list.isEmpty ? null : _buildTabBar(),
      body: asyncList.when(
        loading: () => const Center(child: GlazeSpinner()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
        data: (list) => list.isEmpty
            ? _buildEmptyState()
            : SwipeTabSwitcher(
                index: _tab,
                length: 3,
                onChanged: (i) => setState(() => _tab = i),
                child: TabSlideSwitcher(
                  index: _tab,
                  child: switch (_tab) {
                    0 => _buildLlmTab(list, activeName),
                    1 => _buildEmbeddingsTab(list, activeName),
                    _ => StudioSlotsTab(controller: _agentsScrollController),
                  },
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
        GlazeTabItem(
          label: 'studio_agents'.tr(),
          icon: Icons.smart_toy_outlined,
        ),
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
      onTap: list.isEmpty ? null : _showPresetSheet,
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
            onPressed: _createNewPreset,
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
          _buildConnectionGroup(context),
          _buildGenerationGroup(),
          _buildReasoningGroup(),
          // Everything below is for troubleshooting or provider quirks, not
          // day-to-day tuning — one tap away instead of in the way.
          MenuCollapsibleSection(
            label: 'section_advanced'.tr(),
            children: [
              _buildSamplingGroup(),
              _buildPromptPostProcessingGroup(),
              _buildCacheGroup(),
              _buildReasoningDeliveryGroup(),
              _buildOtherGroup(),
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
        ],
      ),
    );
  }

  Widget _buildConnectionGroup(BuildContext context) {
    return MenuGroup(
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
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _endpointCtrl,
            builder: (context, value, _) {
              final preview = EndpointPreview.resolve(
                rawEndpoint: value.text,
                protocol: _protocol,
                useResponsesApi: _useResponsesApi,
                model: _modelCtrl.text,
              );
              return MenuFieldItem(
                label: 'onboarding_label_endpoint'.tr(),
                controller: _endpointCtrl,
                placeholder: 'https://your-endpoint.example',
                helper: _endpointHelper(preview),
                helperIsError: preview.isInvalid,
              );
            },
          ),
        MenuFieldItem(
          label: 'onboarding_label_model'.tr(),
          controller: _modelCtrl,
          placeholder: 'gemini-3-pro-preview',
          suffix: _isLoadingModels
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 18, height: 18, child: GlazeSpinner()),
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
        MenuFieldItem(
          label: 'label_first_chunk_timeout'.tr(),
          helpTerm: 'first-chunk-timeout',
          description: 'desc_first_chunk_timeout'.tr(),
          controller: _firstChunkTimeoutCtrl,
          placeholder: '60',
          keyboardType: TextInputType.number,
        ),
      ],
    );
  }

  Widget _buildGenerationGroup() {
    return MenuGroup(
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
            included: !_omitTemperature,
            onIncludedChanged: (v) {
              setState(() => _omitTemperature = !v);
              _scheduleSave();
            },
            onChanged: (v) {
              setState(() => _temperature = v);
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
      ],
    );
  }

  Widget _buildReasoningGroup() {
    return MenuGroup(
      compact: true,
      header: 'label_reasoning_settings'.tr(),
      helpTerm: 'preset-reasoning',
      items: [
        if (_protocol == LlmProtocol.customChatCompletion)
          MenuSwitchItem(
            label: 'label_use_responses_api'.tr(),
            description: 'desc_use_responses_api'.tr(),
            value: _customUseResponsesApi,
            onChanged: (v) {
              setState(() => _customUseResponsesApi = v);
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
          MenuSwitchItem(
            label: 'label_request_native_reasoning'.tr(),
            description: 'desc_request_native_reasoning'.tr(),
            value: _requestReasoning && !_omitReasoning,
            onChanged: (v) {
              setState(() {
                _requestReasoning = v;
                _omitReasoning = false;
              });
              _scheduleSave();
            },
          ),
        if (_supportsReasoning)
          MenuSelectorItem(
            label: 'label_reasoning_effort'.tr(),
            helpTerm: 'reasoning-effort',
            currentValue: _reasoningEffortLabel(_reasoningEffort),
            included: !_omitReasoningEffort,
            onIncludedChanged: (v) {
              setState(() => _omitReasoningEffort = !v);
              _scheduleSave();
            },
            onTap: _openReasoningEffortSelector,
          ),
      ],
    );
  }

  // ── Advanced ──────────────────────────────────────────────────────────────

  Widget _buildSamplingGroup() {
    // Anthropic with thinking on hides every sampling control — don't leave an
    // empty card behind.
    final items = <Widget>[
      if (_supportsTopP && !_hideSamplingWhileReasoningAnthropic)
        MenuRangeItem(
          label: 'label_top_p'.tr(),
          helpTerm: 'top-p',
          value: _topP,
          min: 0,
          max: 1,
          divisions: 100,
          editableValue: true,
          included: !_omitTopP,
          onIncludedChanged: (v) {
            setState(() => _omitTopP = !v);
            _scheduleSave();
          },
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
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return MenuGroup(
      compact: true,
      header: 'section_sampling'.tr(),
      items: items,
    );
  }

  /// Reshapes the finished conversation to the message layout a given endpoint
  /// insists on — one system block, strictly alternating turns, no tool
  /// traffic. A property of the API, which is why it lives here and not in the
  /// prompt preset.
  ///
  /// Offered for custom endpoints only. Every first-party protocol already
  /// normalizes what its wire format requires inside its own converter (the
  /// Anthropic and Gemini ones lift the leading system run out and squash
  /// same-role neighbours), so the control would be a second, redundant knob
  /// there. A custom endpoint is the one case Glaze cannot know the shape of.
  Widget _buildPromptPostProcessingGroup() {
    if (!_supportsPromptPostProcessing) return const SizedBox.shrink();
    return MenuGroup(
      compact: true,
      header: 'section_prompt_post_processing'.tr(),
      helpTerm: 'prompt-post-processing',
      items: [
        MenuSelectorItem(
          label: 'label_prompt_post_processing'.tr(),
          description: 'desc_prompt_post_processing'.tr(),
          currentValue: _promptPostProcessingLabel(_promptPostProcessing),
          onTap: _openPromptPostProcessingSelector,
        ),
      ],
    );
  }

  /// `session_id` lives here rather than in Connection: its whole purpose is
  /// keeping the provider's prompt cache warm.
  Widget _buildCacheGroup() {
    return MenuGroup(
      compact: true,
      header: 'section_cache'.tr(),
      items: [
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
        MenuSwitchItem(
          label: 'label_session_id_mode'.tr(),
          helpTerm: 'session-id',
          value: _sessionIdMode == 'always',
          onChanged: (v) {
            setState(() => _sessionIdMode = v ? 'always' : 'off');
            _scheduleSave();
          },
        ),
      ],
    );
  }

  Widget _buildReasoningDeliveryGroup() {
    return MenuGroup(
      compact: true,
      header: 'section_reasoning_delivery'.tr(),
      items: [
        if (_supportsReasoning)
          MenuFieldItem(
            label: 'label_send_reasoning'.tr(),
            description: 'desc_send_reasoning'.tr(),
            controller: _reasoningHistoryCountCtrl,
            placeholder: '0',
            keyboardType: const TextInputType.numberWithOptions(signed: true),
          ),
        if (_supportsReasoning)
          MenuSwitchItem(
            label: 'label_exclude_reasoning_from_budget'.tr(),
            helpTerm: 'reasoning-budget',
            description: 'desc_exclude_reasoning_from_budget'.tr(),
            value: _excludeReasoningFromContextBudget,
            onChanged: (v) {
              setState(() => _excludeReasoningFromContextBudget = v);
              _scheduleSave();
            },
          ),
      ],
    );
  }

  /// Protocol-specific odds and ends. Empty for every protocol but Gemini, so
  /// it renders nothing rather than a bare header.
  Widget _buildOtherGroup() {
    if (!_supportsSystemInstruction) return const SizedBox.shrink();
    return MenuGroup(
      compact: true,
      header: 'section_other'.tr(),
      items: [
        MenuSwitchItem(
          label: 'label_use_system_instruction'.tr(
            namedArgs: {'field': _systemInstructionFieldName},
          ),
          helpTerm: 'system-instruction',
          value: _useSystemInstruction,
          onChanged: (v) {
            setState(() => _useSystemInstruction = v);
            _scheduleSave();
          },
        ),
      ],
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
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _embEndpointCtrl,
                    builder: (context, value, _) {
                      final preview = EndpointPreview.resolveEmbedding(
                        value.text,
                      );
                      return MenuFieldItem(
                        label: 'settings_embedding_endpoint'.tr(),
                        controller: _embEndpointCtrl,
                        placeholder: 'http://127.0.0.1:11434/v1',
                        helper: _endpointHelper(preview),
                        helperIsError: preview.isInvalid,
                      );
                    },
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
                MenuFieldItem(
                  label: 'settings_embedding_requests_per_minute'.tr(),
                  controller: _embRequestsPerMinuteCtrl,
                  placeholder: '50',
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
                        child: GlazeSpinner(),
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

  /// The presets sheet. Its rows are built from the providers on every rebuild
  /// (`cardsBuilder`), so switching the sort mode, dragging a row, deleting a
  /// preset or selecting several updates the open sheet in place — it is never
  /// closed and reopened to show the change.
  Future<void> _showPresetSheet() async {
    _presetSheetOpen = true;
    await GlazeBottomSheet.show<void>(
      context,
      title: 'settings_api_configs_title'.tr(),
      headerAction: Consumer(
        builder: (context, ref, _) {
          final selection = ref.watch(apiPresetSelectionProvider);
          if (selection.active) return _buildSelectionActions(selection);
          final mode =
              ref.watch(apiPresetSortProvider).value?.mode ??
              ApiPresetSortMode.manual;
          final armed = ref.watch(apiPresetReorderArmedProvider);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Only the manually ordered sheet has an order to drag rows into.
              if (mode == ApiPresetSortMode.manual) ...[
                GlazeReorderToggleButton(
                  armed: armed,
                  tooltip: 'sort_reorder'.tr(),
                  onTap: _toggleReorderArmed,
                ),
                const SizedBox(width: 8),
              ],
              GlazeSortIconChip(
                icon: mode.icon,
                tooltip: mode.label,
                onTap: () => _showSortPicker(mode),
              ),
              IconButton(
                icon: Icon(
                  Icons.add_circle_outline_rounded,
                  color: context.cs.primary,
                ),
                tooltip: 'settings_new_config_tooltip'.tr(),
                onPressed: () {
                  Navigator.of(context, rootNavigator: true).pop();
                  _createNewPreset();
                },
              ),
            ],
          );
        },
      ),
      cardsBuilder: (context, ref) {
        final list = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
        final sort =
            ref.watch(apiPresetSortProvider).value ??
            const ApiPresetSortState();
        final selection = ref.watch(apiPresetSelectionProvider);
        final reordering =
            sort.mode == ApiPresetSortMode.manual &&
            ref.watch(apiPresetReorderArmedProvider);
        // The active id falls back to the *repository's* first preset, the same
        // one activeApiConfigProvider picks — sorting only reorders what is
        // shown, so it must not move the highlight to another row.
        final activeId =
            ref.watch(activeApiPresetIdProvider) ??
            (list.isNotEmpty ? list.first.id : null);
        final sorted = sortApiConfigs(list, sort);
        return BottomSheetCards(
          items: [
            for (final config in sorted)
              _presetCard(
                config,
                activeId,
                selection: selection,
                reordering: reordering,
                canDelete: list.length > 1,
              ),
          ],
          onReorder: reordering
              ? (oldIndex, newIndex) =>
                    _onManualReorder(sorted, oldIndex, newIndex)
              : null,
        );
      },
    );
    _presetSheetOpen = false;
    if (!mounted) return;
    // The selection and the armed drag belong to the open sheet, not to the
    // screen behind it.
    ref.read(apiPresetSelectionProvider.notifier).clear();
    ref.read(apiPresetReorderArmedProvider.notifier).state = false;
  }

  /// What the sheet header shows while presets are selected: the count and the
  /// bulk actions, in place of the sort and add controls.
  Widget _buildSelectionActions(ApiPresetSelectionState selection) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${selection.count} ${'selected_count'.tr()}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: context.cs.onSurfaceVariant,
          ),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline_rounded, color: context.cs.error),
          tooltip: 'action_delete'.tr(),
          onPressed: () => _confirmDeleteSelected(selection),
        ),
        IconButton(
          icon: Icon(Icons.close_rounded, color: context.cs.onSurfaceVariant),
          tooltip: 'btn_cancel'.tr(),
          onPressed: () =>
              ref.read(apiPresetSelectionProvider.notifier).clear(),
        ),
      ],
    );
  }

  BottomSheetCardItem _presetCard(
    ApiConfig config,
    String? activeId, {
    required ApiPresetSelectionState selection,
    required bool reordering,
    required bool canDelete,
  }) {
    final isActive = config.id == activeId;
    final isSelected = selection.contains(config.id);
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
      id: config.id,
      label: name,
      sublabel: config.endpoint.isNotEmpty
          ? config.endpoint
                .replaceAll(RegExp(r'https?://'), '')
                .split('/')
                .first
          : null,
      // While selecting, the radio button gives way to a check mark: the row
      // now answers "is it picked", not "is it the connection in use".
      icon: selection.active
          ? (isSelected
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded)
          : (isActive
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded),
      faviconUrl: selection.active ? null : faviconUrl,
      isActive: selection.active ? isSelected : isActive,
      // While dragging is armed a long press lifts the row, so it can't also
      // open multi-select.
      onLongPress: reordering
          ? null
          : () =>
                ref.read(apiPresetSelectionProvider.notifier).start(config.id),
      actions: [
        // Bulk delete owns the header while selecting; per-row deletes would
        // only compete with it.
        if (canDelete && !selection.active)
          BottomSheetAction(
            icon: Icons.delete_outline_rounded,
            color: context.cs.onSurfaceVariant,
            onTap: () async {
              await ref.read(apiListProvider.notifier).remove(config.id);
              _reloadAfterDelete(activeId, {config.id});
            },
          ),
      ],
      onTap: () {
        if (selection.active) {
          ref.read(apiPresetSelectionProvider.notifier).toggle(config.id);
          return;
        }
        Navigator.of(context, rootNavigator: true).pop();
        _saveTimer?.cancel();
        ref.read(activeApiPresetIdProvider.notifier).state = config.id;
        _persistActiveId(config.id);
        _loadedPresetId = null;
        _loadFromConfig(config);
      },
    );
  }

  /// Moves the editor off a preset that was just deleted: clearing the active
  /// id lets [activeApiConfigProvider] fall back to the first one left.
  void _reloadAfterDelete(String? activeId, Set<String> removedIds) {
    if (activeId == null || !removedIds.contains(activeId)) return;
    ref.read(activeApiPresetIdProvider.notifier).state = null;
    _persistActiveId(null);
    _loadedPresetId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadActivePreset();
    });
  }

  /// Deletes every selected preset, after a confirmation. The sheet stays open
  /// and the rows simply go — unless nothing is left to show, which is the one
  /// case it closes itself.
  void _confirmDeleteSelected(ApiPresetSelectionState selection) {
    final ids = selection.ids.toList();
    if (ids.isEmpty) return;
    final list = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final activeId =
        ref.read(activeApiPresetIdProvider) ??
        (list.isNotEmpty ? list.first.id : null);
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'api_delete_many_confirm'.plural(ids.length),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(apiPresetSelectionProvider.notifier).clear();
            for (final id in ids) {
              // Each delete awaits a DB round-trip; bail out if the screen went
              // away in the meantime rather than reading a disposed ref.
              if (!mounted) return;
              await ref.read(apiListProvider.notifier).remove(id);
            }
            if (!mounted) return;
            _reloadAfterDelete(activeId, ids.toSet());
            final remaining = await ref.read(apiListProvider.future);
            // An empty sheet would be a header and nothing else.
            if (remaining.isEmpty && mounted && _presetSheetOpen) {
              Navigator.of(context, rootNavigator: true).pop();
            }
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  /// Commits a drag in the manually ordered sheet. The sheet lists every preset
  /// there is, so what the user dragged over *is* the full order.
  void _onManualReorder(List<ApiConfig> sorted, int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final order = [for (final config in sorted) config.id];
    order.insert(newIndex, order.removeAt(oldIndex));
    unawaited(ref.read(apiPresetSortProvider.notifier).setManualOrder(order));
  }

  /// Arms or disarms dragging in the sheet. Arming clears any multi-select —
  /// the two modes claim the same long press, so only one can be on.
  void _toggleReorderArmed() {
    final armed = !ref.read(apiPresetReorderArmedProvider);
    ref.read(apiPresetReorderArmedProvider.notifier).state = armed;
    if (!armed) return;
    ref.read(apiPresetSelectionProvider.notifier).clear();
    // Arming is the only moment the drag gesture needs explaining, so it is a
    // toast rather than a permanent hint.
    GlazeToast.show(context, 'preset_drag_hint'.tr());
  }

  /// Sort-mode picker, opened over the presets sheet: the sheet below follows
  /// the new mode on its own, so nothing has to be closed or reopened.
  void _showSortPicker(ApiPresetSortMode current) {
    showGlazePickerSheet(
      context,
      title: 'sort_by'.tr(),
      items: [
        for (final mode in ApiPresetSortMode.values)
          GlazePickerItem(
            label: mode.label,
            icon: mode.icon,
            hint: mode.hint,
            isActive: mode == current,
            value: mode,
          ),
      ],
      onSelect: (v) {
        final mode = v as ApiPresetSortMode;
        if (mode == current) return;
        // Another mode has no order to drag rows into: the toggle goes away,
        // so it must not stay armed behind it.
        if (mode != ApiPresetSortMode.manual) {
          ref.read(apiPresetReorderArmedProvider.notifier).state = false;
        }
        unawaited(ref.read(apiPresetSortProvider.notifier).setMode(mode));
      },
    );
  }

  Future<void> _createNewPreset() async {
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
      searchable: true,
      searchHint: 'settings_search_models'.tr(),
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

  /// What the step turns into on the wire for the selected protocol, shown as
  /// the option's hint so `Maximum → high` is not a surprise.
  String? _reasoningEffortHint(String effort) {
    if (effort == 'auto') return 'reasoning_effort_hint_auto'.tr();
    if (_protocol == LlmProtocol.anthropic || _protocol == LlmProtocol.gemini) {
      return 'reasoning_effort_hint_budget'.tr();
    }
    final resolved = resolveReasoningEffort(
      protocol: _protocol,
      effort: effort,
      model: _modelCtrl.text.trim(),
    );
    if (resolved == null || resolved == effort) return null;
    return 'reasoning_effort_hint_sent'.tr(namedArgs: {'value': resolved});
  }

  String _promptPostProcessingLabel(String mode) =>
      'prompt_post_processing_${PromptPostProcessing.baseOf(mode)}'.tr();

  void _openPromptPostProcessingSelector() {
    final current = PromptPostProcessing.baseOf(_promptPostProcessing);
    GlazeBottomSheet.show<void>(
      context,
      title: 'label_prompt_post_processing'.tr(),
      items: PromptPostProcessing.uiModes.map((mode) {
        return BottomSheetItem(
          label: 'prompt_post_processing_$mode'.tr(),
          // Each mode is a mechanical transformation; spelling out what it
          // does to the messages beats a name nobody can decode at a glance.
          hint: 'prompt_post_processing_hint_$mode'.tr(),
          icon: mode == current ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(
              () =>
                  _promptPostProcessing = PromptPostProcessing.withTools(mode),
            );
            _scheduleSave();
          },
        );
      }).toList(),
    );
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
          hint: _reasoningEffortHint(e),
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

  /// Caption under an endpoint field: the URL the request will actually go
  /// to, or a warning when the text is not a URL at all.
  String? _endpointHelper(EndpointPreview preview) {
    if (preview.isInvalid) return 'settings_endpoint_invalid'.tr();
    if (preview.isEmpty) return null;
    return 'settings_endpoint_resolves_to'.tr(namedArgs: {'url': preview.url});
  }

  /// After a successful test, adopt the URL the transport actually reached.
  ///
  /// The candidate walk that rescued a wrong base path lives in memory only,
  /// so writing the working URL back into the field makes the fix permanent —
  /// a complete URL is used verbatim by the normalizer, no path guessing.
  void _adoptResolvedEndpoint() {
    final raw = _endpointCtrl.text.trim();
    if (raw.isEmpty || _protocol == LlmProtocol.openrouter) return;
    final resolvedBase = EndpointResolutionCache.resolvedBase(raw);
    if (resolvedBase == null) return;
    if (resolvedBase == EndpointNormalizer.parse(raw).base) return;

    final route = switch (_protocol) {
      LlmProtocol.anthropic => '/messages',
      LlmProtocol.gemini => '',
      _ => _useResponsesApi ? '/responses' : '/chat/completions',
    };
    if (route.isEmpty) return;

    _endpointCtrl.text = '$resolvedBase$route';
    if (mounted) {
      GlazeToast.show(
        context,
        'settings_endpoint_autofixed'.tr(
          namedArgs: {'url': _endpointCtrl.text},
        ),
      );
    }
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
      final persistedEndpoint = EndpointNormalizer.persistedLlmEndpoint(
        raw: endpoint,
        protocol: _protocol,
        model: _modelCtrl.text,
        stream: _stream,
        useResponsesApi: _useResponsesApi,
      );
      final models = await pickChatTransport(
        _protocol,
      ).fetchModels(endpoint: persistedEndpoint, apiKey: apiKey);
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
        _adoptResolvedEndpoint();
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
