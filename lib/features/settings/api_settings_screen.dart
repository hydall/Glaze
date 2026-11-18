import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../core/llm/converters/reasoning_effort.dart';
import '../../core/llm/converters/thinking_budget.dart';
import '../../core/llm/converters/prompt_post_processing.dart';
import '../../core/llm/transport/endpoint_normalizer.dart';
import '../../core/llm/transport/endpoint_preview.dart';
import '../../core/llm/transport/endpoint_resolution_cache.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/llm/transport/transport_factory.dart';
import '../../core/services/api_connection_tester.dart';
import '../chat/state/cached_token_breakdown.dart';
import '../../core/llm/history_trim.dart';
import '../../core/llm/tokenizer.dart';
import '../../core/models/api_config.dart';
import '../../core/models/extra_request_parameter.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/error_format.dart';
import '../presets/preset_list_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_tab_bar.dart';
import '../../shared/widgets/swipe_tab_switcher.dart';
import '../../shared/widgets/tab_slide_switcher.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/sheet_view.dart';
import 'api_config_draft.dart';
import 'context_budget_check.dart';
import '../model_tools/model_tool.dart';
import 'widgets/aux_slots_tab.dart';
import 'api_list_provider.dart';
import 'api_preset_selection_provider.dart';
import 'api_preset_sort.dart';
import 'tokenizer_labels.dart';
import 'tokenizer_provider.dart';
import 'widgets/connection_status.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/preset_switcher.dart';
import '../../shared/widgets/extra_request_parameters_editor.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../guides/guide_anchor.dart';
import '../guides/guide_service.dart';

/// The factory values every reset affordance on this screen restores.
///
/// A plain [ApiConfig] with nothing but an id carries every `@Default` the
/// model declares, so the numbers live in one place — the model — instead of
/// being copied into each row as a literal.
const _apiDefaults = ApiConfig(id: '');

/// Tokens the globally active chat preset puts into every prompt — see
/// [presetPromptTokens].
final _activePresetTokensProvider = Provider.autoDispose<int>((ref) {
  // A tokenizer switch changes every count.
  ref.watch(tokenizerStatusProvider.select((status) => status.active));
  final presets = ref.watch(presetListProvider).value;
  if (presets == null) return 0;
  final preset = getEffectivePreset(
    presets,
    null,
    null,
    ref.watch(activePresetIdProvider),
    ref.watch(presetConnectionsProvider),
  );
  return preset == null ? 0 : presetPromptTokens(preset);
});

/// A section of the API screen a caller can open it *on*.
enum ApiSettingsSection {
  /// The context-window form on the LLM tab.
  context,

