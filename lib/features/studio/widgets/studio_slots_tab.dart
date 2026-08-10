import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/model_fetcher.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../settings/api_list_provider.dart';
import '../studio_injection_points.dart';
import 'studio_slot_settings_dialog.dart';

/// The "Agents" tab of the API settings sheet: which API connection and which
/// model each Studio stage runs on.
///
/// Slots mirror the pipeline stages one-to-one, so they carry the same labels
/// as the agentic preset editor's sections. Everything is optional — an empty
/// slot falls back to the connection selected in the LLM tab, which is the
/// behaviour an untouched install already has.
///
/// Each stage is one group of three dropdown-style rows: the API connection,
/// the model override, and a link into [StudioSlotSettingsDialog] for that
/// stage's parameter overrides.
class StudioSlotsTab extends ConsumerStatefulWidget {
  final ScrollController controller;

  const StudioSlotsTab({super.key, required this.controller});

  @override
  ConsumerState<StudioSlotsTab> createState() => _StudioSlotsTabState();
}

class _StudioSlotsTabState extends ConsumerState<StudioSlotsTab> {
  /// Fetched model id lists keyed by `'<slot>:<apiConfigId>|<endpoint>|<model>'`.
  final Map<String, List<String>> _fetchedModelsBySlot = {};

  /// Cache keys currently being fetched, to avoid duplicate requests.
  final Set<String> _fetchingModelSlots = {};

