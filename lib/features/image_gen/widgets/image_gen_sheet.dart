import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../../core/utils/platform_paths.dart';
import '../../character_gallery/gallery_image_picker.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/widgets/connection_status.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/help_tip.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../image_gen_capabilities.dart';
import '../image_gen_models.dart';
import '../image_gen_provider.dart';
import '../services/image_gen_connection_service.dart';
import 'a1111_fields.dart';
import 'connection_fields.dart';
import 'model_fields.dart';
import 'openrouter_fields.dart';
import 'reference_library_section.dart';
import 'rows.dart' as rows;
import 'style_library_sheet.dart';

class ImageGenSheet extends ConsumerStatefulWidget {
  const ImageGenSheet({super.key, this.charId});

  final String? charId;

  @override
  ConsumerState<ImageGenSheet> createState() => _ImageGenSheetState();
}

class _ImageGenSheetState extends ConsumerState<ImageGenSheet> {
  late ImageGenSettings _settings;
  bool _isFetchingModels = false;
  final ImageGenConnectionService _connectionService =
      ImageGenConnectionService();
  final ScrollController _scrollController = ScrollController();
  int _connectionEpoch = 0;
  ApiConnectionStatus _connectionStatus = ApiConnectionStatus.idle;
  String _connectionError = '';
  String _modelFetchError = '';

  @override
  void initState() {
    super.initState();
    _settings =
        ref.read(imageGenSettingsProvider).value ?? const ImageGenSettings();
  }

