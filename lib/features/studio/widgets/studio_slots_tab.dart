import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/card_rewriter_settings.dart';
import '../../../core/models/cleaner_settings.dart';
import '../../../core/models/ledger_settings.dart';
import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_pipeline_overrides.dart';
import '../../../core/models/translation_settings.dart';
import '../../../core/services/memory_prompt_presets.dart';
import '../../../core/services/translation_prompt_presets.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/translation_prompt_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../catalog/widgets/lorebook_build_settings.dart';
import '../../chat/widgets/custom_prompt_manager_sheet.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/widgets/api_slot_group.dart';
import '../../translation/translation_languages.dart';
import '../../translation/translation_providers.dart';
import '../../../shared/widgets/list_controls.dart';
import '../studio_availability.dart';
import '../studio_injection_points.dart';
import 'studio_slot_settings_dialog.dart';
import '../../../shared/widgets/glaze_sheet.dart';

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
///
/// Three of the stages — Post Clean, Studio Ledger and Card Rewriter — are
/// configured **per preset**, so their rows read and write the active preset's
/// own settings (`applyStudioPresetOverrides`) rather than the globals. The
/// pre-generation, final and MemoryBook slots remain global.
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
    // Post Clean, Ledger and Card Rewriter are configured per preset, so the
    // rows below show what the *active* preset runs on: its own settings where
    // it has them, the globals where it does not. The pre-generation and final
    // slots are still global and read straight off `pipeline`.
    final pipeline = applyStudioPresetOverrides(
      ref.watch(pipelineSettingsProvider),
      profile,
    );

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
        // The Studio stages leave with Studio itself; MemoryBook below is not
        // a Studio agent and stays.
        if (studioAvailable) ..._studioSlots(context, profile, pipeline),
        // Memory draft generation is an auxiliary LLM call like the ones
        // above, so it is bound here alongside them — and chat summarization
        // runs on this same slot, which is why it is named for memory as a
        // whole rather than for Memory Books. The memory sheet's own API block
        // edits it through the same widget; it buffers the edit until Save,
        // where this tab writes through on change.
        _slot(
          context,
          key: widget.memoryBookSlotKey,
          slotName: 'memory_book',
          studioSlot: null,
          title: 'memory_slot_title'.tr(),
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
          onModelChanged: (value) =>
              _saveMemoryBookApi((api) => api.copyWith(generationModel: value)),
        ),
        _TranslationSlotPanel(
          settings: pipeline.translation,
          onChanged: _saveTranslation,
        ),
        // The catalog's lorebook builds (closed JanitorAI lorebooks, scripted
        // ones) are an auxiliary call too. The capture sheet's settings and the
        // content providers screen show this same group.
        const LorebookBuildLlmGroup(key: ValueKey('studio-slot-lorebook')),
      ],
    );
  }

  List<Widget> _studioSlots(
    BuildContext context,
    StudioPreset? profile,
    PipelineSettings pipeline,
  ) {
    return [
      _slot(
        context,
        slotName: 'pregen',
        studioSlot: StudioSlot.controller,
        title: studioInjectionPointLabel('pregen'),
        description: 'studio_slot_pregen_desc'.tr(),
        apiConfigId: profile?.cheapApiConfigId ?? '',
        onApiConfigChanged: (id) =>
            _saveProfile((c) => c.copyWith(cheapApiConfigId: id)),
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
        onApiConfigChanged: (id) =>
            _saveProfile((c) => c.copyWith(expensiveApiConfigId: id)),
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
        onApiConfigChanged: (id) =>
            _saveProfile((c) => c.copyWith(cleanerApiConfigId: id)),
        model: pipeline.cleaner.postCleanerModel,
        onModelChanged: (value) =>
            _saveCleaner(pipeline, (c) => c.copyWith(postCleanerModel: value)),
        // The Fact Checker pass runs before the rewrite and can use a cheaper
        // model. It inherits the cleaner's connection — only the model differs.
        extraLabel: 'studio_slot_audit_model'.tr(),
        extraDescription: 'studio_slot_audit_model_desc'.tr(),
        extraValue: pipeline.cleaner.postCleanerAuditModel,
        onExtraChanged: (value) => _saveCleaner(
          pipeline,
          (c) => c.copyWith(postCleanerAuditModel: value),
        ),
      ),
      _slot(
        context,
        slotName: 'ledger',
        studioSlot: StudioSlot.ledger,
        title: studioInjectionPointLabel('ledger'),
        description: 'studio_slot_ledger_desc'.tr(),
        apiConfigId: profile?.ledgerApiConfigId ?? '',
        onApiConfigChanged: (id) =>
            _saveProfile((c) => c.copyWith(ledgerApiConfigId: id)),
        model: pipeline.ledger.studioLedgerModel,
        onModelChanged: (value) =>
            _saveLedger(pipeline, (l) => l.copyWith(studioLedgerModel: value)),
      ),
      // Card Rewriter runs after the Ledger's reconciliation, on the evidence
      // that reconciliation commits, so it is bound here in that order. Its
      // connection lives inside the lane's own settings object rather than in
      // a preset column of its own — it was per-preset from the start.
      _slot(
        context,
        slotName: 'card_rewriter',
        studioSlot: null,
        title: 'card_rewriter_studio_title'.tr(),
        description: 'studio_slot_card_rewriter_desc'.tr(),
        apiConfigId: pipeline.cardRewriter.apiConfigId,
        onApiConfigChanged: (id) => _saveCardRewriter(
          pipeline,
          // A model picked against the previous connection would not resolve
          // on the new one, so the override is cleared with the change.
          (c) => c.copyWith(apiConfigId: id, modelOverride: ''),
        ),
        model: pipeline.cardRewriter.modelOverride,
        onModelChanged: (value) => _saveCardRewriter(
          pipeline,
          (c) => c.copyWith(modelOverride: value),
        ),
      ),
    ];
  }

  Future<void> _saveTranslation(
    TranslationSettings Function(TranslationSettings) mutate,
  ) => _savePipeline((p) => p.copyWith(translation: mutate(p.translation)));

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

  /// The pre-generation and final slots are still global app settings.
  Future<void> _savePipeline(
    PipelineSettings Function(PipelineSettings) mutate,
  ) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref.read(pipelineSettingsProvider.notifier).save(mutate(pipeline));
  }

  /// Writes the active preset's runtime settings.
  Future<void> _savePresetRuntime(
    StudioRuntimeSettings Function(StudioRuntimeSettings) mutate,
  ) => _saveProfile(
    (preset) => preset.copyWith(runtime: mutate(preset.runtime)),
  );

  /// The three lane writers all take the `effective` settings the rows are
  /// showing — the preset's own where it has them, the globals where it does
  /// not — so the first edit of a lane stores the values the user was already
  /// looking at instead of resetting the untouched ones to their defaults.
  Future<void> _saveCleaner(
    PipelineSettings effective,
    CleanerSettings Function(CleanerSettings) mutate,
  ) =>
      _savePresetRuntime((r) => r.copyWith(cleaner: mutate(effective.cleaner)));

  Future<void> _saveLedger(
    PipelineSettings effective,
    LedgerSettings Function(LedgerSettings) mutate,
  ) => _savePresetRuntime((r) => r.copyWith(ledger: mutate(effective.ledger)));

  Future<void> _saveCardRewriter(
    PipelineSettings effective,
    CardRewriterSettings Function(CardRewriterSettings) mutate,
  ) => _savePresetRuntime(
    (r) => r.copyWith(cardRewriter: mutate(effective.cardRewriter)),
  );

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
    // The dialog reads and writes a whole PipelineSettings, so it is handed the
    // effective one. Where the result goes depends on the slot: the two
    // per-preset lanes are written back onto the preset, the rest stay global.
    final pipeline = applyStudioPresetOverrides(
      ref.read(pipelineSettingsProvider),
      ref.read(studioPresetProvider).value,
    );
    final configs = ref.read(apiListProvider).value ?? const <ApiConfig>[];
    // A slot left on "use the chat connection" reads its inherited parameter
    // values off the active LLM preset; one pointing at a deleted config shows
    // none rather than the active preset's.
    final presetConfig = apiConfigId.isEmpty
        ? ref.read(activeApiConfigProvider)
        : configs.where((c) => c.id == apiConfigId).firstOrNull;
    final updated = await showGlazeSheet<StudioSlotSettings>(
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
    final applied = updated.applyTo(pipeline, slot);
    switch (slot) {
      case StudioSlot.cleaner:
        await _savePresetRuntime((r) => r.copyWith(cleaner: applied.cleaner));
      case StudioSlot.ledger:
        await _savePresetRuntime((r) => r.copyWith(ledger: applied.ledger));
      case StudioSlot.controller:
      case StudioSlot.finalGenerator:
        await _savePipeline((p) => updated.applyTo(p, slot));
    }
  }
}

