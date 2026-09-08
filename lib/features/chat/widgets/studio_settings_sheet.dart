import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../../core/llm/model_fetcher.dart';
import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/services/file_export_service.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../settings/api_list_provider.dart';
import '../../studio/services/studio_preset_workflow_service.dart';
import '../../studio/studio_preset_workflow_provider.dart';
import '../state/recovery_state_provider.dart';
import '../services/tracker_memory_recovery_service.dart';
import 'studio_preset_editor_sheet.dart';
import 'studio_agents_sheet.dart';
import 'studio_slot_settings_dialog.dart';

/// Studio Settings as a bottom sheet. Single scrollable page.
///
/// Contents:
/// - Studio enable/disable toggle
/// - 3 model dropdowns (final/tracker/cleaner) fetched from the active API
///   provider and stored in PipelineSettings
/// - Edit Preset Blocks button → opens [StudioPresetEditorSheet]
/// - Recovery button (re-run tracker/memory cycles)
class StudioSettingsSheet extends ConsumerStatefulWidget {
  final String charId;
  final String sessionId;

  const StudioSettingsSheet({
    super.key,
    required this.charId,
    required this.sessionId,
  });

  /// Convenience launcher.
  static Future<void> show(
    BuildContext context, {
    required String charId,
    required String sessionId,
  }) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'Studio',
      child: StudioSettingsSheet(charId: charId, sessionId: sessionId),
    );
  }

  @override
  ConsumerState<StudioSettingsSheet> createState() =>
      _StudioSettingsSheetState();
}

class _StudioSettingsSheetState extends ConsumerState<StudioSettingsSheet> {
  StudioConfig? _config;
  bool _loading = true;
  late final StudioPresetWorkflowService _presetWorkflows;

  final Map<String, List<String>> _fetchedModelsBySlot = {};
  final Set<String> _fetchingModelSlots = {};
  List<StudioPreset> _studioPresets = const [];

  @override
  void initState() {
    super.initState();
    _presetWorkflows = ref.read(studioPresetWorkflowServiceProvider);
    _load();
  }

  Future<void> _load() async {
    await ref.read(apiListProvider.future);
    final repo = ref.read(studioConfigRepoProvider);
    var config = await repo.getBySessionId(widget.sessionId);
    // Studio is global — if no config exists at all, auto-create a default
    // profile instead of showing an "Enable Studio" dialog.
    if (config == null) {
      final now = currentTimestampSeconds();
      config = StudioConfig(
        sessionId: widget.sessionId,
        enabled: true,
        agents: StudioControllerOntology.buildDefaultAgents(
          sessionId: widget.sessionId,
          now: now,
        ),
        createdAt: now,
        updatedAt: now,
      );
      await repo.upsert(config);
      // Auto-create enables Studio for the first time — refresh dependents.
      ref.invalidate(sessionStudioEnabledProvider(widget.sessionId));
    }
    final presets = await _presetWorkflows.loadPresets();
    if (!mounted) return;
    setState(() {
      _config = config;
      _studioPresets = presets;
      _loading = false;
    });
  }

  Future<void> _save(StudioConfig config) async {
    final repo = ref.read(studioConfigRepoProvider);
    await repo.upsert(config);
    // Refresh Studio-enablement-driven chat UI (e.g. the per-message "Re-run
    // cleaner" button) so toggling Studio reflects immediately.
    ref.invalidate(sessionStudioEnabledProvider(widget.sessionId));
    setState(() => _config = config);
  }

  Future<void> _changeStudioPreset(String presetId) async {
    // Global: one SharedPreferences key, applies to every session instantly.
    await _presetWorkflows.selectPreset(presetId);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return _buildBody();
  }

