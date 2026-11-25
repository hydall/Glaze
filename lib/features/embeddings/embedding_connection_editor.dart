import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/model_fetcher.dart';
import '../../core/llm/transport/endpoint_normalizer.dart';
import '../../core/llm/transport/endpoint_preview.dart';
import '../../core/llm/transport/endpoint_resolution_cache.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/models/api_config.dart';
import '../../core/services/api_connection_tester.dart';
import '../../core/state/lorebook_embedding_provider.dart';
import '../../core/utils/error_format.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/menu_group.dart';
import '../../shared/widgets/preset_switcher.dart';
import '../settings/api_config_draft.dart';
import '../settings/api_list_provider.dart';
import '../settings/widgets/connection_status.dart';
import 'embedding_preset_sheet.dart';

/// The embedding connection of the active embedding preset: the preset pill
/// with its connection badge, and the fields the preset holds.
///
/// Edits are saved on a debounce and flushed on every way out, onto the
/// embedding preset only — the chat presets are never written from here.
class EmbeddingConnectionEditor extends ConsumerStatefulWidget {
  const EmbeddingConnectionEditor({super.key});

  @override
  ConsumerState<EmbeddingConnectionEditor> createState() =>
      _EmbeddingConnectionEditorState();
}

class _EmbeddingConnectionEditorState
    extends ConsumerState<EmbeddingConnectionEditor> {
  final _nameCtrl = TextEditingController();
  final _endpointCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _chunkTokensCtrl = TextEditingController();
  final _requestsPerMinuteCtrl = TextEditingController();

  List<TextEditingController> get _ctrls => [
    _nameCtrl,
    _endpointCtrl,
    _apiKeyCtrl,
    _modelCtrl,
    _chunkTokensCtrl,
    _requestsPerMinuteCtrl,
  ];

  bool _enabled = false;
  bool _useLlmApi = true;

  /// The LLM preset "Use LLM API" borrows its endpoint from. Empty means
  /// "whichever connection the chat is on".
  String _llmPresetId = '';

  bool _showApiKey = false;
  bool _isLoadingModels = false;
  List<String> _fetchedModels = [];
  ApiConnectionStatus _status = ApiConnectionStatus.idle;
  String _error = '';

  String? _loadedId;
  bool _loading = false;
  Timer? _saveTimer;

  /// The endpoint and key the cached model list was last valid for.
  String _connection = '';

  /// Saves outlive the widget (they are flushed on the way out), and a
  /// `WidgetRef` is unusable once unmounted, so writes go through the
  /// container instead.
  late ProviderContainer _container;

  late final EmbeddingPresetActions _presetActions = EmbeddingPresetActions(
    context: context,
    ref: ref,
    flushPendingSave: _flushSave,
    cancelPendingSave: () => _saveTimer?.cancel(),
  );

  @override
  void initState() {
    super.initState();
    for (final c in _ctrls) {
      c.addListener(_scheduleSave);
    }
    _endpointCtrl.addListener(_onConnectionEdited);
    _apiKeyCtrl.addListener(_onConnectionEdited);
    final config = ref.read(activeEmbeddingConfigProvider);
    if (config != null) _load(config);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void deactivate() {
    // Still mounted here, so a sheet dismissed by swipe keeps its last edit.
    _flushSave();
    super.deactivate();
  }

  @override
  void dispose() {
    _flushSave();
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Load / save ───────────────────────────────────────────────────────────

  void _load(ApiConfig config) {
    _loadedId = config.id;
    _loading = true;
    final draft = ApiConfigDraft.fromConfig(config);
    _nameCtrl.text = draft.name;
    _endpointCtrl.text = draft.embeddingEndpoint;
    _apiKeyCtrl.text = draft.embeddingApiKey;
    _modelCtrl.text = draft.embeddingModel;
    _chunkTokensCtrl.text = draft.embeddingMaxChunkTokens;
    _requestsPerMinuteCtrl.text = draft.embeddingRequestsPerMinute;
    _enabled = draft.values.embeddingEnabled;
    _useLlmApi = draft.values.embeddingUseSame;
    _llmPresetId = draft.values.embeddingLlmPresetId;
    // The model list and the badge describe the preset open a moment ago.
    _fetchedModels = [];
    _status = ApiConnectionStatus.idle;
    _error = '';
    _connection = '${_endpointCtrl.text.trim()}\n${_apiKeyCtrl.text.trim()}';
    _loading = false;
  }

  void _scheduleSave() {
    if (_loading) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  void _flushSave() {
    if (_saveTimer?.isActive == true) {
      _saveTimer!.cancel();
      _save();
    }
  }

  Future<void> _save() async {
    // The preset the fields were loaded from, which is not necessarily the
    // active one any more: a switch flushes the edits of the preset left.
    final presets =
        _container.read(embeddingPresetListProvider).value ??
        const <ApiConfig>[];
    final config = presets.where((p) => p.id == _loadedId).firstOrNull;
    if (config == null) return;
    // Controllers are disposed with the widget, so their text is read before
    // the first await.
    final name = _nameCtrl.text.trim();
    final draft = ApiConfigDraft(
      values: config.copyWith(
        embeddingEnabled: _enabled,
        embeddingUseSame: _useLlmApi,
        embeddingLlmPresetId: _llmPresetId,
      ),
      name: name,
      endpoint: '',
      apiKey: '',
      model: '',
      maxTokens: '',
      contextSize: '',
      firstChunkTimeoutSeconds: '',
      reasoningHistoryCount: '',
      embeddingEndpoint: _endpointCtrl.text,
      embeddingApiKey: _apiKeyCtrl.text,
      embeddingModel: _modelCtrl.text,
      embeddingMaxChunkTokens: _chunkTokensCtrl.text,
      embeddingRequestsPerMinute: _requestsPerMinuteCtrl.text,
    );
    await _container
        .read(embeddingPresetListProvider.notifier)
        .put(draft.applyEmbeddingTo(config).copyWith(name: name));
  }

  /// A model list fetched with the old endpoint or key may not exist on the
  /// new one, so it is dropped and the next picker tap fetches afresh.
  void _onConnectionEdited() {
    final connection =
        '${_endpointCtrl.text.trim()}\n${_apiKeyCtrl.text.trim()}';
    if (connection == _connection) return;
    _connection = connection;
    if (_useLlmApi || _fetchedModels.isEmpty) return;
    setState(() => _fetchedModels = []);
  }

  /// Drops what belonged to the connection that was in use a moment ago.
  void _resetConnectionState() {
    _fetchedModels = [];
    _status = ApiConnectionStatus.idle;
    _error = '';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(activeEmbeddingConfigProvider);
    // Another preset was picked (here or anywhere else): flush the edits of
    // the one being left onto it, then load the new one.
    if (config != null && config.id != _loadedId) {
      _flushSave();
      _load(config);
    }
    final presets =
        ref.watch(embeddingPresetListProvider).value ?? const <ApiConfig>[];
    final chatPresets = ref.watch(apiListProvider).value ?? const <ApiConfig>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _buildTopControls(presets, config),
        ),
        MenuGroup(
          compact: true,
          header: 'embeddings_connection'.tr(),
          helpTerm: 'embeddings',
          items: [
            MenuFieldItem(
              label: 'settings_config_name'.tr(),
              controller: _nameCtrl,
              placeholder: 'My embeddings',
            ),
            MenuSwitchItem(
              label: 'search_type_vector'.tr(),
              description: 'settings_enable_vector_desc'.tr(),
              value: _enabled,
              onChanged: (v) {
                setState(() => _enabled = v);
                if (config != null) {
                  ref
                      .read(embeddingPresetListProvider.notifier)
                      .setEmbeddingEnabled(config.id, v);
                }
                _scheduleSave();
              },
            ),
            if (_enabled) ..._buildConnectionItems(chatPresets),
          ],
        ),
      ],
    );
  }

  Widget _buildTopControls(List<ApiConfig> presets, ApiConfig? config) {
    final pill = PresetPill(
      label: embeddingPresetName(config),
      onTap: presets.isEmpty ? null : _presetActions.showSheet,
    );
    // Nothing to probe until embeddings are switched on. Align keeps the lone
    // pill at its own width under the full-width constraint.
    if (!_enabled) return Align(alignment: Alignment.centerLeft, child: pill);
    return ConnectionStatus(
      status: _status,
      errorMessage: _error,
      onRetry: _testConnection,
      child: pill,
    );
  }

  List<Widget> _buildConnectionItems(List<ApiConfig> chatPresets) {
    return [
      MenuSwitchItem(
        label: 'settings_use_llm_api'.tr(),
        description: 'settings_use_llm_api_desc'.tr(),
        value: _useLlmApi,
        onChanged: (v) {
          setState(() {
            _useLlmApi = v;
            _resetConnectionState();
          });
          _scheduleSave();
        },
      ),
      if (_useLlmApi)
        MenuSelectorItem(
          label: 'settings_embedding_llm_preset'.tr(),
          description: 'settings_embedding_llm_preset_desc'.tr(),
          currentValue: _llmPresetName(chatPresets),
          onTap: () => _openLlmPresetSelector(chatPresets),
        )
      else ...[
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _endpointCtrl,
          builder: (context, value, _) {
            final preview = EndpointPreview.resolveEmbedding(value.text);
            return MenuFieldItem(
              label: 'settings_embedding_endpoint'.tr(),
              controller: _endpointCtrl,
              placeholder: 'http://127.0.0.1:11434/v1',
              helper: _endpointHelper(preview),
              helperIsError: preview.isInvalid,
            );
          },
        ),
        MenuFieldItem(
          label: 'onboarding_label_key'.tr(),
          helpTerm: 'apikey',
          controller: _apiKeyCtrl,
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
      ],
      _buildModelField(),
      MenuFieldItem(
        label: 'settings_max_tokens_chunk'.tr(),
        controller: _chunkTokensCtrl,
        placeholder: '512',
        keyboardType: TextInputType.number,
      ),
      MenuFieldItem(
        label: 'settings_embedding_requests_per_minute'.tr(),
        controller: _requestsPerMinuteCtrl,
        placeholder: '50',
        keyboardType: TextInputType.number,
      ),
    ];
  }

  /// Free text plus a chevron that fetches the model list from whichever
  /// connection the embedding request will actually use.
  Widget _buildModelField() {
    return MenuFieldItem(
      label: 'settings_embedding_model'.tr(),
      controller: _modelCtrl,
      placeholder: 'text-embedding-3-small',
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
    );
  }

  String? _endpointHelper(EndpointPreview preview) {
    if (preview.isInvalid) return 'settings_endpoint_invalid'.tr();
    if (preview.isEmpty) return null;
    return 'settings_endpoint_resolves_to'.tr(namedArgs: {'url': preview.url});
  }

  // ── "Use LLM API" source ──────────────────────────────────────────────────

  String _llmPresetName(List<ApiConfig> chatPresets) {
    for (final config in chatPresets) {
      if (config.id == _llmPresetId) return _chatPresetLabel(config);
    }
    // None named, or the named preset was deleted: the active one is used.
    return 'studio_slot_use_chat_api'.tr();
  }

  static String _chatPresetLabel(ApiConfig config) {
    if (config.name.isNotEmpty) return config.name;
    if (config.model.isNotEmpty) return config.model;
    return 'unnamed_entry'.tr();
  }

  void _openLlmPresetSelector(List<ApiConfig> chatPresets) {
    BottomSheetItem radio(String id, String label) => BottomSheetItem(
      label: label,
      icon: _llmPresetId == id
          ? Icons.radio_button_checked
          : Icons.radio_button_off,
      iconColor: _llmPresetId == id
          ? context.cs.primary
          : context.cs.onSurfaceVariant,
      onTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() {
          _llmPresetId = id;
          _resetConnectionState();
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
          radio(config.id, _chatPresetLabel(config)),
      ],
    );
  }

  /// The LLM connection "Use LLM API" borrows: the preset the row names, or
  /// the chat's active one. Both are persisted, so their endpoints are stored
  /// normalized.
  ApiConfig? _llmSource() {
    if (_llmPresetId.isNotEmpty) {
      final list = ref.read(apiListProvider).value ?? const <ApiConfig>[];
      for (final config in list) {
        if (config.id == _llmPresetId) return config;
      }
    }
    return ref.read(activeApiConfigProvider);
  }

  /// The connection the model list is fetched from, mirroring what
  /// `resolveEmbeddingConfig` feeds the request.
  ApiConfig? _modelSource() {
    if (_useLlmApi) {
      final source = _llmSource();
      if (source == null || source.endpoint.isEmpty) return null;
      return ApiConfig(
        id: '',
        endpoint: source.endpoint,
        apiKey: source.apiKey,
        protocol: source.protocol,
      );
    }
    final raw = _endpointCtrl.text.trim();
    if (raw.isEmpty) return null;
    // A dedicated embedding endpoint speaks the OpenAI-compatible surface.
    return ApiConfig(
      id: '',
      endpoint: EndpointNormalizer.persistedEmbeddingEndpoint(raw),
      apiKey: _apiKeyCtrl.text.trim(),
      protocol: LlmProtocol.customChatCompletion,
    );
  }

  // ── Models ────────────────────────────────────────────────────────────────

  Future<void> _fetchModels() async {
    final source = _modelSource();
    if (source == null || source.apiKey.isEmpty) {
      GlazeToast.show(context, 'settings_err_endpoint_key'.tr());
      return;
    }
    setState(() => _isLoadingModels = true);
    try {
      final ids = await ModelFetcher.fetchModelIds(source);
      if (!mounted) return;
      // The connection was edited while the request was out.
      final current = _modelSource();
      final stale =
          current == null ||
          current.endpoint != source.endpoint ||
          current.apiKey != source.apiKey;
      setState(() {
        if (!stale) _fetchedModels = ids;
        _isLoadingModels = false;
      });
      if (!stale && ids.isEmpty) {
        GlazeToast.show(context, 'settings_err_no_models'.tr());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingModels = false);
      GlazeErrorDialog.show(context, e, prefix: 'settings_err_failed'.tr());
    }
  }

  Future<void> _openModelSelector() async {
    if (_fetchedModels.isEmpty) {
      await _fetchModels();
      if (_fetchedModels.isEmpty) return;
    }
    if (!mounted) return;
    final models = List<String>.from(_fetchedModels);
    final current = _modelCtrl.text.trim();
    // A model typed by hand stays selectable.
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
      items: [
        for (final m in models)
          BottomSheetItem(
            label: m,
            icon: m == current ? Icons.check : null,
            iconColor: context.cs.primary,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _modelCtrl.text = m;
            },
          ),
      ],
    );
  }

  // ── Connection test ───────────────────────────────────────────────────────

  Future<void> _testConnection() async {
    final String endpoint, apiKey, model;
    if (_useLlmApi) {
      final source = _llmSource();
      endpoint = source?.endpoint ?? '';
      apiKey = source?.apiKey ?? '';
      model = source == null
          ? _modelCtrl.text.trim()
          : embeddingModelForBorrowedLlm(_modelCtrl.text, source);
    } else {
      endpoint = _endpointCtrl.text.trim();
      apiKey = _apiKeyCtrl.text.trim();
      model = _modelCtrl.text.trim();
    }
    if (endpoint.isEmpty) {
      GlazeToast.show(context, 'settings_err_fill_endpoint'.tr());
      return;
    }
    // The badge stays tappable while connecting; ignore a second tap.
    if (_status == ApiConnectionStatus.connecting) return;
    setState(() {
      _status = ApiConnectionStatus.connecting;
      _error = '';
    });
    final result = await ApiConnectionTester().testEmbedding(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
    );
    if (!mounted) return;
    switch (result) {
      case ApiTestSuccess(:final message):
        setState(() => _status = ApiConnectionStatus.connected);
        _adoptResolvedEndpoint();
        GlazeToast.show(context, message);
      case ApiTestFailure(:final error):
        setState(() {
          _status = ApiConnectionStatus.failed;
          _error = formatError(error);
        });
        GlazeErrorDialog.show(
          context,
          error,
          prefix: 'settings_err_conn_failed'.tr(),
        );
    }
  }

  /// After a successful test, writes the URL the request actually reached
  /// back into the field, so a rescued base path is not re-walked on every
  /// launch. With "Use LLM API" on the URL belongs to the LLM preset.
  void _adoptResolvedEndpoint() {
    if (_useLlmApi) return;
    final raw = _endpointCtrl.text.trim();
    if (raw.isEmpty) return;
    final resolvedBase = EndpointResolutionCache.resolvedBase(raw);
    if (resolvedBase == null) return;
    if (resolvedBase == EndpointNormalizer.parse(raw).base) return;
    _endpointCtrl.text = '$resolvedBase/embeddings';
    GlazeToast.show(
      context,
      'settings_endpoint_autofixed'.tr(namedArgs: {'url': _endpointCtrl.text}),
    );
  }
}