  @override
  Widget build(BuildContext context) {
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final profile = ref.watch(studioPresetProvider).value;
    final pipeline = ref.watch(pipelineSettingsProvider);

    return ListView(
      controller: widget.controller,
      // The sheet injects the header height into padding.top and the nav bar's
      // into padding.bottom, so the list clears both — same as the other tabs.
      // Horizontal insets come from MenuGroup itself.
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 12,
        bottom: MediaQuery.paddingOf(context).bottom + 16,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'studio_slots_hint'.tr(),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
        ),
        _slot(
          context,
          configs: configs,
          slotName: 'pregen',
          studioSlot: StudioSlot.controller,
          title: studioInjectionPointLabel('pregen'),
          description: 'studio_slot_pregen_desc'.tr(),
          apiConfigId: profile?.cheapApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(cheapApiConfigId: id),
            slotName: 'pregen',
          ),
          model: pipeline.studioAgent.studioControllerModelOverride,
          onModelChanged: (value) => _savePipeline(
            (p) => p.copyWith(
              studioAgent: p.studioAgent.copyWith(
                studioControllerModelOverride: value,
              ),
            ),
          ),
        ),
        _slot(
          context,
          configs: configs,
          slotName: 'final',
          studioSlot: StudioSlot.finalGenerator,
          title: studioInjectionPointLabel('final'),
          description: 'studio_slot_final_desc'.tr(),
          apiConfigId: profile?.expensiveApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(expensiveApiConfigId: id),
            slotName: 'final',
          ),
          model: pipeline.studioAgent.studioFinalModelOverride,
          onModelChanged: (value) => _savePipeline(
            (p) => p.copyWith(
              studioAgent: p.studioAgent.copyWith(
                studioFinalModelOverride: value,
              ),
            ),
          ),
        ),
        _slot(
          context,
          configs: configs,
          slotName: 'cleaner',
          studioSlot: StudioSlot.cleaner,
          title: studioInjectionPointLabel('cleaner'),
          description: 'studio_slot_cleaner_desc'.tr(),
          apiConfigId: profile?.cleanerApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(cleanerApiConfigId: id),
            slotName: 'cleaner',
          ),
          model: pipeline.cleaner.postCleanerModel,
          onModelChanged: (value) => _savePipeline(
            (p) => p.copyWith(
              cleaner: p.cleaner.copyWith(postCleanerModel: value),
            ),
          ),
          // The Fact Checker pass runs before the rewrite and can use a cheaper
          // model. It inherits the cleaner's connection — only the model differs.
          extraLabel: 'studio_slot_audit_model'.tr(),
          extraDescription: 'studio_slot_audit_model_desc'.tr(),
          extraValue: pipeline.cleaner.postCleanerAuditModel,
          onExtraChanged: (value) => _savePipeline(
            (p) => p.copyWith(
              cleaner: p.cleaner.copyWith(postCleanerAuditModel: value),
            ),
          ),
        ),
        _slot(
          context,
          configs: configs,
          slotName: 'ledger',
          studioSlot: StudioSlot.ledger,
          title: studioInjectionPointLabel('ledger'),
          description: 'studio_slot_ledger_desc'.tr(),
          apiConfigId: profile?.ledgerApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(ledgerApiConfigId: id),
            slotName: 'ledger',
          ),
          model: pipeline.ledger.studioLedgerModel,
          onModelChanged: (value) => _savePipeline(
            (p) =>
                p.copyWith(ledger: p.ledger.copyWith(studioLedgerModel: value)),
          ),
        ),
      ],
    );
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Slot API bindings live on the default Studio preset new sessions inherit;
  /// the preset row is seeded on the first edit, never just by opening the tab.
  Future<void> _saveProfile(
    StudioPreset Function(StudioPreset) mutate, {
    required String slotName,
  }) async {
    final repo = ref.read(studioPresetRepoProvider);
    final preset = await repo.ensureDefaultSeeded();
    await repo.upsert(
      mutate(
        preset,
      ).copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000),
    );
    ref.invalidate(studioPresetProvider);
    // The model list is keyed by the connection; clear it so the next open
    // refetches against the new endpoint/key.
    if (mounted) setState(() => _clearSlotModelCache(slotName));
  }

  /// Model overrides and generation settings are global app settings.
  Future<void> _savePipeline(
    PipelineSettings Function(PipelineSettings) mutate,
  ) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref.read(pipelineSettingsProvider.notifier).save(mutate(pipeline));
  }

  // ── Rows ───────────────────────────────────────────────────────────────────

  /// One stage = one settings group: the stage name as its header, its blurb
  /// as the description, then the connection, the model override and the link
  /// to this stage's parameter overrides.
  Widget _slot(
    BuildContext context, {
    required List<ApiConfig> configs,
    required String slotName,
    required StudioSlot studioSlot,
    required String title,
    required String description,
    required String apiConfigId,
    required ValueChanged<String> onApiConfigChanged,
    required String model,
    required ValueChanged<String> onModelChanged,
    String? extraLabel,
    String? extraDescription,
    String? extraValue,
    ValueChanged<String>? onExtraChanged,
  }) {
    return MenuGroup(
      header: title,
      description: description,
      items: [
        MenuSelectorItem(
          label: 'studio_slot_api'.tr(),
          currentValue: _apiName(configs, apiConfigId),
          onTap: () => _pickApiConfig(
            context,
            configs: configs,
            selectedId: apiConfigId,
            onSelected: onApiConfigChanged,
          ),
        ),
        _modelSelector(
          slotName: slotName,
          apiConfigId: apiConfigId,
          value: model,
          onChanged: onModelChanged,
        ),
        if (extraLabel != null && onExtraChanged != null)
          _modelSelector(
            slotName: 'cleaner_audit',
            apiConfigId: apiConfigId,
            value: extraValue ?? '',
            onChanged: onExtraChanged,
            label: extraLabel,
            description: extraDescription,
          ),
        MenuItem(
          icon: Icons.tune,
          label: 'studio_slot_parameters'.tr(),
          subtitle: 'studio_slot_parameters_desc'.tr(),
          trailing: Icon(
            Icons.chevron_right,
            size: 22,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          onTap: () => _openSlotSettings(studioSlot, apiConfigId, configs),
        ),
      ],
    );
  }

  /// A model override row rendered as a dropdown. Empty reads as "Automatic",
  /// and the picker always offers that entry back so a slot can be returned to
  /// the connection's own model.
  Widget _modelSelector({
    required String slotName,
    required String apiConfigId,
    required String value,
    required ValueChanged<String> onChanged,
    String? label,
    String? description,
  }) {
    return MenuSelectorItem(
      label: label ?? 'studio_slot_model'.tr(),
      description: description,
      currentValue: value.isEmpty ? 'studio_slot_model_auto'.tr() : value,
      onTap: () => _openModelSelector(
        slotName: slotName,
        apiConfigId: apiConfigId,
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  String _apiName(List<ApiConfig> configs, String id) {
    if (id.isEmpty) return 'studio_slot_use_chat_api'.tr();
    final config = configs.where((c) => c.id == id).firstOrNull;
    if (config == null) return 'unnamed_entry'.tr();
    if (config.name.isNotEmpty) return config.name;
    if (config.model.isNotEmpty) return config.model;
    return 'unnamed_entry'.tr();
  }

  void _pickApiConfig(
    BuildContext context, {
    required List<ApiConfig> configs,
    required String selectedId,
    required ValueChanged<String> onSelected,
  }) {
    BottomSheetItem radio(String id, String label) => BottomSheetItem(
      label: label,
      icon: selectedId == id
          ? Icons.radio_button_checked
          : Icons.radio_button_off,
      iconColor: selectedId == id
          ? context.cs.primary
          : context.cs.onSurfaceVariant,
      onTap: () {
        Navigator.of(context, rootNavigator: true).pop();
        onSelected(id);
      },
    );

    GlazeBottomSheet.show<void>(
      context,
      title: 'studio_slot_api'.tr(),
      items: [
        radio('', 'studio_slot_use_chat_api'.tr()),
        for (final config in configs)
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

  // ── Fetched model picker ───────────────────────────────────────────────────

  ApiConfig? _slotApiConfig(String apiConfigId, List<ApiConfig> configs) {
    if (apiConfigId.isNotEmpty) {
      final selected = configs.where((c) => c.id == apiConfigId).firstOrNull;
      if (selected != null) return selected;
    }
    return ref.read(activeApiConfigProvider);
  }

  String _modelCacheKey(
    String slotName,
    String apiConfigId,
    List<ApiConfig> configs,
  ) {
    final config = _slotApiConfig(apiConfigId, configs);
    final apiKey = config == null
        ? apiConfigId
        : '${config.id}|${config.endpoint}|${config.model}';
    return '$slotName:$apiKey';
  }

  void _clearSlotModelCache(String slotName) {
    final prefix = '$slotName:';
    _fetchedModelsBySlot.removeWhere((key, _) => key.startsWith(prefix));
    _fetchingModelSlots.removeWhere((key) => key.startsWith(prefix));
  }

  Future<void> _fetchModels({
    required String slotName,
    required String apiConfigId,
  }) async {
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final cacheKey = _modelCacheKey(slotName, apiConfigId, configs);
    if (_fetchingModelSlots.contains(cacheKey)) return;
    final config = _slotApiConfig(apiConfigId, configs);
    if (config == null) {
      GlazeToast.show(context, 'studio_slot_no_api'.tr());
      return;
    }
    setState(() => _fetchingModelSlots.add(cacheKey));
    try {
      final ids = await ModelFetcher.fetchModelIds(
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        fallbackModel: config.model,
      );
      if (!mounted) return;
      setState(() => _fetchedModelsBySlot[cacheKey] = ids);
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'settings_err_failed'.tr());
      }
    } finally {
      if (mounted) {
        setState(() => _fetchingModelSlots.remove(cacheKey));
      }
    }
  }

  Future<void> _openModelSelector({
    required String slotName,
    required String apiConfigId,
    required String value,
    required ValueChanged<String> onChanged,
  }) async {
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    final cacheKey = _modelCacheKey(slotName, apiConfigId, configs);
    final fetched = _fetchedModelsBySlot[cacheKey] ?? const <String>[];
    if (fetched.isEmpty) {
      await _fetchModels(slotName: slotName, apiConfigId: apiConfigId);
      if (!mounted) return;
    }
    final models = <String>{
      ...?_fetchedModelsBySlot[cacheKey],
      if (value.isNotEmpty) value,
    }.toList()..sort();
    // "Automatic" is always offered, even when the fetch came back empty —
    // otherwise a slot pointed at a stale model id could never be reset.
    final items = <BottomSheetItem>[
      BottomSheetItem(
        label: 'studio_slot_model_auto'.tr(),
        icon: value.isEmpty ? Icons.check : null,
        iconColor: context.cs.primary,
        onTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          onChanged('');
        },
      ),
      for (final m in models)
        BottomSheetItem(
          label: m,
          icon: m == value ? Icons.check : null,
          iconColor: context.cs.primary,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            onChanged(m);
          },
        ),
    ];
    if (models.isEmpty) GlazeToast.show(context, 'settings_err_no_models'.tr());
    final selectedIndex = models.indexOf(value);
    await GlazeBottomSheet.show<void>(
      context,
      title: 'onboarding_select_model'.tr(),
      // +1 for the leading "Automatic" entry.
      scrollToIndex: selectedIndex >= 0 ? selectedIndex + 1 : null,
      items: items,
    );
  }

  // ── Advanced slot settings ─────────────────────────────────────────────────

  Future<void> _openSlotSettings(
    StudioSlot slot,
    String apiConfigId,
    List<ApiConfig> configs,
  ) async {
    final pipeline = ref.read(pipelineSettingsProvider);
    final presetConfig = _slotApiConfig(apiConfigId, configs);
    final updated = await showModalBottomSheet<StudioSlotSettings>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StudioSlotSettingsDialog(
        slot: slot,
        pipeline: pipeline,
        presetConfig: presetConfig,
      ),
    );
    if (!mounted || updated == null) return;
    await _savePipeline((p) => updated.applyTo(p, slot));
  }
}