  void _update(ImageGenSettings s) {
    final connectionChanged = _hasConnectionChanged(_settings, s);
    _settings = s;
    ref.read(imageGenSettingsProvider.notifier).save(s);
    // Nothing is probed automatically — but a verdict about the old endpoint
    // must not linger once the connection settings change under it.
    if (!s.enabled || connectionChanged) {
      _connectionEpoch++;
      _connectionStatus = ApiConnectionStatus.idle;
      _connectionError = '';
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _connectionService.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _hasConnectionChanged(ImageGenSettings before, ImageGenSettings after) =>
      before.apiType != after.apiType ||
      before.useSameEndpoint != after.useSameEndpoint ||
      before.customEndpoint != after.customEndpoint ||
      before.customApiKey != after.customApiKey ||
      before.naisteraApiKey != after.naisteraApiKey ||
      before.routmyApiKey != after.routmyApiKey ||
      before.ruRoutmyApiKey != after.ruRoutmyApiKey ||
      before.openrouter.apiKey != after.openrouter.apiKey ||
      before.openrouter.endpoint != after.openrouter.endpoint ||
      before.electronhub.apiKey != after.electronhub.apiKey ||
      before.electronhub.endpoint != after.electronhub.endpoint ||
      before.a1111.endpoint != after.a1111.endpoint ||
      before.a1111.apiKey != after.a1111.apiKey;

  /// Probes the provider. Only ever runs from a tap on the status badge — the
  /// sheet never reaches out on its own.
  Future<void> _checkConnection() async {
    final settings = _settings;
    if (!settings.enabled) return;
    final epoch = ++_connectionEpoch;
    setState(() {
      _connectionStatus = ApiConnectionStatus.connecting;
      _connectionError = '';
    });
    final apiConfig = ref.read(activeApiConfigProvider);
    try {
      await _connectionService.checkConnection(
        settings: settings,
        llmEndpoint: apiConfig?.endpoint ?? '',
        llmApiKey: apiConfig?.apiKey ?? '',
      );
      if (!mounted || epoch != _connectionEpoch) return;
      setState(() => _connectionStatus = ApiConnectionStatus.connected);
    } catch (error) {
      if (!mounted || epoch != _connectionEpoch) return;
      setState(() {
        _connectionStatus = ApiConnectionStatus.failed;
        _connectionError = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  void _showOptions<T>({
    required String title,
    required List<T> items,
    required String Function(T) labelBuilder,
    required bool Function(T) isSelected,
    required void Function(T) onSelected,
  }) {
    rows.showImageGenOptions<T>(
      context,
      title: title,
      items: items,
      labelBuilder: labelBuilder,
      isSelected: isSelected,
      onSelected: onSelected,
    );
  }

  void _openApiTypeSelector() {
    _showOptions<ImageGenApiType>(
      title: 'imggen_api_type'.tr(),
      items: ImageGenApiType.values,
      labelBuilder: (t) => t.label,
      isSelected: (t) => _settings.apiType == t,
      onSelected: (t) => _update(_settings.copyWith(apiType: t)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;

    return SheetView(
      titleWidget: Row(
        children: [
          Text(
            'section_image_gen'.tr(),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const HelpTip(term: 'image-gen'),
          const Spacer(),
          Switch(
            value: s.enabled,
            onChanged: (v) => _update(s.copyWith(enabled: v)),
          ),
        ],
      ),
      fitContent: false,
      scrollController: _scrollController,
      enableHeaderBlur: false,
      body: s.enabled ? _buildBody(context, s) : _buildDisabledPlaceholder(),
    );
  }

  /// Shown instead of the settings when generation is off, so the sheet does
  /// not read as broken or empty.
  Widget _buildDisabledPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
              size: 56,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'imggen_disabled_placeholder'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ImageGenSettings s) {
    return Builder(
      builder: (context) => SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: ConnectionStatus(
                status: _connectionStatus,
                errorMessage: _connectionError,
                onRetry: _checkConnection,
                child: _buildPresetSelector(s.apiType),
              ),
            ),
            MenuGroup(
              header: 'imggen_connection'.tr(),
              items: _buildConnectionFields(s),
            ),
            MenuGroup(header: 'Model', items: _buildModelFields(s)),
            if (_modelFetchError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  _modelFetchError,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            MenuGroup(
              header: 'imggen_generation'.tr(),
              items: [
                MenuSwitchItem(
                  label: 'imggen_concurrent'.tr(),
                  description: 'imggen_concurrent_desc'.tr(),
                  value: s.concurrentGeneration,
                  onChanged: (v) =>
                      _update(s.copyWith(concurrentGeneration: v)),
                ),
              ],
            ),
            MenuGroup(
              header: 'imggen_styles'.tr(),
              items: [
                MenuSelectorItem(
                  label: 'imggen_style_active'.tr(),
                  currentValue: s.activeStyle?.name ?? 'imggen_style_none'.tr(),
                  onTap: _openStyleLibrary,
                ),
              ],
            ),
            if (s.apiType == ImageGenApiType.naistera &&
                !NaisteraConstants.supportsReferences(s.naisteraModel))
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.05),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    'imggen_no_refs_hint'.tr(),
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            if (providerMaxReferences(s) > 0)
              ...buildReferenceSections(
                context: context,
                settings: s,
                maxReferences: providerMaxReferences(s),
                onUpdate: _update,
                pickImage: _pickReferenceImage,
              ),
            if (providerMaxReferences(s) > 0)
              MenuGroup(
                header: 'Image Context',
                items: [
                  MenuSwitchItem(
                    label: 'Send previous images as context',
                    description: 'imggen_image_context_desc'.tr(),
                    value: s.imageContextEnabled,
                    onChanged: (v) =>
                        _update(s.copyWith(imageContextEnabled: v)),
                  ),
                  if (s.imageContextEnabled)
                    MenuSelectorItem(
                      label: 'Context image count',
                      currentValue: s.imageContextCount.toString(),
                      onTap: () {
                        _showOptions<int>(
                          title: 'Context image count',
                          items: [1, 2, 3],
                          labelBuilder: (i) => i.toString(),
                          isSelected: (i) => s.imageContextCount == i,
                          onSelected: (i) =>
                              _update(s.copyWith(imageContextCount: i)),
                        );
                      },
                    ),
                ],
              ),
            MenuGroup(
              header: 'imggen_tag_hint_title'.tr(),
              description: 'imggen_tag_hint_desc'.tr(),
              items: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: SelectableText(
                    '[IMG:GEN:{"prompt":"...","style":"anime"}]',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: context.cs.primary,
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

  /// The API-type pill. Sits left of the connection-status badge, mirroring
  /// the preset pill in the API settings screen.
  Widget _buildPresetSelector(ImageGenApiType selected) {
    return InkWell(
      onTap: _openApiTypeSelector,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selected.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.primary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: context.cs.primary,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildConnectionFields(ImageGenSettings s) {
    switch (s.apiType) {
      case ImageGenApiType.naistera:
        return buildNaisteraConnectionFields(s, _update);
      case ImageGenApiType.routmy:
        return buildRoutmyConnectionFields(s, isRu: false, onUpdate: _update);
      case ImageGenApiType.ruRoutmy:
        return buildRoutmyConnectionFields(s, isRu: true, onUpdate: _update);
      case ImageGenApiType.openrouter:
        return buildOpenRouterConnectionFields(s, _update);
      case ImageGenApiType.electronhub:
        return buildElectronHubConnectionFields(s, _update);
      case ImageGenApiType.a1111:
        return buildA1111ConnectionFields(s, _update);
      case ImageGenApiType.openai:
      case ImageGenApiType.gemini:
        return buildOpenaiConnectionFields(s, _update);
    }
  }

  void _openStyleLibrary() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StyleLibrarySheet(settings: _settings, onUpdate: _update),
    );
  }

  List<Widget> _buildModelFields(ImageGenSettings s) {
    final showOptions = _showOptionsCallback();
    switch (s.apiType) {
      case ImageGenApiType.naistera:
        return buildNaisteraModelFields(s, _update, showOptions);
      case ImageGenApiType.routmy:
        return buildRoutmyModelFields(
          s,
          isRu: false,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.ruRoutmy:
        return buildRoutmyModelFields(
          s,
          isRu: true,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.openai:
        return buildOpenaiModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.gemini:
        return buildGeminiModelFields(s, _update, showOptions);
      case ImageGenApiType.openrouter:
        return buildOpenRouterModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.electronhub:
        return buildElectronHubModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
      case ImageGenApiType.a1111:
        return buildA1111ModelFields(
          s,
          isFetching: _isFetchingModels,
          onFetchModels: _onFetchModels,
          onUpdate: _update,
          showOptions: showOptions,
        );
    }
  }

  ShowOptionsCallback _showOptionsCallback() {
    return <T>({
      required String title,
      required List<T> items,
      required String Function(T) labelBuilder,
      required bool Function(T) isSelected,
      required void Function(T) onSelected,
    }) {
      _showOptions<T>(
        title: title,
        items: items,
        labelBuilder: labelBuilder,
        isSelected: isSelected,
        onSelected: onSelected,
      );
    };
  }

  /// Model discovery differs per provider: OpenAI-style `/v1/models` for the
  /// OpenAI and Gemini paths, filtered listings for OpenRouter and Electron
  /// Hub, and loaded checkpoints for a local AUTOMATIC1111 server.
  Future<List<String>> _fetchModelsForProvider(ApiConfig? apiConfig) {
    switch (_settings.apiType) {
      case ImageGenApiType.openrouter:
        return _connectionService.fetchOpenRouterModels(_settings);
      case ImageGenApiType.electronhub:
        return _connectionService.fetchElectronHubModels(_settings);
      case ImageGenApiType.a1111:
        return _connectionService.fetchA1111Models(_settings);
      case ImageGenApiType.openai:
      case ImageGenApiType.gemini:
      case ImageGenApiType.naistera:
      case ImageGenApiType.routmy:
      case ImageGenApiType.ruRoutmy:
        return _connectionService.fetchOpenAiModels(
          settings: _settings,
          llmEndpoint: apiConfig?.endpoint ?? '',
          llmApiKey: apiConfig?.apiKey ?? '',
        );
    }
  }

  bool _isSelectedModel(String model) => switch (_settings.apiType) {
    ImageGenApiType.openrouter => _settings.openrouter.model == model,
    ImageGenApiType.electronhub => _settings.electronhub.model == model,
    ImageGenApiType.a1111 => _settings.a1111.model == model,
    _ => _settings.customModel == model,
  };

  void _applyModel(String model) {
    switch (_settings.apiType) {
      case ImageGenApiType.openrouter:
        _update(
          _settings.copyWith(
            openrouter: _settings.openrouter.copyWith(model: model),
          ),
        );
      case ImageGenApiType.electronhub:
        _update(
          _settings.copyWith(
            electronhub: _settings.electronhub.copyWith(model: model),
          ),
        );
      case ImageGenApiType.a1111:
        _update(
          _settings.copyWith(a1111: _settings.a1111.copyWith(model: model)),
        );
      default:
        _update(_settings.copyWith(customModel: model));
    }
  }

  Future<void> _onFetchModels() async {
    setState(() => _isFetchingModels = true);
    final apiConfig = ref.read(activeApiConfigProvider);
    try {
      final models = await _fetchModelsForProvider(apiConfig);
      if (!mounted) return;
      if (models.isEmpty) {
        setState(() => _modelFetchError = 'imggen_no_models'.tr());
        return;
      }
      setState(() => _modelFetchError = '');
      _showOptions<String>(
        title: 'Image models',
        items: models,
        labelBuilder: (model) => model,
        isSelected: _isSelectedModel,
        onSelected: _applyModel,
      );
    } catch (error) {
      if (!mounted) return;
      setState(
        () =>
            _modelFetchError = error.toString().replaceFirst('Bad state: ', ''),
      );
    } finally {
      if (mounted) setState(() => _isFetchingModels = false);
    }
  }

  Future<String?> _pickReferenceImage() async {
    final source = await GlazeBottomSheet.show<String>(
      context,
      title: 'imggen_ref_pick_title'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.folder_open,
          label: 'imggen_ref_pick_device'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop('device'),
        ),
        if (widget.charId != null)
          BottomSheetItem(
            icon: Icons.photo_library_outlined,
            label: 'imggen_ref_pick_gallery'.tr(),
            onTap: () =>
                Navigator.of(context, rootNavigator: true).pop('gallery'),
          ),
      ],
    );
    if (!mounted || source == null) return null;

    if (source == 'gallery') {
      final entry = await showCharacterGalleryImagePicker(
        context,
        charId: widget.charId!,
      );
      if (entry == null) return null;
      final path = resolveGlazeFilePath(entry.imagePath) ?? entry.imagePath;
      return _fileToDataUrl(File(path), path);
    }

    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    final bytes =
        picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null) return null;
    return 'data:${_imageMime(picked.name)};base64,${base64Encode(bytes)}';
  }

  Future<String?> _fileToDataUrl(File file, String path) async {
    try {
      if (!await file.exists()) return null;
      return 'data:${_imageMime(path)};base64,${base64Encode(await file.readAsBytes())}';
    } catch (_) {
      return null;
    }
  }

  String _imageMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }
}