/// The translation slot: one engine (the LLM or a machine-translation
/// service), the languages it targets, and the two automatic toggles.
///
/// Stateful because the machine-translation key, its endpoint and the prompt
/// are plain text rows that write through as the reader types. The header and
/// the enable switch stay put; everything below them folds away while the
/// feature is off.
class _TranslationSlotPanel extends ConsumerStatefulWidget {
  final TranslationSettings settings;
  final void Function(TranslationSettings Function(TranslationSettings))
  onChanged;

  const _TranslationSlotPanel({
    required this.settings,
    required this.onChanged,
  });

  @override
  ConsumerState<_TranslationSlotPanel> createState() =>
      _TranslationSlotPanelState();
}

class _TranslationSlotPanelState extends ConsumerState<_TranslationSlotPanel> {
  late final TextEditingController _apiKey;
  late final TextEditingController _endpoint;
  late final TextEditingController _folderId;
  late final TextEditingController _prompt;

  /// The settings the controllers were last written from, so an external
  /// change can be told from the reader's own typing.
  late TranslationSettings _last;

  TranslationSettings get _s => widget.settings;

  @override
  void initState() {
    super.initState();
    _apiKey = TextEditingController(text: _s.translatorApiKey);
    _endpoint = TextEditingController(text: _s.translatorEndpoint);
    _folderId = TextEditingController(text: _s.translatorFolderId);
    _prompt = TextEditingController(text: _s.prompt);
    _last = _s;
  }

