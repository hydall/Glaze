import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../core/llm/converters/reasoning_effort.dart';
import '../../core/llm/converters/prompt_post_processing.dart';
import '../../core/llm/model_fetcher.dart';
import '../../core/llm/transport/endpoint_normalizer.dart';
import '../../core/llm/transport/endpoint_preview.dart';
import '../../core/llm/transport/endpoint_resolution_cache.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/llm/transport/transport_factory.dart';
import '../../core/services/api_connection_tester.dart';
import '../chat/state/token_breakdown_cache.dart';
import '../chat/state/cached_token_breakdown.dart';
import '../../core/llm/history_trim.dart';
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

/// A section of the API screen a caller can open it *on*.
enum ApiSettingsSection { context }

class ApiSettingsScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  /// Scrolls to this section once the first frame is laid out. The Prompt
  /// Inspector's cutoff notice uses it to land on the context window rather
  /// than at the top of a long form.
  final ApiSettingsSection? focusSection;

  const ApiSettingsScreen({
    super.key,
    this.startExpanded = false,
    this.focusSection,
  });

  @override
  ConsumerState<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends ConsumerState<ApiSettingsScreen> {
  int _tab = 0; // 0 = LLM, 1 = Embeddings, 2 = Studio agents

  bool _showApiKey = false;
  bool _showEmbApiKey = false;
  bool _isLoadingModels = false;
  ApiConnectionStatus _llmStatus = ApiConnectionStatus.idle;
  String _llmError = '';
  ApiConnectionStatus _embStatus = ApiConnectionStatus.idle;
  String _embError = '';
  List<Map<String, dynamic>> _fetchedModels = [];

  bool _isLoadingEmbModels = false;

  /// Model ids offered by the embedding connection, cached until the preset,
  /// the protocol or the "use LLM API" toggle changes the connection they
  /// came from.
  List<String> _embFetchedModels = [];

  // Text controllers
  final _nameCtrl = TextEditingController();
  final _endpointCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _maxTokensCtrl = TextEditingController();
  final _contextSizeCtrl = TextEditingController();
  final _firstChunkTimeoutCtrl = TextEditingController();
  final _reasoningHistoryCountCtrl = TextEditingController();
  final _embNameCtrl = TextEditingController();
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

  /// The LLM preset "Use LLM API" borrows its endpoint from. Empty means
  /// "whichever connection the LLM tab is on".
  String _embeddingLlmPresetId = '';
  String _cacheControlTtl = 'off';
  String _cacheBreakpointMode = 'depth';
  String _historyTrimMode = HistoryTrimMode.sliding;
  int _historyTrimTriggerPercent = kDefaultHistoryTrimTriggerPercent;
  int _historyTrimStepPercent = kDefaultHistoryTrimStepPercent;

  /// Scroll target for a deep link that opens this screen *on* the context
  /// settings — the Prompt Inspector's cutoff notice links here.
  final GlobalKey _contextGroupKey = GlobalKey();

  /// Runs once: a deep link names a section, and the form it lives in is only
  /// measurable after the first layout pass.
  void _scrollToFocusSection() {
    if (widget.focusSection != ApiSettingsSection.context) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _contextGroupKey.currentContext;
      if (target == null || !mounted) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
    });
  }

  String _sessionIdMode = 'openrouter';
  String _promptPostProcessing = PromptPostProcessing.none;
  String _protocol = LlmProtocol.openai;
  List<ExtraRequestParameter> _extraRequestParameters = const [];

  String? _loadedPresetId;

  /// The preset the *embedding* half of the editor is loaded from. It follows
  /// the LLM one only until the user picks another on the Embeddings tab —
  /// the two selections are independent from then on.
  String? _loadedEmbeddingPresetId;

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
    _embNameCtrl,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadActivePreset();
      _scrollToFocusSection();
    });
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

  /// The list a tab writes its presets to.
  ApiPresetWriter _presetNotifier(bool forEmbedding) => forEmbedding
      ? ref.read(embeddingPresetListProvider.notifier)
      : ref.read(apiListProvider.notifier);

  void _persistActiveEmbeddingId(String? id) async {
    final prefs = ref.read(sharedPreferencesProvider).value;
    if (prefs == null) return;
    if (id != null) {
      await prefs.setString(kActiveEmbeddingConfigIdKey, id);
    } else {
      await prefs.remove(kActiveEmbeddingConfigIdKey);
    }
  }

  void _loadActivePreset() {
    final config = ref.read(activeApiConfigProvider);
    if (config != null) _loadFromConfig(config);
    final embeddingConfig = ref.read(activeEmbeddingConfigProvider);
    if (embeddingConfig != null) _loadEmbeddingFromConfig(embeddingConfig);
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
      _cacheControlTtl = values.cacheControlTtl;
      _cacheBreakpointMode = values.cacheBreakpointMode;
      _historyTrimMode = HistoryTrimMode.normalize(values.historyTrimMode);
      _historyTrimTriggerPercent = values.historyTrimTriggerPercent;
      _historyTrimStepPercent = values.historyTrimStepPercent;
      _sessionIdMode = values.sessionIdMode;
      _promptPostProcessing = values.promptPostProcessing;
      _protocol = values.protocol;
      _extraRequestParameters = values.extraRequestParameters;
      _fetchedModels = [];
      // With "Use LLM API" on, the embedding model list was fetched from this
      // connection, so it goes with the preset it came from.
      if (_embeddingUseSame) _embFetchedModels = [];
    });

    _loading = false;
  }

  /// Loads the embedding half of the editor from the preset the Embeddings tab
  /// points at — [activeEmbeddingConfigProvider], which is not necessarily the
  /// preset the LLM tab is on.
  void _loadEmbeddingFromConfig(ApiConfig config) {
    if (config.id == _loadedEmbeddingPresetId) return;
    _loadedEmbeddingPresetId = config.id;
    _loading = true;
    final draft = ApiConfigDraft.fromConfig(config);

    _embNameCtrl.text = draft.name;
    _embEndpointCtrl.text = draft.embeddingEndpoint;
    _embApiKeyCtrl.text = draft.embeddingApiKey;
    _embModelCtrl.text = draft.embeddingModel;
    _embChunkTokensCtrl.text = draft.embeddingMaxChunkTokens;
    _embRequestsPerMinuteCtrl.text = draft.embeddingRequestsPerMinute;

    setState(() {
      _embeddingEnabled = draft.values.embeddingEnabled;
      _embeddingUseSame = draft.values.embeddingUseSame;
      _embeddingLlmPresetId = draft.values.embeddingLlmPresetId;
      // Both the model list and the connection badge describe the preset that
      // was open a moment ago.
      _embFetchedModels = [];
      _embStatus = ApiConnectionStatus.idle;
      _embError = '';
    });

    _loading = false;
  }

  Future<void> _save() async {
    final config = _ref.read(activeApiConfigProvider);
    final embeddingConfig = _ref.read(activeEmbeddingConfigProvider);
    if (config == null && embeddingConfig == null) return;
    // Either tab can be the only one with a preset open — the editor still
    // saves the half that has one. The base only supplies the fields the
    // written half does not carry.
    final draft = ApiConfigDraft(
      values: (config ?? embeddingConfig!).copyWith(
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
        embeddingLlmPresetId: _embeddingLlmPresetId,
        cacheControlTtl: _cacheControlTtl,
        cacheBreakpointMode: _cacheBreakpointMode,
        historyTrimMode: _historyTrimMode,
        historyTrimTriggerPercent: _historyTrimTriggerPercent,
        historyTrimStepPercent: _historyTrimStepPercent,
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
    // Each tab owns a preset from its own list, so each half is written to its
    // own row: a save from the LLM tab must never copy this editor's embedding
    // fields onto the LLM preset, nor the other way round.
    if (config != null) {
      final updated = draft.applyLlmTo(config);
      // The window and the trim mode decide which messages survive into the
      // prompt, so every cached breakdown taken under the old values is stale
      // the moment this lands — including the ones on surfaces nobody has open
      // right now (the drawer's stats, the context card under the chat header).
      final budgetChanged =
          updated.contextBudgetSignature != config.contextBudgetSignature;
      await _ref.read(apiListProvider.notifier).put(updated);
      if (budgetChanged) {
        TokenBreakdownCache.invalidate();
        _ref.invalidate(cachedTokenBreakdownProvider);
      }
    }
    if (embeddingConfig == null) return;
    await _ref
        .read(embeddingPresetListProvider.notifier)
        .put(
          draft
              .applyEmbeddingTo(embeddingConfig)
              .copyWith(name: _embNameCtrl.text.trim()),
        );
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
    final asyncEmbeddingList = ref.watch(embeddingPresetListProvider);
    final activeConfig = ref.watch(activeApiConfigProvider);
    final embeddingConfig = ref.watch(activeEmbeddingConfigProvider);

    if (activeConfig != null && activeConfig.id != _loadedPresetId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadFromConfig(activeConfig);
      });
    }
    if (embeddingConfig != null &&
        embeddingConfig.id != _loadedEmbeddingPresetId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadEmbeddingFromConfig(embeddingConfig);
      });
    }

    final list = asyncList.value ?? [];
    final embeddingList = asyncEmbeddingList.value ?? const <ApiConfig>[];
    final activeName = _activeName(activeConfig, list);
    final embeddingName = _activeName(embeddingConfig, embeddingList);

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
      // The tab bar goes away only while there is nothing at all to configure;
      // an empty Embeddings list is the tab's own empty state, not the screen's.
      headerBottom: list.isEmpty && embeddingList.isEmpty
          ? null
          : _buildTabBar(),
      body: asyncList.when(
        loading: () => const Center(child: GlazeSpinner()),
        error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
        data: (list) => list.isEmpty && embeddingList.isEmpty
            ? _buildEmptyState(forEmbedding: false)
            : SwipeTabSwitcher(
                index: _tab,
                length: 3,
                onChanged: (i) => setState(() => _tab = i),
                child: TabSlideSwitcher(
                  index: _tab,
                  child: switch (_tab) {
                    0 =>
                      list.isEmpty
                          ? _buildEmptyState(forEmbedding: false)
                          : _buildLlmTab(list, activeName),
                    1 =>
                      embeddingList.isEmpty
                          ? _buildEmptyState(forEmbedding: true)
                          : _buildEmbeddingsTab(
                              embeddingList,
                              list,
                              embeddingName,
                            ),
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

  /// The preset pill plus its connection badge, above each tab's settings.
  ///
  /// [forEmbedding] decides which selection the pill speaks for: the LLM tab
  /// switches the chat connection, the Embeddings tab the one embeddings run
  /// on. The flag is passed rather than read off `_tab` because both tab
  /// bodies are alive during a slide, and each must keep showing its own.
  Widget _buildTopControls(
    List<ApiConfig> list,
    String presetName, {
    required bool forEmbedding,
  }) {
    final pill = _buildPresetPill(
      context,
      list,
      presetName,
      forEmbedding: forEmbedding,
    );
    if (!forEmbedding) {
      return ConnectionStatus(
        status: _llmStatus,
        errorMessage: _llmError,
        onRetry: _testLlmConnection,
        child: pill,
      );
    }
    // Nothing to probe until the preset has embeddings switched on, so the
    // badge appears with the rest of the embedding settings. Without it the
    // pill is alone under a full-width tight constraint, which would stretch
    // it across the row — Align hands it loose ones so it keeps its own size,
    // exactly as it has inside ConnectionStatus's Row.
    if (!_embeddingEnabled) {
      return Align(alignment: Alignment.centerLeft, child: pill);
    }
    return ConnectionStatus(
      status: _embStatus,
      errorMessage: _embError,
      onRetry: _testEmbConnection,
      child: pill,
    );
  }

  Widget _buildPresetPill(
    BuildContext context,
    List<ApiConfig> list,
    String activeName, {
    required bool forEmbedding,
  }) {
    return GestureDetector(
      onTap: list.isEmpty
          ? null
          : () => _showPresetSheet(forEmbedding: forEmbedding),
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

  Widget _buildEmptyState({required bool forEmbedding}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            forEmbedding ? Icons.layers_outlined : Icons.cloud,
            size: 64,
            color: context.cs.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            forEmbedding
                ? 'settings_no_embedding_configs'.tr()
                : 'settings_no_api_configs'.tr(),
            style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => _createNewPreset(forEmbedding: forEmbedding),
            child: Text(
              forEmbedding
                  ? 'settings_add_embedding_config'.tr()
                  : 'settings_add_api_config'.tr(),
            ),
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
            child: _buildTopControls(list, activeName, forEmbedding: false),
          ),
          _buildConnectionGroup(context),
          _buildContextGroup(),
          _buildGenerationGroup(),
          _buildReasoningGroup(),
          // Everything below is for troubleshooting or provider quirks, not
          // day-to-day tuning — one tap away instead of in the way.
          MenuCollapsibleSection(
            label: 'section_advanced'.tr(),
            children: [
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

  /// The window the prompt is cut against, and how it is cut.
  ///
  /// `contextSize` and `maxTokens` used to sit among the sampling knobs, which
  /// put the two numbers that decide what the model *sees* next to the ones
  /// that decide how it writes. They belong with the trim mode that spends
  /// them.
  Widget _buildContextGroup() {
    return MenuGroup(
      key: _contextGroupKey,
      compact: true,
      header: 'section_context'.tr(),
      items: [
        // No description here: the two modes are explained where the choice is
        // actually made, in the picker's hints. Repeating it under the closed
        // dropdown pushed the fields it belongs with off the screen.
        MenuSelectorItem(
          label: 'label_history_trim_mode'.tr(),
          currentValue: _historyTrimModeLabel(_historyTrimMode),
          onTap: _openHistoryTrimModeSelector,
        ),
        // Only stepped spends them; under sliding they would be two dead rows.
        if (_historyTrimMode == HistoryTrimMode.stepped) ...[
          MenuRangeItem(
            label: 'label_history_trim_threshold'.tr(),
            description: 'desc_history_trim_threshold'.tr(),
            value: _historyTrimTriggerPercent.toDouble(),
            min: 10,
            max: 100,
            divisions: 90,
            decimalPlaces: 0,
            editableValue: true,
            onChanged: (v) {
              setState(() => _historyTrimTriggerPercent = v.round());
              _scheduleSave();
            },
          ),
          MenuRangeItem(
            label: 'label_history_trim_step'.tr(),
            description: 'desc_history_trim_step'.tr(),
            value: _historyTrimStepPercent.toDouble(),
            min: 5,
            max: 95,
            divisions: 90,
            decimalPlaces: 0,
            editableValue: true,
            onChanged: (v) {
              setState(() => _historyTrimStepPercent = v.round());
              _scheduleSave();
            },
          ),
        ],
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

  String _historyTrimModeLabel(String mode) => mode == HistoryTrimMode.stepped
      ? 'history_trim_stepped'.tr()
      : 'history_trim_sliding'.tr();

  String _historyTrimModeDescription(String mode) =>
      mode == HistoryTrimMode.stepped
      ? 'history_trim_stepped_hint'.tr()
      : 'history_trim_sliding_hint'.tr();

  void _openHistoryTrimModeSelector() {
    GlazeBottomSheet.show<void>(
      context,
      title: 'label_history_trim_mode'.tr(),
      items: HistoryTrimMode.all.map((mode) {
        final active = mode == _historyTrimMode;
        return BottomSheetItem(
          label: _historyTrimModeLabel(mode),
          hint: _historyTrimModeDescription(mode),
          icon: active ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            setState(() => _historyTrimMode = mode);
            _scheduleSave();
          },
        );
      }).toList(),
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
        ..._samplingItems(),
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

  /// Sampling knobs, inlined into the generation group.
  ///
  /// They used to be a card of their own behind "Advanced", which hid the
  /// controls people reach for most often behind a disclosure. Returns a list
  /// rather than a group so an all-hidden protocol (Anthropic with thinking on)
  /// simply contributes nothing.
  List<Widget> _samplingItems() {
    return <Widget>[
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

  /// [presets] is the Embeddings tab's own list — what the pill and its sheet
  /// switch between. [chatPresets] is the LLM list, offered by the
  /// "endpoint from" row under the *Use LLM API* toggle.
  Widget _buildEmbeddingsTab(
    List<ApiConfig> presets,
    List<ApiConfig> chatPresets,
    String embeddingName,
  ) {
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
            child: _buildTopControls(
              presets,
              embeddingName,
              forEmbedding: true,
            ),
          ),
          MenuGroup(
            compact: true,
            header: 'tab_embeddings'.tr(),
            helpTerm: 'embeddings',
            items: [
              MenuFieldItem(
                label: 'settings_config_name'.tr(),
                controller: _embNameCtrl,
                placeholder: 'My embeddings',
              ),
              MenuSwitchItem(
                label: 'search_type_vector'.tr(),
                description: 'settings_enable_vector_desc'.tr(),
                value: _embeddingEnabled,
                onChanged: (v) {
                  setState(() => _embeddingEnabled = v);
                  final config = ref.read(activeEmbeddingConfigProvider);
                  if (config != null) {
                    ref
                        .read(embeddingPresetListProvider.notifier)
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
                    // The list was fetched from the other connection.
                    setState(() {
                      _embeddingUseSame = v;
                      _embFetchedModels = [];
                      _embStatus = ApiConnectionStatus.idle;
                      _embError = '';
                    });
                    _scheduleSave();
                  },
                ),
                // Which LLM preset the borrowed endpoint comes from. Without
                // it the answer was implicit — whatever the LLM tab happened
                // to be on — which is exactly what the two tabs no longer
                // share.
                if (_embeddingUseSame)
                  MenuSelectorItem(
                    label: 'settings_embedding_llm_preset'.tr(),
                    description: 'settings_embedding_llm_preset_desc'.tr(),
                    currentValue: _embeddingLlmPresetName(chatPresets),
                    onTap: () => _openEmbeddingLlmPresetSelector(chatPresets),
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
                  _buildEmbeddingModelField(),
                  MenuFieldItem(
                    label: 'onboarding_label_key'.tr(),
                    helpTerm: 'apikey',
                    controller: _embApiKeyCtrl,
                    placeholder: 'sk-...',
                    obscure: !_showEmbApiKey,
                    suffix: IconButton(
                      icon: Icon(
                        _showEmbApiKey
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: context.cs.onSurfaceVariant,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _showEmbApiKey = !_showEmbApiKey),
                    ),
                  ),
                ],
                if (_embeddingUseSame) _buildEmbeddingModelField(),
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
        ],
      ),
    );
  }

  /// The embedding-model row, shared by both branches of "use LLM API".
  ///
  /// Mirrors the LLM tab's model field: free text plus a chevron that fetches
  /// the model list from whichever connection the embedding request will
  /// actually use, and opens the same searchable picker.
  Widget _buildEmbeddingModelField() {
    return MenuFieldItem(
      label: 'settings_embedding_model'.tr(),
      controller: _embModelCtrl,
      placeholder: 'text-embedding-3-small',
      suffix: _isLoadingEmbModels
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
              tooltip: _embFetchedModels.isEmpty
                  ? 'settings_fetch_models'.tr()
                  : 'settings_select_model'.tr(),
              onPressed: _openEmbeddingModelSelector,
            ),
    );
  }

  /// The name shown by the "endpoint from" row: the LLM preset the embedding
  /// preset names, or the connection the LLM tab is on when it names none.
  String _embeddingLlmPresetName(List<ApiConfig> chatPresets) {
    if (_embeddingLlmPresetId.isEmpty) return 'studio_slot_use_chat_api'.tr();
    for (final config in chatPresets) {
      if (config.id != _embeddingLlmPresetId) continue;
      if (config.name.isNotEmpty) return config.name;
      if (config.model.isNotEmpty) return config.model;
      return 'unnamed_entry'.tr();
    }
    // The named preset was deleted; the request falls back to the active one.
    return 'studio_slot_use_chat_api'.tr();
  }

  void _openEmbeddingLlmPresetSelector(List<ApiConfig> chatPresets) {
    BottomSheetItem radio(String id, String label) => BottomSheetItem(
      label: label,
      icon: _embeddingLlmPresetId == id
          ? Icons.radio_button_checked
          : Icons.radio_button_off,
      iconColor: _embeddingLlmPresetId == id
          ? context.cs.primary
          : context.cs.onSurfaceVariant,
      onTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        // The model list and the badge belong to the connection that was
        // selected a moment ago.
        setState(() {
          _embeddingLlmPresetId = id;
          _embFetchedModels = [];
          _embStatus = ApiConnectionStatus.idle;
          _embError = '';
        });
        _scheduleSave();
      },
    );

    GlazeBottomSheet.show<void>(
      context,
      title: 'settings_embedding_llm_preset'.tr(),
      items: [
        radio('', 'studio_slot_use_chat_api'.tr()),
        for (final config in chatPresets)
          radio(
            config.id,
            config.name.isNotEmpty
                ? config.name
                : (config.model.isNotEmpty
                      ? config.model
                      : 'unnamed_entry'.tr()),
          ),
      ],
    );
  }

  /// The LLM connection "use LLM API" borrows, as the request will see it: the
  /// preset named by the row — already persisted, so its endpoint is stored
  /// normalized — or the connection the LLM tab is on, whose fields are still
  /// being edited and so are read from the controllers.
  ApiConfig? _embeddingLlmSource() {
    if (_embeddingLlmPresetId.isNotEmpty) {
      final list = ref.read(apiListProvider).value ?? const <ApiConfig>[];
      for (final config in list) {
        if (config.id == _embeddingLlmPresetId) return config;
      }
    }
    final endpoint = EndpointNormalizer.persistedLlmEndpoint(
      raw: _endpointCtrl.text.trim(),
      protocol: _protocol,
      model: _modelCtrl.text.trim(),
      stream: _stream,
      useResponsesApi: _useResponsesApi,
    );
    if (endpoint.isEmpty) return null;
    return ApiConfig(
      id: '',
      endpoint: endpoint,
      apiKey: _keyCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
      protocol: _protocol,
    );
  }

  /// The connection the embedding model list is fetched from, mirroring what
  /// `resolveEmbeddingConfig` feeds the request: the borrowed LLM connection
  /// while "use LLM API" is on, the dedicated embedding one otherwise.
  ///
  /// The endpoint goes through the same persistence normalization the repo
  /// applies, so a protocol with a fixed URL (OpenRouter, whose endpoint field
  /// is hidden) resolves here exactly as it does at request time. Returns null
  /// when there is nothing to fetch from yet.
  ApiConfig? _embeddingModelSource() {
    if (_embeddingUseSame) {
      final source = _embeddingLlmSource();
      if (source == null || source.endpoint.isEmpty) return null;
      return ApiConfig(
        id: '',
        endpoint: source.endpoint,
        apiKey: source.apiKey,
        protocol: source.protocol,
      );
    }
    final raw = _embEndpointCtrl.text.trim();
    if (raw.isEmpty) return null;
    // A dedicated embedding endpoint speaks the OpenAI-compatible surface
    // (`/embeddings`, `/models`) whatever protocol the chat side uses.
    return ApiConfig(
      id: '',
      endpoint: EndpointNormalizer.persistedEmbeddingEndpoint(raw),
      apiKey: _embApiKeyCtrl.text.trim(),
      protocol: LlmProtocol.customChatCompletion,
    );
  }

  Future<void> _fetchEmbeddingModels() async {
    final source = _embeddingModelSource();
    if (source == null || source.apiKey.isEmpty) {
      GlazeToast.show(context, 'settings_err_endpoint_key'.tr());
      return;
    }
    setState(() => _isLoadingEmbModels = true);
    try {
      final ids = await ModelFetcher.fetchModelIds(source);
      if (!mounted) return;
      setState(() {
        _embFetchedModels = ids;
        _isLoadingEmbModels = false;
      });
      if (ids.isEmpty) {
        GlazeToast.show(context, 'settings_err_no_models'.tr());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingEmbModels = false);
        GlazeErrorDialog.show(context, e, prefix: 'settings_err_failed'.tr());
      }
    }
  }

  Future<void> _openEmbeddingModelSelector() async {
    if (_embFetchedModels.isEmpty) {
      await _fetchEmbeddingModels();
      if (_embFetchedModels.isEmpty) return;
    }
    if (!mounted) return;
    final models = List<String>.from(_embFetchedModels);
    final current = _embModelCtrl.text.trim();
    // A model typed by hand (or one the provider does not list) stays
    // selectable instead of silently dropping out of the picker.
    if (current.isNotEmpty && !models.contains(current)) {
      models.insert(0, current);
    }
    final selectedIndex = models.indexOf(current);
    await GlazeBottomSheet.show<void>(
      context,
      title: 'settings_embedding_model'.tr(),
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
                _embModelCtrl.text = m;
              },
            ),
          )
          .toList(),
    );
  }

  // ── Sheet actions ─────────────────────────────────────────────────────────────

  /// The presets sheet. Its rows are built from the providers on every rebuild
  /// (`cardsBuilder`), so switching the sort mode, dragging a row, deleting a
  /// preset or selecting several updates the open sheet in place — it is never
  /// closed and reopened to show the change.
  ///
  /// [forEmbedding] picks the list it shows and the selection a tap moves: the
  /// Embeddings tab has presets of its own, so the two sheets never share a
  /// row.
  Future<void> _showPresetSheet({required bool forEmbedding}) async {
    _presetSheetOpen = true;
    await GlazeBottomSheet.show<void>(
      context,
      // Same list, two roles — the title says which one a tap is choosing.
      title: forEmbedding
          ? 'settings_embedding_config_title'.tr()
          : 'settings_api_configs_title'.tr(),
      headerAction: Consumer(
        builder: (context, ref, _) {
          final selection = ref.watch(apiPresetSelectionProvider);
          if (selection.active) {
            return _buildSelectionActions(
              selection,
              forEmbedding: forEmbedding,
            );
          }
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
                  _createNewPreset(forEmbedding: forEmbedding);
                },
              ),
            ],
          );
        },
      ),
      cardsBuilder: (context, ref) {
        final list =
            ref
                .watch(
                  forEmbedding ? embeddingPresetListProvider : apiListProvider,
                )
                .value ??
            const <ApiConfig>[];
        final sort =
            ref.watch(apiPresetSortProvider).value ??
            const ApiPresetSortState();
        final selection = ref.watch(apiPresetSelectionProvider);
        final reordering =
            sort.mode == ApiPresetSortMode.manual &&
            ref.watch(apiPresetReorderArmedProvider);
        // The active id falls back to the *repository's* first preset, the same
        // one activeApiConfigProvider (or its embedding twin) picks — sorting
        // only reorders what is shown, so it must not move the highlight to
        // another row.
        final activeId =
            (forEmbedding
                ? ref.watch(activeEmbeddingPresetIdProvider)
                : ref.watch(activeApiPresetIdProvider)) ??
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
                // The Embeddings tab has an empty state of its own, so its
                // last preset may go; the chat side always keeps one.
                canDelete: forEmbedding || list.length > 1,
                forEmbedding: forEmbedding,
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
  Widget _buildSelectionActions(
    ApiPresetSelectionState selection, {
    required bool forEmbedding,
  }) {
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
          onPressed: () =>
              _confirmDeleteSelected(selection, forEmbedding: forEmbedding),
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
    required bool forEmbedding,
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
              await _presetNotifier(forEmbedding).remove(config.id);
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
        if (forEmbedding) {
          // Only the embedding side moves: the chat connection stays where it
          // is, and so does everything the LLM tab holds.
          ref.read(activeEmbeddingPresetIdProvider.notifier).state = config.id;
          _persistActiveEmbeddingId(config.id);
          _loadedEmbeddingPresetId = null;
          _loadEmbeddingFromConfig(config);
          return;
        }
        ref.read(activeApiPresetIdProvider.notifier).state = config.id;
        _persistActiveId(config.id);
        _loadedPresetId = null;
        _loadFromConfig(config);
      },
    );
  }

  /// Moves the editor off a preset that was just deleted: clearing the active
  /// id lets [activeApiConfigProvider] — and [activeEmbeddingConfigProvider],
  /// which can be sitting on a different preset — fall back to the first one
  /// left.
  void _reloadAfterDelete(String? activeId, Set<String> removedIds) {
    var moved = false;
    if (activeId != null && removedIds.contains(activeId)) {
      ref.read(activeApiPresetIdProvider.notifier).state = null;
      _persistActiveId(null);
      _loadedPresetId = null;
      moved = true;
    }
    final embeddingId = ref.read(activeEmbeddingPresetIdProvider);
    if (embeddingId != null && removedIds.contains(embeddingId)) {
      ref.read(activeEmbeddingPresetIdProvider.notifier).state = null;
      _persistActiveEmbeddingId(null);
      _loadedEmbeddingPresetId = null;
      moved = true;
    }
    if (!moved) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadActivePreset();
    });
  }

  /// Deletes every selected preset, after a confirmation. The sheet stays open
  /// and the rows simply go — unless nothing is left to show, which is the one
  /// case it closes itself.
  void _confirmDeleteSelected(
    ApiPresetSelectionState selection, {
    required bool forEmbedding,
  }) {
    final ids = selection.ids.toList();
    if (ids.isEmpty) return;
    final list =
        ref
            .read(forEmbedding ? embeddingPresetListProvider : apiListProvider)
            .value ??
        const <ApiConfig>[];
    final activeId =
        (forEmbedding
            ? ref.read(activeEmbeddingPresetIdProvider)
            : ref.read(activeApiPresetIdProvider)) ??
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
              await _presetNotifier(forEmbedding).remove(id);
            }
            if (!mounted) return;
            _reloadAfterDelete(activeId, ids.toSet());
            final remaining = await ref.read(
              forEmbedding
                  ? embeddingPresetListProvider.future
                  : apiListProvider.future,
            );
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

  /// Creates a preset and points the tab it was created from at it: a preset
  /// added from the Embeddings tab becomes the embedding connection, leaving
  /// the chat one alone.
  Future<void> _createNewPreset({bool forEmbedding = false}) async {
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
            mode: forEmbedding ? kEmbeddingPresetMode : 'chat',
          );
          if (forEmbedding) {
            ref.read(activeEmbeddingPresetIdProvider.notifier).state =
                newConfig.id;
            _persistActiveEmbeddingId(newConfig.id);
            _loadedEmbeddingPresetId = null;
            _loadEmbeddingFromConfig(newConfig);
          } else {
            ref.read(activeApiPresetIdProvider.notifier).state = newConfig.id;
            _persistActiveId(newConfig.id);
            _loadedPresetId = null;
            _loadFromConfig(newConfig);
          }
          await _presetNotifier(forEmbedding).put(newConfig);
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
              _embFetchedModels = [];
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

  /// After a successful embedding test, adopt the URL the request actually
  /// reached — the mirror of [_adoptResolvedEndpoint] for the dedicated
  /// endpoint field, so a rescued base path is not re-walked on every launch.
  ///
  /// With "use LLM API" on there is no field here to write to: the URL belongs
  /// to the LLM preset, and the LLM tab's own test adopts it there.
  void _adoptResolvedEmbeddingEndpoint() {
    if (_embeddingUseSame) return;
    final raw = _embEndpointCtrl.text.trim();
    if (raw.isEmpty) return;
    final resolvedBase = EndpointResolutionCache.resolvedBase(raw);
    if (resolvedBase == null) return;
    if (resolvedBase == EndpointNormalizer.parse(raw).base) return;

    _embEndpointCtrl.text = '$resolvedBase/embeddings';
    if (mounted) {
      GlazeToast.show(
        context,
        'settings_endpoint_autofixed'.tr(
          namedArgs: {'url': _embEndpointCtrl.text},
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
      // Probe the connection the request will actually borrow — the preset the
      // "endpoint from" row names, or the one the LLM tab is on — with its
      // endpoint resolved the way the repo persists it. A protocol with a
      // fixed URL (OpenRouter, whose endpoint field is hidden) leaves the
      // controller empty and would otherwise fail the guard below.
      final source = _embeddingLlmSource();
      endpoint = source?.endpoint ?? '';
      apiKey = source?.apiKey ?? '';
      model = _embModelCtrl.text.trim().isNotEmpty
          ? _embModelCtrl.text.trim()
          : (source?.model ?? '');
    } else {
      endpoint = _embEndpointCtrl.text.trim();
      apiKey = _embApiKeyCtrl.text.trim();
      model = _embModelCtrl.text.trim();
    }
    if (endpoint.isEmpty) {
      GlazeToast.show(context, 'settings_err_fill_endpoint'.tr());
      return;
    }
    // The badge stays tappable while connecting, so ignore a second tap
    // instead of racing two probes into the same status field.
    if (_embStatus == ApiConnectionStatus.connecting) return;
    setState(() {
      _embStatus = ApiConnectionStatus.connecting;
      _embError = '';
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
        _adoptResolvedEmbeddingEndpoint();
        GlazeToast.show(context, message);
      case ApiTestFailure(:final error):
        setState(() {
          _embStatus = ApiConnectionStatus.failed;
          _embError = error.toString();
        });
        GlazeErrorDialog.show(
          context,
          error,
          prefix: 'settings_err_conn_failed'.tr(),
        );
    }
  }
}

/// Opens the API screen as a sheet, optionally landing on one section.
///
/// The screen is presented as a modal sheet everywhere it is reached from a
/// chat, so callers do not each rebuild the `showModalBottomSheet` boilerplate.
Future<void> showApiSettingsSheet(
  BuildContext context, {
  ApiSettingsSection? focusSection,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => ApiSettingsScreen(focusSection: focusSection),
  );
}