  Widget _buildBody() {
    final config = _config!;
    final pipeline = ref.watch(pipelineSettingsProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Studio Enabled'),
            value: config.enabled,
            onChanged: (v) => _save(config.copyWith(enabled: v)),
          ),
          const Divider(),
          _buildModeSelector(),
          const SizedBox(height: 4),
          _buildPresetSelector(),
          const Divider(),
          Text('Models', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _buildModelSlot(
            slot: StudioSlot.finalGenerator,
            label: 'Final Generator',
            description: 'Expensive — high-quality prose generation',
            emptyLabel: 'Use active chat model',
            value: pipeline.studioAgent.studioFinalModelOverride,
            apiConfigId: config.expensiveApiConfigId,
            onChanged: (model) => _savePipelineModel(
              (p) => p.copyWith(
                studioAgent: p.studioAgent.copyWith(
                  studioFinalModelOverride: model,
                ),
              ),
            ),
            onApiConfigChanged: (apiConfigId) =>
                _save(config.copyWith(expensiveApiConfigId: apiConfigId)),
            onSettings: () =>
                _openSlotSettings(slot: StudioSlot.finalGenerator),
          ),
          const SizedBox(height: 12),
          _buildModelSlot(
            slot: StudioSlot.tracker,
            label: 'Trackers',
            description: 'Cheap — compact JSON briefs, fast',
            emptyLabel: 'Use active chat model',
            value: pipeline.studioAgent.studioTrackerModelOverride,
            apiConfigId: config.cheapApiConfigId,
            onChanged: (model) => _savePipelineModel(
              (p) => p.copyWith(
                studioAgent: p.studioAgent.copyWith(
                  studioTrackerModelOverride: model,
                ),
              ),
            ),
            onApiConfigChanged: (apiConfigId) =>
                _save(config.copyWith(cheapApiConfigId: apiConfigId)),
            onSettings: () => _openSlotSettings(slot: StudioSlot.tracker),
          ),
          const SizedBox(height: 12),
          _buildModelSlot(
            slot: StudioSlot.cleaner,
            label: 'Cleaner (Post-Processing)',
            description: 'Semi-expensive — prose rewrite + continuity audit',
            emptyLabel: 'Use tracker/chat model',
            value: pipeline.cleaner.postCleanerModel,
            apiConfigId: config.cleanerApiConfigId,
            onChanged: (model) => _savePipelineModel(
              (p) => p.copyWith(
                cleaner: p.cleaner.copyWith(postCleanerModel: model),
              ),
            ),
            onApiConfigChanged: (apiConfigId) =>
                _save(config.copyWith(cleanerApiConfigId: apiConfigId)),
            onSettings: () => _openSlotSettings(slot: StudioSlot.cleaner),
          ),
          const Divider(),
          // ── Post-gen toggles ───────────────────────────────────────────
          _buildPostGenToggles(pipeline),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('Agents'),
            subtitle: const Text('Enable or disable individual Studio agents'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final presetId = await ref.read(
                activeStudioPresetProvider.future,
              );
              if (!mounted) return;
              await GlazeBottomSheet.show<void>(
                context,
                title: 'Agents',
                child: StudioAgentsSheet(presetId: presetId),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: const Text('Edit Preset Blocks'),
            subtitle: const Text('Trackers, Final Agent, Cleaner, Ledger'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final presetId = await ref.read(
                activeStudioPresetProvider.future,
              );
              if (!mounted) return;
              await GlazeBottomSheet.show<void>(
                context,
                title: 'Preset Blocks',
                child: StudioPresetEditorSheet(presetId: presetId),
              );
            },
          ),
          const Divider(),
          _buildPostTrackerContextSetting(pipeline),
          const Divider(),
          _buildRecoverySection(),
        ],
      ),
    );
  }

  Future<void> _savePipelineModel(
    PipelineSettings Function(PipelineSettings pipeline) mutate,
  ) async {
    final pipeline = ref.read(pipelineSettingsProvider);
    await ref.read(pipelineSettingsProvider.notifier).save(mutate(pipeline));
  }

  StudioPreset? get _activeStudioPreset {
    final activePresetId =
        ref.watch(activeStudioPresetProvider).value ?? 'default';
    return _studioPresets.where((p) => p.id == activePresetId).firstOrNull;
  }

  String _modeLabel(StudioExecutionMode mode) {
    return switch (mode) {
      StudioExecutionMode.legacy => 'Legacy — full controller pipeline',
      StudioExecutionMode.direct => 'Direct Loom — FINAL without pregen',
      StudioExecutionMode.assisted =>
        'Assisted Loom — Continuity + Scene Director + Beauty',
    };
  }

  Widget _buildModeSelector() {
    final current = _activeStudioPreset;
    final mode = current?.executionMode ?? StudioExecutionMode.legacy;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.account_tree_outlined),
      title: const Text('Studio Mode'),
      subtitle: Text(_modeLabel(mode)),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: _openStudioModeSelector,
    );
  }

  Widget _buildPresetSelector() {
    final activePresetId =
        ref.watch(activeStudioPresetProvider).value ?? 'default';
    final current = _activeStudioPreset;
    final label = current?.name.isNotEmpty == true
        ? current!.name
        : activePresetId;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.view_module_outlined),
      title: const Text('Studio Preset'),
      subtitle: Text(
        label.isEmpty ? 'Default' : label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: _openStudioPresetSelector,
    );
  }

  Future<void> _openStudioModeSelector() async {
    final current = _activeStudioPreset;
    final items = <BottomSheetItem>[
      for (final mode in StudioExecutionMode.values)
        BottomSheetItem(
          label: _modeLabel(mode),
          hint: switch (mode) {
            StudioExecutionMode.legacy =>
              'Keep the selected full Studio preset and all enabled controllers.',
            StudioExecutionMode.direct => 'FINAL only; no pregen controllers.',
            StudioExecutionMode.assisted =>
              'Continuity, Scene Director, and Beauty before FINAL.',
          },
          icon: current?.executionMode == mode ? Icons.check : null,
          iconColor: Theme.of(context).colorScheme.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            unawaited(_selectStudioMode(mode));
          },
        ),
    ];
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Studio Mode',
      items: items,
    );
  }

  Future<void> _selectStudioMode(StudioExecutionMode mode) async {
    final current = _activeStudioPreset;
    if (current?.executionMode == mode) return;
    final candidates = _studioPresets
        .where((preset) => preset.executionMode == mode)
        .toList();
    final preset =
        candidates
            .where((candidate) => candidate.name.startsWith('Loom Adapt v1'))
            .firstOrNull ??
        candidates.firstOrNull;
    if (preset == null) {
      if (mounted) {
        GlazeToast.show(
          context,
          'Import a ${mode.wireName} Studio preset first.',
        );
      }
      return;
    }
    await _changeStudioPreset(preset.id);
  }

  Future<void> _openStudioPresetSelector() async {
    final items = <BottomSheetItem>[
      BottomSheetItem(
        label: 'Create new preset',
        hint: 'Copy the current full block set',
        icon: Icons.add,
        iconColor: Theme.of(context).colorScheme.primary,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          unawaited(_createStudioPreset());
        },
      ),
      BottomSheetItem(
        label: 'Import preset from file',
        hint: 'Create a new preset from a JSON file',
        icon: Icons.file_upload_outlined,
        iconColor: Theme.of(context).colorScheme.primary,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          unawaited(_importPreset());
        },
      ),
      ..._studioPresets.map((preset) {
        final active =
            preset.id ==
            (ref.read(activeStudioPresetProvider).value ?? 'default');
        final name = preset.name.isNotEmpty ? preset.name : preset.id;
        final sections =
            preset.blocks
                .where((b) => b.enabled)
                .map((b) => b.section)
                .toSet()
                .toList()
              ..sort();
        return BottomSheetItem(
          label: name,
          hint: sections.isEmpty ? preset.id : sections.join(', '),
          icon: active ? Icons.check : null,
          iconColor: Theme.of(context).colorScheme.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _changeStudioPreset(preset.id);
          },
          actions: [
            BottomSheetAction(
              icon: Icons.file_download_outlined,
              onTap: () => _exportPreset(preset),
            ),
            if (preset.id != 'default')
              BottomSheetAction(
                icon: Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
                onTap: () {
                  Navigator.of(context, rootNavigator: true).pop();
                  _deletePreset(preset);
                },
              ),
          ],
        );
      }),
    ];
    await GlazeBottomSheet.show<void>(
      context,
      title: 'Studio Presets',
      items: items,
    );
  }

  Future<void> _createStudioPreset() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New Studio Preset'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Preset name',
            hintText: 'My Studio Preset',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(nameCtrl.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    final trimmedName = name?.trim() ?? '';
    if (!mounted || trimmedName.isEmpty) return;

    final result = await _presetWorkflows.createPreset(
      name: trimmedName,
      availablePresets: _studioPresets,
    );
    if (!mounted) return;
    if (result == null) {
      GlazeToast.show(context, 'No Studio preset to copy.');
      return;
    }
    setState(() => _studioPresets = result.presets);
  }

  Future<void> _importPreset() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    try {
      final bytes = result.files.single.bytes;
      if (bytes == null) {
        if (mounted) GlazeToast.show(context, 'Could not read preset file.');
        return;
      }
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final imported = StudioPreset.fromJson(decoded);
      if (!mounted) return;

      final nameCtrl = TextEditingController(
        text: imported.name.isNotEmpty ? imported.name : 'Imported Preset',
      );
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Import Studio Preset'),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Preset name',
              hintText: 'My Imported Preset',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(nameCtrl.text),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      nameCtrl.dispose();
      final trimmedName = name?.trim() ?? '';
      if (!mounted || trimmedName.isEmpty) return;

      final importResult = await _presetWorkflows.importPreset(
        imported: imported,
        name: trimmedName,
      );
      if (!mounted) return;
      if (importResult == null) return;
      setState(() => _studioPresets = importResult.presets);
      if (mounted) GlazeToast.show(context, 'Preset "$trimmedName" imported.');
    } catch (e) {
      if (mounted) GlazeToast.show(context, 'Failed to import preset: $e');
    }
  }

  Future<void> _exportPreset(StudioPreset preset) async {
    final safeName = (preset.name.isNotEmpty ? preset.name : preset.id)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final data = const JsonEncoder.withIndent('  ').convert(preset.toJson());
    try {
      final path = await FileExportService.export(
        data: data,
        filename: 'studio_preset_$safeName.json',
        subfolder: 'studio_presets',
      );
      if (mounted) GlazeToast.show(context, 'Preset exported to $path');
    } catch (e) {
      if (mounted) GlazeToast.show(context, 'Failed to export preset: $e');
    }
  }

  Future<void> _deletePreset(StudioPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Preset'),
        content: Text(
          'Delete "${preset.name.isNotEmpty ? preset.name : preset.id}"? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final nextPresets = await _presetWorkflows.deletePreset(preset.id);
    if (!mounted) return;
    setState(() => _studioPresets = nextPresets);
    if (mounted) GlazeToast.show(context, 'theme_preset_deleted'.tr());
  }

  Widget _buildPostTrackerContextSetting(PipelineSettings pipeline) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Post-Processing', style: tt.titleSmall),
        const SizedBox(height: 4),
        Text(
          'How many chat messages post-processing trackers receive '
          '(last turn + the response to edit).',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final value in const [1, 2, 3, 5])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text('$value'),
                  selected:
                      pipeline.studioAgent.studioPostTrackerContextSize ==
                      value,
                  onSelected: (_) => _savePipelineModel(
                    (p) => p.copyWith(
                      studioAgent: p.studioAgent.copyWith(
                        studioPostTrackerContextSize: value,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildModelSlot({
    required StudioSlot slot,
    required String label,
    required String description,
    required String value,
    required String apiConfigId,
    required String emptyLabel,
    required ValueChanged<String> onChanged,
    required ValueChanged<String> onApiConfigChanged,
    required VoidCallback onSettings,
  }) {
    final apiConfigs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final apiConfig = _slotApiConfig(apiConfigId, apiConfigs);
    final modelCacheKey = _modelCacheKey(slot, apiConfigId, apiConfigs);
    final fetchedModels =
        _fetchedModelsBySlot[modelCacheKey] ?? const <String>[];
    final fetchingModels = _fetchingModelSlots.contains(modelCacheKey);
    final models = <String>{
      ...fetchedModels,
      if (value.isNotEmpty) value,
      if (apiConfig?.model.isNotEmpty == true) apiConfig!.model,
    }.toList()..sort();

    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final usesOtherApi = apiConfigId.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: tt.titleSmall)),
            IconButton(
              icon: const Icon(Icons.tune, size: 18),
              tooltip: 'Settings',
              onPressed: onSettings,
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(4),
                minimumSize: const Size(28, 28),
              ),
            ),
          ],
        ),
        Text(
          description,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Другой API'),
          subtitle: Text(
            usesOtherApi
                ? _apiConfigLabel(apiConfigId, apiConfigs)
                : 'Use active chat API',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: usesOtherApi,
          onChanged: (checked) {
            if (checked == true) {
              _openApiConfigSelector(
                currentId: apiConfigId,
                onSelected: onApiConfigChanged,
              );
            } else {
              onApiConfigChanged('');
              setState(() => _clearSlotModelCache(slot));
            }
          },
        ),
        if (usesOtherApi)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _openApiConfigSelector(
                currentId: apiConfigId,
                onSelected: onApiConfigChanged,
              ),
              icon: const Icon(Icons.api, size: 16),
              label: const Text('Select API preset'),
            ),
          ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: models.contains(value) || value.isEmpty ? value : null,
          isExpanded: true,
          decoration: InputDecoration(
            helperText: fetchingModels
                ? 'Loading models...'
                : fetchedModels.isEmpty
                ? 'Open this field to load models from ${usesOtherApi ? 'the selected API config' : 'the active API config'}'
                : '${fetchedModels.length} models available',
            helperMaxLines: 2,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            DropdownMenuItem<String>(
              value: '',
              child: Text(emptyLabel, overflow: TextOverflow.ellipsis),
            ),
            ...models.map(
              (model) => DropdownMenuItem<String>(
                value: model,
                child: Text(model, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onTap: fetchingModels
              ? null
              : () => unawaited(_fetchModels(slot, apiConfigId)),
          onChanged: (model) => onChanged(model ?? ''),
        ),
      ],
    );
  }

  ApiConfig? _slotApiConfig(String apiConfigId, List<ApiConfig> apiConfigs) {
    if (apiConfigId.isNotEmpty) {
      final selected = apiConfigs.where((c) => c.id == apiConfigId).firstOrNull;
      if (selected != null) return selected;
    }
    return ref.read(activeApiConfigProvider);
  }

  String _modelCacheKey(
    StudioSlot slot,
    String apiConfigId,
    List<ApiConfig> apiConfigs,
  ) {
    final config = _slotApiConfig(apiConfigId, apiConfigs);
    final apiKey = config == null
        ? apiConfigId
        : '${config.id}|${config.endpoint}|${config.model}';
    return '${slot.name}:$apiKey';
  }

  void _clearSlotModelCache(StudioSlot slot) {
    final prefix = '${slot.name}:';
    _fetchedModelsBySlot.removeWhere((key, _) => key.startsWith(prefix));
    _fetchingModelSlots.removeWhere((key) => key.startsWith(prefix));
  }

  String _apiConfigLabel(String apiConfigId, List<ApiConfig> apiConfigs) {
    final config = apiConfigs.where((c) => c.id == apiConfigId).firstOrNull;
    if (config == null) return 'Missing API preset';
    if (config.name.isNotEmpty) return config.name;
    if (config.model.isNotEmpty) return config.model;
    return config.endpoint.isNotEmpty ? config.endpoint : config.id;
  }

  Future<void> _openApiConfigSelector({
    required String currentId,
    required ValueChanged<String> onSelected,
  }) async {
    final apiConfigs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    if (apiConfigs.isEmpty) {
      GlazeToast.show(context, 'No API configs found.');
      return;
    }
    await GlazeBottomSheet.show<void>(
      context,
      title: 'API Preset',
      items: apiConfigs.map((config) {
        final active = config.id == currentId;
        final label = config.name.isNotEmpty
            ? config.name
            : config.model.isNotEmpty
            ? config.model
            : config.id;
        return BottomSheetItem(
          label: label,
          hint: config.endpoint,
          icon: active ? Icons.check : null,
          iconColor: Theme.of(context).colorScheme.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            onSelected(config.id);
          },
        );
      }).toList(),
    );
  }

  Future<void> _fetchModels(StudioSlot slot, String apiConfigId) async {
    final apiConfigs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final modelCacheKey = _modelCacheKey(slot, apiConfigId, apiConfigs);
    if (_fetchingModelSlots.contains(modelCacheKey)) return;
    final config = _slotApiConfig(apiConfigId, apiConfigs);
    if (config == null) {
      GlazeToast.show(context, 'No API configs found.');
      return;
    }
    setState(() => _fetchingModelSlots.add(modelCacheKey));
    try {
      final ids = await ModelFetcher.fetchModelIds(
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        fallbackModel: config.model,
      );
      if (!mounted) return;
      setState(() => _fetchedModelsBySlot[modelCacheKey] = ids);
    } catch (e) {
      if (mounted) {
        GlazeToast.show(context, 'Failed to fetch models: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _fetchingModelSlots.remove(modelCacheKey));
      }
    }
  }

  Widget _buildPostGenToggles(PipelineSettings pipeline) {
    final cleaner = pipeline.cleaner;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Post-Gen', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Пост-клинер'),
          subtitle: const Text(
            'Факт-чекер + пост-клинер: аудит и перезапись ответа',
          ),
          value: cleaner.postCleanerEnabled,
          onChanged: (v) => _savePipeline(
            (p) =>
                p.copyWith(cleaner: p.cleaner.copyWith(postCleanerEnabled: v)),
          ),
        ),
      ],
    );
  }

  Future<void> _savePipeline(
    PipelineSettings Function(PipelineSettings) mutate,
  ) async {
    final pipeline = ref.read(pipelineSettingsProvider);
    await ref.read(pipelineSettingsProvider.notifier).save(mutate(pipeline));
  }

  Widget _buildRecoverySection() {
    final state = ref.watch(recoveryStateProvider);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isRunning = state.isActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recovery', style: tt.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Re-runs the Studio tracker cycle for all assistant messages in '
          'this session.',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (isRunning) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  state.totalMessages > 0
                      ? 'Processing message ${state.processedMessages} of ${state.totalMessages}'
                      : 'Starting...',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.totalMessages > 0
                  ? state.processedMessages / state.totalMessages
                  : null,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () =>
                  ref.read(trackerMemoryRecoveryServiceProvider).cancel(),
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('Cancel'),
              style: TextButton.styleFrom(foregroundColor: cs.error),
            ),
          ),
        ] else if (state.isDone) ...[
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Done: ${state.trackersWritten} trackers, '
                  '${state.failedMessages} failed',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => _startRecovery(),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('Run Recovery'),
          ),
        ] else ...[
          FilledButton.tonalIcon(
            onPressed: () => _startRecovery(),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('Run Recovery'),
          ),
        ],
      ],
    );
  }

  Future<void> _openSlotSettings({required StudioSlot slot}) async {
    final updated = await showModalBottomSheet<StudioSlotSettings>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (c) => StudioSlotSettingsDialog(
        slot: slot,
        pipeline: ref.read(pipelineSettingsProvider),
      ),
    );
    if (!mounted || updated == null) return;
    final pipeline = ref.read(pipelineSettingsProvider);
    await ref
        .read(pipelineSettingsProvider.notifier)
        .save(updated.applyTo(pipeline, slot));
  }

  Future<void> _startRecovery() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Recovery'),
        content: const Text(
          'This will re-run the Studio tracker cycle for every assistant '
          'message in this session. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Run Recovery'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    unawaited(
      ref
          .read(trackerMemoryRecoveryServiceProvider)
          .recover(sessionId: widget.sessionId, charId: widget.charId),
    );
  }
}