  @override
  void didUpdateWidget(covariant _TranslationSlotPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(_apiKey, _s.translatorApiKey, _last.translatorApiKey);
    _sync(_endpoint, _s.translatorEndpoint, _last.translatorEndpoint);
    _sync(_folderId, _s.translatorFolderId, _last.translatorFolderId);
    _sync(_prompt, _s.prompt, _last.prompt);
    _last = _s;
  }

  /// Adopts an externally changed value, but never fights the reader mid-edit:
  /// a controller that already holds the new value is left alone.
  static void _sync(
    TextEditingController controller,
    String next,
    String previous,
  ) {
    if (next != previous && next != controller.text) controller.text = next;
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _endpoint.dispose();
    _folderId.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _emit(TranslationSettings Function(TranslationSettings) mutate) =>
      widget.onChanged(mutate);

  @override
  Widget build(BuildContext context) {
    final provider = TranslationProvider.fromId(_s.provider);
    final enabled = _s.enabled;
    final isLlm = provider == TranslationProvider.llm;
    final custom =
        ref.watch(translationCustomPromptsProvider).value ?? const [];

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: ApiSlotGroup(
        key: const ValueKey('studio-slot-translation'),
        header: 'translation_slot_title'.tr(),
        description: 'translation_slot_desc'.tr(),
        leadingItems: [
          MenuSwitchItem(
            label: 'translation_enable'.tr(),
            description: 'translation_enable_desc'.tr(),
            value: enabled,
            onChanged: (value) => _emit((t) => t.copyWith(enabled: value)),
          ),
          if (enabled)
            MenuSelectorItem(
              label: 'translation_provider'.tr(),
              description: 'translation_provider_desc'.tr(),
              currentValue: provider.labelKey.tr(),
              onTap: () => _pickProvider(provider),
            ),
        ],
        // The connection and model rows belong to the LLM engine alone; a
        // machine service is configured by its own key and endpoint below.
        showSlotRows: enabled && isLlm,
        apiConfigId: _s.apiConfigId,
        onApiConfigChanged: (id) => _emit(
          // A model picked against the previous connection would not resolve
          // on the new one.
          (t) => t.copyWith(apiConfigId: id, model: ''),
        ),
        modelRows: [
          ApiSlotModelRow(
            value: _s.model,
            onChanged: (value) => _emit((t) => t.copyWith(model: value)),
          ),
        ],
        trailingItems: enabled
            ? [
                if (isLlm) ..._llmItems(custom) else ..._machineItems(provider),
                MenuSelectorItem(
                  label: 'translation_message_language'.tr(),
                  description: 'translation_message_language_desc'.tr(),
                  currentValue: _s.messageLanguage.isEmpty
                      ? 'translation_language_interface'.tr()
                      : resolveTranslationLanguage(
                          _s.messageLanguage,
                        ).nativeName,
                  onTap: () => _pickLanguage(
                    title: 'translation_message_language'.tr(),
                    current: _s.messageLanguage,
                    allowInterface: true,
                    onSelect: (code) =>
                        _emit((t) => t.copyWith(messageLanguage: code)),
                  ),
                ),
                MenuSelectorItem(
                  label: 'translation_input_language'.tr(),
                  description: 'translation_input_language_desc'.tr(),
                  currentValue: resolveTranslationLanguage(
                    _s.inputLanguage,
                  ).nativeName,
                  onTap: () => _pickLanguage(
                    title: 'translation_input_language'.tr(),
                    current: _s.inputLanguage,
                    allowInterface: false,
                    onSelect: (code) =>
                        _emit((t) => t.copyWith(inputLanguage: code)),
                  ),
                ),
                MenuSwitchItem(
                  label: 'translation_auto_user'.tr(),
                  description: 'translation_auto_user_desc'.tr(),
                  value: _s.autoTranslateUser,
                  onChanged: (value) =>
                      _emit((t) => t.copyWith(autoTranslateUser: value)),
                ),
                MenuSwitchItem(
                  label: 'translation_auto_character'.tr(),
                  description: 'translation_auto_character_desc'.tr(),
                  value: _s.autoTranslateCharacter,
                  onChanged: (value) =>
                      _emit((t) => t.copyWith(autoTranslateCharacter: value)),
                ),
              ]
            : const [],
      ),
    );
  }

