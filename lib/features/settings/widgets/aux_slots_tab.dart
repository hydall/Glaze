import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/translation_settings.dart';
import '../../../core/services/memory_prompt_presets.dart';
import '../../../core/services/translation_prompt_presets.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/translation_prompt_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../catalog/widgets/lorebook_build_settings.dart';
import '../../chat/widgets/custom_prompt_manager_sheet.dart';
import '../../translation/translation_languages.dart';
import '../../translation/translation_providers.dart';
import 'api_slot_group.dart';

/// The "Agents" tab of the API settings sheet: which connection and which
/// model each auxiliary call runs on — memory, translation and the catalog's
/// lorebook builds.
///
/// Everything is optional — an empty slot falls back to the connection
/// selected in the LLM tab, which is the behaviour an untouched install already
/// has.
class AuxSlotsTab extends ConsumerStatefulWidget {
  final ScrollController controller;

  /// Scroll target for a deep link that opens the API screen *on* the
  /// MemoryBook slot — the memory settings sheet links here. Owned by the
  /// hosting screen, which is what runs the scroll, and passed in rather than
  /// held here so two mounted screens cannot collide on one [GlobalKey].
  final Key? memoryBookSlotKey;

  const AuxSlotsTab({
    super.key,
    required this.controller,
    this.memoryBookSlotKey,
  });

  @override
  ConsumerState<AuxSlotsTab> createState() => _AuxSlotsTabState();
}

class _AuxSlotsTabState extends ConsumerState<AuxSlotsTab> {
  @override
  Widget build(BuildContext context) {
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
        // Memory draft generation is an auxiliary LLM call, so it is bound
        // here — and chat summarization runs on this same slot, which is why
        // it is named for memory as a whole rather than for Memory Books. The
        // memory sheet's own API block edits it through the same widget; it
        // buffers the edit until Save, where this tab writes through on change.
        ApiSlotGroup(
          key:
              widget.memoryBookSlotKey ??
              const ValueKey('studio-slot-memory_book'),
          header: 'memory_slot_title'.tr(),
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
          modelRows: [
            ApiSlotModelRow(
              value: pipeline.memoryBookApi.generationModel,
              onChanged: (value) => _saveMemoryBookApi(
                (api) => api.copyWith(generationModel: value),
              ),
            ),
          ],
        ),
        // The shared connection agents set to "helper connection" run on.
        ApiSlotGroup(
          key: const ValueKey('agents-helper-slot'),
          header: 'agents_helper_title'.tr(),
          description: 'agents_helper_desc'.tr(),
          apiConfigId: pipeline.agents.helperApiConfigId,
          onApiConfigChanged: (id) => _savePipeline(
            (p) => p.copyWith(
              agents: p.agents.copyWith(helperApiConfigId: id, helperModel: ''),
            ),
          ),
          modelRows: [
            ApiSlotModelRow(
              value: pipeline.agents.helperModel,
              onChanged: (value) => _savePipeline(
                (p) =>
                    p.copyWith(agents: p.agents.copyWith(helperModel: value)),
              ),
            ),
          ],
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

  Future<void> _saveTranslation(
    TranslationSettings Function(TranslationSettings) mutate,
  ) => _savePipeline((p) => p.copyWith(translation: mutate(p.translation)));

  Future<void> _saveMemoryBookApi(
    MemoryBookApiSettings Function(MemoryBookApiSettings) mutate,
  ) => _savePipeline((p) => p.copyWith(memoryBookApi: mutate(p.memoryBookApi)));

  Future<void> _savePipeline(
    PipelineSettings Function(PipelineSettings) mutate,
  ) {
    final pipeline = ref.read(pipelineSettingsProvider);
    return ref.read(pipelineSettingsProvider.notifier).save(mutate(pipeline));
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
