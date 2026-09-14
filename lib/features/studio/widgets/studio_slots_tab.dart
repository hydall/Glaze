import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/widgets/api_slot_group.dart';
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

  /// Scroll target for a deep link that opens the API screen *on* the
  /// MemoryBook slot — the memory settings sheet links here. Owned by the
  /// hosting screen, which is what runs the scroll, and passed in rather than
  /// held here so two mounted screens cannot collide on one [GlobalKey].
  final Key? memoryBookSlotKey;

  const StudioSlotsTab({
    super.key,
    required this.controller,
    this.memoryBookSlotKey,
  });

  @override
  ConsumerState<StudioSlotsTab> createState() => _StudioSlotsTabState();
}

class _StudioSlotsTabState extends ConsumerState<StudioSlotsTab> {
  @override
  Widget build(BuildContext context) {
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
          slotName: 'pregen',
          studioSlot: StudioSlot.controller,
          title: studioInjectionPointLabel('pregen'),
          description: 'studio_slot_pregen_desc'.tr(),
          apiConfigId: profile?.cheapApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(cheapApiConfigId: id),
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
          slotName: 'final',
          studioSlot: StudioSlot.finalGenerator,
          title: studioInjectionPointLabel('final'),
          description: 'studio_slot_final_desc'.tr(),
          apiConfigId: profile?.expensiveApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(expensiveApiConfigId: id),
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
          slotName: 'cleaner',
          studioSlot: StudioSlot.cleaner,
          title: studioInjectionPointLabel('cleaner'),
          description: 'studio_slot_cleaner_desc'.tr(),
          apiConfigId: profile?.cleanerApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(cleanerApiConfigId: id),
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
          slotName: 'ledger',
          studioSlot: StudioSlot.ledger,
          title: studioInjectionPointLabel('ledger'),
          description: 'studio_slot_ledger_desc'.tr(),
          apiConfigId: profile?.ledgerApiConfigId ?? '',
          onApiConfigChanged: (id) => _saveProfile(
            (c) => c.copyWith(ledgerApiConfigId: id),
          ),
          model: pipeline.ledger.studioLedgerModel,
          onModelChanged: (value) => _savePipeline(
            (p) =>
                p.copyWith(ledger: p.ledger.copyWith(studioLedgerModel: value)),
          ),
        ),
        // MemoryBook draft generation is an auxiliary LLM call like the ones
        // above, so it is bound here alongside them. The memory sheet's own
        // API block edits the same slot through the same widget; it buffers
        // the edit until Save, where this tab writes through on change.
        _slot(
          context,
          key: widget.memoryBookSlotKey,
          slotName: 'memory_book',
          studioSlot: null,
          title: 'magic_memory_books'.tr(),
          description: 'memory_books_slot_desc'.tr(),
          apiConfigId: pipeline.memoryBookApi.apiConfigId,
          onApiConfigChanged: (id) => _saveMemoryBookApi(
            (api) => api.copyWith(
              apiConfigId: id,
              // Endpoint and key always come from the selected connection;
              // a model chosen against the previous one would not resolve.
              generationSource: 'current',
              generationModel: '',
            ),
          ),
          model: pipeline.memoryBookApi.generationModel,
          onModelChanged: (value) => _saveMemoryBookApi(
            (api) => api.copyWith(generationModel: value),
          ),
        ),
      ],
    );
  }

  Future<void> _saveMemoryBookApi(
    MemoryBookApiSettings Function(MemoryBookApiSettings) mutate,
  ) => _savePipeline((p) => p.copyWith(memoryBookApi: mutate(p.memoryBookApi)));

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Slot API bindings live on the **active** Studio preset — the one a turn
  /// resolves through `StudioTurnConfigResolver`. Writing to `default` instead
  /// would drop the binding for anyone running a different preset, while the
  /// global model override still applied, sending that model to whatever
  /// connection the turn fell back to.
  ///
  /// The `default` row is seeded on the first edit only when the active id no
  /// longer resolves, never just by opening the tab.
  Future<void> _saveProfile(StudioPreset Function(StudioPreset) mutate) async {
    final repo = ref.read(studioPresetRepoProvider);
    final activeId = await ref.read(activeStudioPresetProvider.future);
    final preset =
        await repo.getById(activeId) ?? await repo.ensureDefaultSeeded();
    await repo.upsert(
      mutate(
        preset,
      ).copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000),
    );
    ref.invalidate(studioPresetProvider);
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
  ///
  /// The rows themselves, their pickers and the fetched-model cache live in
  /// [ApiSlotGroup] — MemoryBook's own settings sheet binds its slot with the
  /// same widget, so the two read and behave identically.
  Widget _slot(
    BuildContext context, {
    Key? key,
    required String slotName,
    // Null for a slot that has no Studio parameter overrides of its own —
    // MemoryBook generation runs on the connection and the model alone.
    required StudioSlot? studioSlot,
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
    return ApiSlotGroup(
      key: key ?? ValueKey('studio-slot-$slotName'),
      header: title,
      description: description,
      apiConfigId: apiConfigId,
      onApiConfigChanged: onApiConfigChanged,
      modelRows: [
        ApiSlotModelRow(value: model, onChanged: onModelChanged),
        if (extraLabel != null && onExtraChanged != null)
          ApiSlotModelRow(
            cacheTag: 'audit_model',
            label: extraLabel,
            description: extraDescription,
            value: extraValue ?? '',
            onChanged: onExtraChanged,
          ),
      ],
      trailingItems: [
        if (studioSlot != null)
          MenuItem(
            icon: Icons.tune,
            label: 'studio_slot_parameters'.tr(),
            subtitle: 'studio_slot_parameters_desc'.tr(),
            trailing: Icon(
              Icons.chevron_right,
              size: 22,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            onTap: () => _openSlotSettings(studioSlot, apiConfigId),
          ),
      ],
    );
  }

  // ── Advanced slot settings ─────────────────────────────────────────────────

  Future<void> _openSlotSettings(StudioSlot slot, String apiConfigId) async {
    final pipeline = ref.read(pipelineSettingsProvider);
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    // A slot left on "use the chat connection" reads its inherited parameter
    // values off the active LLM preset; one pointing at a deleted config shows
    // none rather than the active preset's.
    final presetConfig = apiConfigId.isEmpty
        ? ref.read(activeApiConfigProvider)
        : configs.where((c) => c.id == apiConfigId).firstOrNull;
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