  List<Widget> _llmItems(List<MemoryPromptPreset> custom) {
    final preset = TranslationPromptPresets.match(_s.prompt, custom);
    return [
      MenuSelectorItem(
        label: 'translation_prompt_preset'.tr(),
        description: 'translation_prompt_preset_desc'.tr(),
        currentValue: preset?.label ?? 'summary_prompt_preset_custom'.tr(),
        onTap: () => showPromptPresetPicker(
          context,
          title: 'translation_prompt_preset'.tr(),
          builtIn: TranslationPromptPresets.builtIn,
          custom: custom,
          activeKey: preset?.key,
          onPick: (picked) {
            _prompt.text = picked.prompt;
            _emit((t) => t.copyWith(prompt: picked.prompt));
          },
        ),
      ),
      MenuItem(
        icon: Icons.edit_note_rounded,
        label: 'translation_prompt_manage'.tr(),
        subtitle: 'translation_prompt_manage_desc'.tr(),
        onTap: _managePrompts,
      ),
      MenuFieldItem(
        label: 'translation_prompt'.tr(),
        description: 'translation_prompt_desc'.tr(),
        controller: _prompt,
        placeholder: TranslationPromptPresets.builtIn.first.prompt,
        maxLines: 6,
        keyboardType: TextInputType.multiline,
        onChanged: (value) => _emit((t) => t.copyWith(prompt: value)),
        onReset: _s.prompt.trim().isEmpty
            ? null
            : () {
                _prompt.text = '';
                _emit((t) => t.copyWith(prompt: ''));
              },
      ),
    ];
  }

  List<Widget> _machineItems(TranslationProvider provider) {
    return [
      MenuFieldItem(
        label: 'translation_translator_key'.tr(),
        description: 'translation_translator_key_desc'.tr(),
        controller: _apiKey,
        obscure: true,
        placeholder: 'translation_translator_key_hint'.tr(),
        onChanged: (value) => _emit((t) => t.copyWith(translatorApiKey: value)),
      ),
      MenuFieldItem(
        label: 'translation_translator_endpoint'.tr(),
        description: 'translation_translator_endpoint_desc'.tr(),
        controller: _endpoint,
        placeholder: provider.defaultEndpoint.isEmpty
            ? 'translation_translator_endpoint_hint'.tr()
            : provider.defaultEndpoint,
        maxLines: 1,
        onChanged: (value) =>
            _emit((t) => t.copyWith(translatorEndpoint: value)),
      ),
      if (provider.needsFolderId)
        MenuFieldItem(
          label: 'translation_translator_folder'.tr(),
          description: 'translation_translator_folder_desc'.tr(),
          controller: _folderId,
          onChanged: (value) =>
              _emit((t) => t.copyWith(translatorFolderId: value)),
        ),
    ];
  }

  Future<void> _pickProvider(TranslationProvider current) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'translation_provider'.tr(),
      items: [
        for (final provider in TranslationProvider.values)
          BottomSheetItem(
            label: provider.labelKey.tr(),
            icon: provider == current
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            iconColor: provider == current
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _emit((t) => t.copyWith(provider: provider.id));
            },
          ),
      ],
    );
  }

  Future<void> _managePrompts() async {
    final custom =
        ref.read(translationCustomPromptsProvider).value ??
        const <MemoryPromptPreset>[];
    final result = await GlazeBottomSheet.show<List<MemoryPromptPreset>>(
      context,
      title: 'translation_prompt_manage'.tr(),
      child: CustomPromptManagerSheet(
        customPrompts: custom,
        builtIn: TranslationPromptPresets.builtIn,
        title: 'translation_prompt_preset'.tr(),
      ),
    );
    if (!mounted || result == null) return;
    await ref.read(translationCustomPromptsProvider.notifier).save(result);
  }

  void _pickLanguage({
    required String title,
    required String current,
    required bool allowInterface,
    required ValueChanged<String> onSelect,
  }) {
    showGlazePickerSheet(
      context,
      title: title,
      items: [
        if (allowInterface)
          GlazePickerItem(
            label: 'translation_language_interface'.tr(),
            isActive: current.isEmpty,
            value: '',
          ),
        for (final language in kTranslationLanguages)
          GlazePickerItem(
            label: language.nativeName,
            isActive: language.code == current,
            value: language.code,
          ),
      ],
      onSelect: (value) => onSelect(value as String),
    );
  }
}