  /// The MemoryBook generation slot on the Agents tab. Memory settings link
  /// here since the connection and the model moved out of that sheet.
  memoryBook,
}

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
  late int _tab; // 0 = LLM, 1 = auxiliary connections

  bool _showApiKey = false;
  bool _isLoadingModels = false;
  ApiConnectionStatus _llmStatus = ApiConnectionStatus.idle;
  String _llmError = '';
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
  bool _toolCalling = false;
  bool _timeoutOverridesNetwork = false;
  List<String> _disabledToolGroups = const [];
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
  String _cacheControlTtl = 'off';
  String _cacheBreakpointMode = 'depth';
  String _historyTrimMode = HistoryTrimMode.sliding;
  String _tokenizer = kTokenizerAuto;
  int _historyTrimTriggerPercent = kDefaultHistoryTrimTriggerPercent;
  int _historyTrimStepPercent = kDefaultHistoryTrimStepPercent;

  /// Scroll target for a deep link that opens this screen *on* the context
  /// settings — the Prompt Inspector's cutoff notice links here.
  final GlobalKey _contextGroupKey = GlobalKey();

  /// The same, for the MemoryBook generation slot on the Agents tab.
  final GlobalKey _memoryBookSlotKey = GlobalKey();

  /// Runs once: a deep link names a section, and the form it lives in is only
  /// measurable after the first layout pass.
  void _scrollToFocusSection() {
    final key = switch (widget.focusSection) {
      ApiSettingsSection.context => _contextGroupKey,
      ApiSettingsSection.memoryBook => _memoryBookSlotKey,
      null => null,
    };
    if (key == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
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

  /// Whether the presets sheet is on screen. A bulk delete can outlive it, and
  /// closing "the sheet" once it is gone would pop whatever took its place.
  bool _presetSheetOpen = false;
  // Each tab owns its own scroll controller. During a slide transition both
  // tab bodies are briefly alive at once, so they must never share a single
  // controller (a controller attached to two scroll views throws). The sheet
  // is pointed at whichever controller belongs to the active tab.
  final _llmScrollController = ScrollController();
  final _agentsScrollController = ScrollController();
  Timer? _saveTimer;
  bool _loading = false;

  /// The provider container this screen lives in, captured while the element
  /// is still in the tree.
  ///
  /// A save is debounced and flushed on the way out, so its DB writes routinely
  /// outlive the widget. A `WidgetRef` cannot be used then — read, watch and
  /// invalidate all throw once the widget is unmounted — and the flush would
  /// die halfway. The container has no such lifetime tied to the widget, so
  /// [_save] goes through it instead.
  late ProviderContainer _container;

  List<TextEditingController> get _ctrls => [
    _nameCtrl,
    _endpointCtrl,
    _keyCtrl,
    _modelCtrl,
    _maxTokensCtrl,
    _contextSizeCtrl,
    _firstChunkTimeoutCtrl,
    _reasoningHistoryCountCtrl,
  ];

  @override
  void initState() {
    super.initState();
    // A deep link at the MemoryBook slot opens straight on the tab that
    // holds it rather than on LLM and then jumping.
    _tab = switch (widget.focusSection) {
      ApiSettingsSection.memoryBook => 1,
      _ => 0,
    };
    for (final c in _ctrls) {
      c.addListener(_scheduleSave);
    }
    _endpointCtrl.addListener(_onLlmConnectionEdited);
    _keyCtrl.addListener(_onLlmConnectionEdited);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadActivePreset();
    });
  }

  /// Whether the screen's content may be built yet.
  ///
  /// Building it is not cheap — two tabs of grouped settings, each a long
  /// list — and doing that in the frame that pushes the route is why the sheet
  /// looked slow to open: the route was there immediately, but its first frame
  /// took long enough to read as a delay, and the slide-in inherited the cost.
  /// The sheet now goes up straight away showing the spinner it would have
  /// shown for a cold load anyway, and the content is built once the entrance
  /// transition is done.
  bool _revealed = false;
  Animation<double>? _revealAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
    if (_revealed || _revealAnimation != null) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      // No transition to wait for — a hosted panel, or a route that is already
      // settled. One frame is still enough to get the chrome up first.
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
      return;
    }
    _revealAnimation = animation..addStatusListener(_onRevealStatus);
  }

  void _onRevealStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _reveal();
  }

  void _reveal() {
    if (_revealed || !mounted) return;
    setState(() => _revealed = true);
    // Not before: the guide's controls only exist once the content is built.
    maybeShowGuide(context, AppGuide.api);
    // The deep-linked section only exists once the content is built, so the
    // scroll is kicked off here rather than in `initState` — where the spinner
    // was still on screen and the key had no context to measure.
    _scrollToFocusSection();
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
    _revealAnimation?.removeStatusListener(_onRevealStatus);
    _llmScrollController.dispose();
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

  /// Saves a pick from a list (model, protocol, tokenizer) without the typing
  /// debounce: the active connection's tokenizer follows the saved row, so it
  /// switches — and starts downloading — the moment the pick lands.
  void _saveNow() {
    if (_loading) return;
    _saveTimer?.cancel();
    unawaited(_save());
  }

  /// The endpoint and key the cached model list was last valid for. A
  /// controller also notifies on cursor moves, so only a change of the text
  /// itself counts.
  String _llmConnection = '';

  /// A model list fetched with the old endpoint or key may not exist on the
  /// new one, so it is dropped and the next picker tap fetches afresh.
  void _onLlmConnectionEdited() {
    final connection = '${_endpointCtrl.text.trim()}\n${_keyCtrl.text.trim()}';
    if (connection == _llmConnection) return;
    _llmConnection = connection;
    if (_fetchedModels.isEmpty) return;
    setState(() => _fetchedModels = []);
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
      _toolCalling = values.toolCalling;
      _timeoutOverridesNetwork = values.firstChunkTimeoutOverridesNetwork;
      _disabledToolGroups = values.disabledToolGroups;
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
      _tokenizer = values.tokenizer;
      _historyTrimTriggerPercent = values.historyTrimTriggerPercent;
      _historyTrimStepPercent = values.historyTrimStepPercent;
      _sessionIdMode = values.sessionIdMode;
      _promptPostProcessing = values.promptPostProcessing;
      _protocol = values.protocol;
      _extraRequestParameters = values.extraRequestParameters;
      _fetchedModels = [];
    });

    _loading = false;
  }

  Future<void> _save() async {
    final config = _container.read(activeApiConfigProvider);
    if (config == null) return;
    // The controllers are disposed with the widget, so their text is read up
    // front rather than after an await. Everything else goes through
    // [_container], which stays valid for the whole write.
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
        toolCalling: _toolCalling,
        disabledToolGroups: _disabledToolGroups,
        firstChunkTimeoutOverridesNetwork: _timeoutOverridesNetwork,
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
        cacheControlTtl: _cacheControlTtl,
        cacheBreakpointMode: _cacheBreakpointMode,
        historyTrimMode: _historyTrimMode,
        tokenizer: _tokenizer,
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
      // Embeddings have a screen and a preset list of their own; the LLM
      // half never writes them.
      embeddingEndpoint: config.embeddingEndpoint,
      embeddingApiKey: config.embeddingApiKey,
      embeddingModel: config.embeddingModel,
      embeddingMaxChunkTokens: config.embeddingMaxChunkTokens.toString(),
      embeddingRequestsPerMinute: config.embeddingRequestsPerMinute.toString(),
    );
    {
      final updated = draft.applyLlmTo(config);
      // The window and the trim mode decide which messages survive into the
      // prompt, so every cached breakdown taken under the old values is stale
      // the moment this lands — including the ones on surfaces nobody has open
      // right now (the drawer's stats, the context card under the chat header).
      final budgetChanged =
          updated.contextBudgetSignature != config.contextBudgetSignature;
      await _container.read(apiListProvider.notifier).put(updated);
      if (budgetChanged) {
        _container.invalidate(cachedTokenBreakdownProvider);
      }
    }
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
      title: 'menu_api_settings'.tr(),
      showBack: true,
      onBack: _goBack,
      scrollController: switch (_tab) {
        0 => _llmScrollController,
        _ => _agentsScrollController,
      },
      // The LLM/Agents switcher stays fixed in the header so it never slides
      // with the tab bodies — a single segmented control that keeps its own
      // pill animation while the content swipes beneath it. It goes away only
      // while there is nothing at all to configure.
      headerBottom: list.isEmpty ? null : _buildTabBar(),
      // Until the sheet is on screen, only the spinner. See [_revealed].
      body: !_revealed
          ? const Center(child: GlazeSpinner())
          : asyncList.when(
              loading: () => const Center(child: GlazeSpinner()),
              error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
              data: (list) => list.isEmpty
                  ? _buildEmptyState()
                  : SwipeTabSwitcher(
                      index: _tab,
                      length: 2,
                      onChanged: (i) => setState(() => _tab = i),
                      child: TabSlideSwitcher(
                        index: _tab,
                        child: switch (_tab) {
                          0 => _buildLlmTab(list, activeName),
                          _ => AuxSlotsTab(
                            controller: _agentsScrollController,
                            memoryBookSlotKey: _memoryBookSlotKey,
                          ),
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

  // The fixed LLM/Agents segmented control. Lives in the sheet header so it
  // stays put (and keeps its own pill animation) while the tab bodies slide.
  // Embeddings have a screen of their own (Tools → Embeddings).
  Widget _buildTabBar() {
    return GuideAnchor(
      id: GuideIds.apiTabs,
      child: GlazeTabBar(
        tabs: [
          GlazeTabItem(
            label: 'tab_llm'.tr(),
            icon: Icons.chat_bubble_outline_rounded,
          ),
          GlazeTabItem(
            label: 'studio_agents'.tr(),
            icon: Icons.smart_toy_outlined,
          ),
        ],
        activeIndex: _tab,
        onChanged: (i) => setState(() => _tab = i),
      ),
    );
  }

  /// The preset pill plus its connection badge, above the LLM settings.
  Widget _buildTopControls(List<ApiConfig> list, String presetName) {
    return ConnectionStatus(
      status: _llmStatus,
      errorMessage: _llmError,
      onRetry: _testLlmConnection,
      child: PresetPill(
        label: presetName,
        onTap: list.isEmpty ? null : _showPresetSheet,
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
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          GuideAnchor(
            id: GuideIds.apiAdd,
            child: GlazeActionButton(
              icon: Icons.add_rounded,
              label: 'settings_add_api_config'.tr(),
              tone: GlazeActionTone.primary,
              onTap: _createNewPreset,
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
        // A deep link lands on the Context group, which sits below the fold.
        // A lazy list never builds it, and `Scrollable.ensureVisible` cannot
        // scroll to an element that does not exist, so while a focus is
        // pending the viewport builds far enough down to reach it.
        cacheExtent: widget.focusSection == ApiSettingsSection.context
            ? 3000
            : null,
        // A sidebar panel's header already keeps its gap below the tab bar.
        padding: EdgeInsets.only(
          top:
              MediaQuery.paddingOf(context).top +
              (inSidebarPanel(context) ? 0 : 12),
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: GuideAnchor(
              id: GuideIds.apiSwitcher,
              child: _buildTopControls(list, activeName),
            ),
          ),
          GuideAnchor(
            id: GuideIds.apiConnection,
            child: _buildConnectionGroup(context),
          ),
          _buildContextGroup(),
          _buildGenerationGroup(),
          _buildReasoningGroup(),
          _buildToolsGroup(),
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
        MenuSwitchItem(
          label: 'label_timeout_overrides_network'.tr(),
          description: 'desc_timeout_overrides_network'.tr(),
          value: _timeoutOverridesNetwork,
          onChanged: (v) {
            setState(() => _timeoutOverridesNetwork = v);
            _scheduleSave();
          },
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
      helpTerm: 'history-trim',
      items: [
        MenuSelectorItem(
          label: 'label_history_trim_mode'.tr(),
          helpTerm: 'history-trim',
          currentValue: _historyTrimModeLabel(_historyTrimMode),
          description: 'desc_history_trim_mode'.tr(),
          onTap: _openHistoryTrimModeSelector,
        ),
        // Only stepped spends them; under sliding they would be two dead rows.
        if (_historyTrimMode == HistoryTrimMode.stepped) ...[
          MenuRangeItem(
            label: 'label_history_trim_threshold'.tr(),
            helpTerm: 'history-trim',
            description: 'desc_history_trim_threshold'.tr(),
            value: _historyTrimTriggerPercent.toDouble(),
            min: 10,
            max: 100,
            divisions: 90,
            decimalPlaces: 0,
            editableValue: true,
            unit: '%',
            onChanged: (v) {
              setState(() => _historyTrimTriggerPercent = v.round());
              _scheduleSave();
            },
          ),
          MenuRangeItem(
            label: 'label_history_trim_step'.tr(),
            helpTerm: 'step-size',
            description: 'desc_history_trim_step'.tr(),
            value: _historyTrimStepPercent.toDouble(),
            min: 5,
            max: 95,
            divisions: 90,
            decimalPlaces: 0,
            editableValue: true,
            unit: '%',
            onChanged: (v) {
              setState(() => _historyTrimStepPercent = v.round());
              _scheduleSave();
            },
          ),
        ],
        // Listens to both fields: the cap below moves with the context size.
        ListenableBuilder(
          listenable: Listenable.merge([_maxTokensCtrl, _contextSizeCtrl]),
          builder: (context, _) {
            final contextSize = _typedContextSize;
            final exceeds = contextSize > 0 && _typedMaxTokens > contextSize;
            return MenuFieldItem(
              label: 'label_max_tokens'.tr(),
              helpTerm: 'max-tokens',
              controller: _maxTokensCtrl,
              placeholder: '${_apiDefaults.maxTokens}',
              keyboardType: TextInputType.number,
              helper: exceeds
                  ? 'error_max_tokens_exceeds_context'.tr(
                      args: ['$contextSize'],
                    )
                  : null,
              helperIsError: exceeds,
              onReset: _maxTokensCtrl.text.trim() != '${_apiDefaults.maxTokens}'
                  ? () {
                      _maxTokensCtrl.text = '${_apiDefaults.maxTokens}';
                      _scheduleSave();
                    }
                  : null,
            );
          },
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _contextSizeCtrl,
          builder: (context, value, _) => MenuFieldItem(
            label: 'label_context_size'.tr(),
            helpTerm: 'context-size',
            controller: _contextSizeCtrl,
            placeholder: '${_apiDefaults.contextSize}',
            keyboardType: TextInputType.number,
            onReset: value.text.trim() != '${_apiDefaults.contextSize}'
                ? () {
                    _contextSizeCtrl.text = '${_apiDefaults.contextSize}';
                    _scheduleSave();
                  }
                : null,
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_maxTokensCtrl, _contextSizeCtrl]),
          builder: (context, _) => _buildPresetFitWarning(),
        ),
        // Auto follows the model field as it is typed, not the saved row.
        ListenableBuilder(
          listenable: _modelCtrl,
          builder: (context, _) => _buildTokenizerSelector(),
        ),
      ],
    );
  }

  /// The context size as the next save will store it — an unparsable field
  /// keeps the preset's value, the same fallback [ApiConfigDraft] applies.
  int get _typedContextSize =>
      int.tryParse(_contextSizeCtrl.text.trim()) ??
      ref.read(activeApiConfigProvider)?.contextSize ??
      _apiDefaults.contextSize;

  int get _typedMaxTokens =>
      int.tryParse(_maxTokensCtrl.text.trim()) ??
      ref.read(activeApiConfigProvider)?.maxTokens ??
      _apiDefaults.maxTokens;

  /// Warns when the active chat preset alone outgrows what the context window
  /// leaves for the prompt once the reply is reserved.
  Widget _buildPresetFitWarning() {
    final fits = presetFitsContext(
      presetTokens: ref.watch(_activePresetTokensProvider),
      contextSize: _typedContextSize,
      maxTokens: _typedMaxTokens,
    );
    if (fits) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: context.cs.error,
            ),
          ),
          Expanded(
            child: PresetFitWarningText(
              style: TextStyle(
                color: context.cs.error,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What `auto` resolves to for the model and protocol being edited.
  TokenizerKind get _autoTokenizer => resolveTokenizerKind(
    setting: kTokenizerAuto,
    model: _modelCtrl.text,
    protocol: _protocol,
  );

  Widget _buildTokenizerSelector() {
    final explicit = TokenizerKind.fromId(_tokenizer);
    final effective = explicit ?? _autoTokenizer;
    final status = ref.watch(tokenizerStatusProvider);
    final String description;
    if (status.requested == effective &&
        status.phase == TokenizerPhase.downloading) {
      description = 'tokenizer_status_downloading'.tr();
    } else if (status.requested == effective &&
        status.phase == TokenizerPhase.failed) {
      description = 'tokenizer_status_failed'.tr(
        args: [tokenizerLabel(status.active)],
      );
    } else {
      description = 'desc_tokenizer'.tr();
    }
    return MenuSelectorItem(
      label: 'label_tokenizer'.tr(),
      helpTerm: 'token-estimate',
      currentValue: explicit == null
          ? 'tokenizer_auto_value'.tr(args: [tokenizerLabel(effective)])
          : tokenizerLabel(explicit),
      description: description,
      onTap: _openTokenizerSelector,
    );
  }

  void _openTokenizerSelector() {
    final explicit = TokenizerKind.fromId(_tokenizer);
    void choose(String value) {
      Navigator.of(context, rootNavigator: true).pop();
      setState(() => _tokenizer = value);
      _saveNow();
      // Picking the tokenizer that just failed to download again does not
      // change the connection's request, so nothing else would retry it.
      final status = ref.read(tokenizerStatusProvider);
      final picked = TokenizerKind.fromId(value) ?? _autoTokenizer;
      if (status.phase == TokenizerPhase.failed && status.requested == picked) {
        unawaited(ref.read(tokenizerStatusProvider.notifier).retry());
      }
    }

    GlazeBottomSheet.show<void>(
      context,
      title: 'label_tokenizer'.tr(),
      items: [
        BottomSheetItem(
          label: 'tokenizer_auto'.tr(),
          hint: 'tokenizer_auto_hint'.tr(
            args: [tokenizerLabel(_autoTokenizer)],
          ),
          icon: explicit == null ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () => choose(kTokenizerAuto),
        ),
        for (final kind in TokenizerKind.values)
          BottomSheetItem(
            label: tokenizerLabel(kind),
            hint: tokenizerModelsHint(kind),
            icon: explicit == kind ? Icons.check : null,
            iconColor: context.cs.primary,
            onTap: () => choose(kind.id),
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
            onReset:
                !_omitTemperature && _temperature != _apiDefaults.temperature
                ? () {
                    setState(() => _temperature = _apiDefaults.temperature);
                    _scheduleSave();
                  }
                : null,
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
            onReset:
                !_omitReasoningEffort &&
                    _reasoningEffort != _apiDefaults.reasoningEffort
                ? () {
                    setState(
                      () => _reasoningEffort = _apiDefaults.reasoningEffort,
                    );
                    _scheduleSave();
                  }
                : null,
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
          onReset: !_omitTopP && _topP != _apiDefaults.topP
              ? () {
                  setState(() => _topP = _apiDefaults.topP);
                  _scheduleSave();
                }
              : null,
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
          onReset: !_omitTopK && _topK != _apiDefaults.topK
              ? () {
                  setState(() => _topK = _apiDefaults.topK);
                  _scheduleSave();
                }
              : null,
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
          onReset:
              !_omitFrequencyPenalty &&
                  _frequencyPenalty != _apiDefaults.frequencyPenalty
              ? () {
                  setState(
                    () => _frequencyPenalty = _apiDefaults.frequencyPenalty,
                  );
                  _scheduleSave();
                }
              : null,
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
          onReset:
              !_omitPresencePenalty &&
                  _presencePenalty != _apiDefaults.presencePenalty
              ? () {
                  setState(
                    () => _presencePenalty = _apiDefaults.presencePenalty,
                  );
                  _scheduleSave();
                }
              : null,
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

  bool get _supportsToolCalling => LlmProtocol.supportsToolCalling(
    _protocol,
    useResponsesApi: _useResponsesApi,
  );

  /// Tools the chat model may call (`lib/features/model_tools/`). Hidden for
  /// protocols whose transport cannot report a call back.
  Widget _buildToolsGroup() {
    if (!_supportsToolCalling) return const SizedBox.shrink();
    return MenuGroup(
      compact: true,
      header: 'section_model_tools'.tr(),
      items: [
        MenuSwitchItem(
          label: 'label_tool_calling'.tr(),
          description: 'desc_tool_calling'.tr(),
          value: _toolCalling,
          onChanged: (v) {
            setState(() => _toolCalling = v);
            _scheduleSave();
          },
        ),
        if (_toolCalling)
          for (final group in ModelToolGroup.values)
            MenuSwitchItem(
              label: 'label_tool_group_${group.id}'.tr(),
              description: 'desc_tool_group_${group.id}'.tr(),
              value: !_disabledToolGroups.contains(group.id),
              onChanged: (v) {
                setState(() {
                  _disabledToolGroups = v
                      ? [
                          for (final id in _disabledToolGroups)
                            if (id != group.id) id,
                        ]
                      : [..._disabledToolGroups, group.id];
                });
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

  // ── Sheet actions ─────────────────────────────────────────────────────────────

  /// The presets sheet. Its rows are built from the providers on every rebuild
  /// (`cardsBuilder`), so switching the sort mode, dragging a row, deleting a
  /// preset or selecting several updates the open sheet in place — it is never
  /// closed and reopened to show the change.
  Future<void> _showPresetSheet() async {
    _presetSheetOpen = true;
    await PresetSwitcher.show(
      context,
      title: 'settings_api_configs_title'.tr(),
      // The shared element owns the sort state, the drag arm and the live
      // rebuild; this screen only maps its configs to rows.
      sort: PresetSwitcherSort(
        sort: apiPresetSortProvider,
        reorderArmed: apiPresetReorderArmedProvider,
      ),
      addAction: PresetSwitcherAction(
        icon: Icons.add_circle_outline_rounded,
        label: 'settings_new_config_tooltip'.tr(),
        closesSwitcher: true,
        onTap: _createNewPreset,
      ),
      selection: PresetSwitcherSelection(
        isActive: (ref) => ref.watch(apiPresetSelectionProvider).active,
        header: (_, ref) =>
            _buildSelectionActions(ref.watch(apiPresetSelectionProvider)),
      ),
      entriesBuilder: (_, sheetRef) {
        final list =
            sheetRef.watch(apiListProvider).value ?? const <ApiConfig>[];
        final sort =
            sheetRef.watch(apiPresetSortProvider).value ??
            const ApiPresetSortState();
        final selection = sheetRef.watch(apiPresetSelectionProvider);
        final reordering =
            sort.mode == ApiPresetSortMode.manual &&
            sheetRef.watch(apiPresetReorderArmedProvider);
        // The active id falls back to the *repository's* first preset, the same
        // one activeApiConfigProvider picks — sorting only reorders what is
        // shown, so it must not move the highlight to another row.
        final activeId =
            sheetRef.watch(activeApiPresetIdProvider) ??
            (list.isNotEmpty ? list.first.id : null);
        return [
          for (final config in list)
            _presetEntry(
              sheetRef,
              config,
              activeId,
              selection: selection,
              reordering: reordering,
              // The chat side always keeps one preset.
              canDelete: list.length > 1,
            ),
        ];
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

  /// Maps one API config to a row of the shared preset-switcher element.
  PresetSwitcherEntry _presetEntry(
    WidgetRef ref,
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

    return PresetSwitcherEntry(
      id: config.id,
      label: name,
      sublabel: config.endpoint.isNotEmpty
          ? config.endpoint
                .replaceAll(RegExp(r'https?://'), '')
                .split('/')
                .first
          : null,
      isActive: selection.active ? isSelected : isActive,
      isSelected: isSelected,
      // While selecting, the radio button gives way to a check mark: the row
      // now answers "is it picked", not "is it the connection in use".
      icon: selection.active
          ? (isSelected
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded)
          : null,
      faviconUrl: selection.active ? null : _faviconFor(config),
      // A tap that selects stays in the sheet; one that picks a connection
      // closes it, the way every other preset switcher does.
      closeOnTap: !selection.active,
      // While dragging is armed a long press lifts the row, so it can't also
      // open multi-select.
      onLongPress: reordering
          ? null
          : () =>
                ref.read(apiPresetSelectionProvider.notifier).start(config.id),
      menu: [
        // Bulk delete owns the header while selecting; per-row deletes would
        // only compete with it.
        if (canDelete && !selection.active)
          PresetSwitcherAction(
            icon: Icons.delete_outline_rounded,
            label: 'action_delete'.tr(),
            isDestructive: true,
            onTap: () async {
              // A pending save would race the delete and write the row back.
              _saveTimer?.cancel();
              await ref.read(apiListProvider.notifier).remove(config.id);
              _reloadAfterDelete(activeId, {config.id});
            },
          ),
      ],
      onSelect: () {
        if (selection.active) {
          ref.read(apiPresetSelectionProvider.notifier).toggle(config.id);
          return;
        }
        // Edits made in the last debounce window belong to the preset that is
        // still open. Flush them to it before the selection moves — cancelling
        // the timer here simply threw them away.
        _flushSave();
        ref.read(activeApiPresetIdProvider.notifier).state = config.id;
        _persistActiveId(config.id);
        _loadedPresetId = null;
        _loadFromConfig(config);
      },
    );
  }

  /// Favicon of the endpoint's host, or null for a local / unparsable one.
  String? _faviconFor(ApiConfig config) {
    if (config.endpoint.isEmpty) return null;
    try {
      final uri = Uri.parse(config.endpoint);
      if (uri.host.isEmpty ||
          uri.host.contains('127.0.0.1') ||
          uri.host.contains('localhost')) {
        return null;
      }
      return 'https://www.google.com/s2/favicons?domain=${uri.host}&sz=128';
    } catch (_) {
      return null;
    }
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
            // As with a single delete: no pending save may outlive the rows.
            _saveTimer?.cancel();
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

  /// Creates a chat preset and makes it the active connection.
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
          // As with picking another preset: the editor is about to be pointed
          // somewhere else, so whatever is still pending belongs to the preset
          // being left.
          _flushSave();

          final newConfig = ApiConfig(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: trimmed,
            mode: 'chat',
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
                _saveNow();
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
    if (_protocol == LlmProtocol.gemini) {
      // Level-based Gemini models take a named level, not a budget share.
      final level = calculateGoogleBudgetTokens(
        maxTokens: 0,
        reasoningEffort: effort,
        model: _modelCtrl.text.trim(),
      );
      if (level is String) {
        if (level == effort) return null;
        return 'reasoning_effort_hint_sent'.tr(namedArgs: {'value': level});
      }
    }
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
            // Auto falls back to the protocol's tokenizer for unknown models.
            _saveNow();
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
      // The endpoint or key was edited while the request was out: the list
      // describes a connection that is no longer in the fields.
      final stale =
          endpoint != _endpointCtrl.text.trim() ||
          apiKey != _keyCtrl.text.trim();
      setState(() {
        if (!stale) _fetchedModels = models;
        _isLoadingModels = false;
      });
      if (stale) return;
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
          _llmError = formatError(error);
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
  return showGlazeSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => ApiSettingsScreen(focusSection: focusSection),
  );
}
