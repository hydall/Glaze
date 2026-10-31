import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/preset.dart';
import '../../../core/services/memory_prompt_presets.dart'
    show MemoryPromptPreset;
import '../../../core/services/summary_preamble.dart';
import '../../../core/services/summary_prompt_presets.dart';
import '../../../core/state/preset_resolution.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../presets/preset_list_provider.dart';
import '../../settings/api_settings_screen.dart';
import 'custom_prompt_manager_sheet.dart';
import '../../../shared/widgets/glaze_sheet.dart';

/// Everything about the summary except the summary itself.
///
/// The Summary tab used to be one long form: the text, the master switch (in
/// the sheet header, as a bare `Switch`), the prompt template, the auto
/// compaction and the injection point, all in one scroll. Only the first of
/// those is read or edited day to day. They live behind the header's settings
/// button now, the way the Memory Books tab's do, so the tab itself is the
/// summary and the one button that rewrites it.
///
/// Values are buffered and written on Save — same contract as
/// `MemoryGenerationSettingsSheet`.
class SummarySettingsSheet extends ConsumerStatefulWidget {
  final String charId;
  final String sessionId;

  const SummarySettingsSheet({
    super.key,
    required this.charId,
    required this.sessionId,
  });

  static Future<void> show(
    BuildContext context, {
    required String charId,
    required String sessionId,
  }) {
    return showGlazeSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          SummarySettingsSheet(charId: charId, sessionId: sessionId),
    );
  }

  @override
  ConsumerState<SummarySettingsSheet> createState() =>
      _SummarySettingsSheetState();
}

class _SummarySettingsSheetState extends ConsumerState<SummarySettingsSheet> {
  final ScrollController _scrollController = ScrollController();

  bool _loading = true;
  bool _enabled = true;
  SummaryCompactionSettings _compaction = const SummaryCompactionSettings();

  /// Saved prompts, buffered like the rest of the form so the manager sheet
  /// and the picker agree before anything is written.
  List<MemoryPromptPreset> _customPrompts = const [];
  List<MemoryPromptPreset> _customMergePrompts = const [];
  List<MemoryPromptPreset> _customShortenPrompts = const [];

  SummaryPromptSelection _selection = const SummaryPromptSelection();

  /// The instruction put first in every prompt, for a model that refuses.
  /// Its switch; the text is in [_preambleText].
  bool _preambleOn = false;
  final TextEditingController _preambleText = TextEditingController();

  /// The manual tail in tokens, typed; [_compaction] follows every valid edit.
  final TextEditingController _tailTokens = TextEditingController();

  /// The chat's own retelling text, kept from before prompts were chosen by
  /// key. It wins over [_selection] until a preset is picked, which clears it.
  String? _ownPrompt;

  /// Null until the effective preset is resolved, or when it carries no
  /// `summary` block — the injection section stays hidden in both cases.
  String? _presetId;
  String _role = 'system';
  String _insertionMode = 'relative';
  int _depth = 1;

  /// The saved prompts as they were loaded, by identity: the manager sheet
  /// hands back a new list only when something changed.
  List<MemoryPromptPreset> _loadedPrompts = const [];
  List<MemoryPromptPreset> _loadedMergePrompts = const [];
  List<MemoryPromptPreset> _loadedShortenPrompts = const [];

  /// What was loaded, so Save writes only what actually changed. Writing the
  /// prompt unconditionally would be harmless; writing the compaction
  /// settings or the preset back is not — both are global state other chats
  /// read.
  late _SummarySettings _loaded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _preambleText.dispose();
    _tailTokens.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = ref.read(summaryServiceProvider);
    final enabled = await service.isSummaryEnabled(widget.sessionId);
    final prompt = await service.getSummaryPrompt(widget.sessionId);
    final compaction = await ref.read(summaryCompactionSettingsProvider.future);
    final customPrompts = await ref.read(summaryCustomPromptsProvider.future);
    final customMergePrompts = await ref.read(
      summaryCustomMergePromptsProvider.future,
    );
    final customShortenPrompts = await ref.read(
      summaryCustomShortenPromptsProvider.future,
    );
    final selection = await ref.read(summaryPromptSelectionProvider.future);
    final preamble = await ref.read(summaryPreambleProvider.future);
    // The preset list loads lazily; effectivePresetForChatProvider reads null
    // until it resolves, which would leave the injection section hidden.
    await ref.read(presetListProvider.future);
    if (!mounted) return;
    final preset = ref.read(
      effectivePresetForChatProvider((
        charId: widget.charId,
        sessionId: widget.sessionId,
      )),
    );
    final block = preset?.blocks.where((b) => b.id == 'summary').firstOrNull;

    setState(() {
      _enabled = enabled;
      _compaction = compaction;
      _tailTokens.text = '${compaction.manualTailTokens}';
      _ownPrompt = prompt;
      _selection = selection;
      _preambleOn = preamble.enabled;
      _preambleText.text = preamble.text;
      _customPrompts = customPrompts;
      _customMergePrompts = customMergePrompts;
      _loadedMergePrompts = customMergePrompts;
      _customShortenPrompts = customShortenPrompts;
      _loadedShortenPrompts = customShortenPrompts;
      _presetId = block == null ? null : preset?.id;
      _role = block?.role ?? _role;
      _insertionMode = block?.insertionMode ?? _insertionMode;
      _depth = block?.depth ?? _depth;
      _loadedPrompts = customPrompts;
      _loaded = _current();
      _loading = false;
    });
  }

  _SummarySettings _current() => _SummarySettings(
    enabled: _enabled,
    compaction: _compaction,
    ownPrompt: _ownPrompt,
    selection: _selection,
    preamble: _preamble,
    role: _role,
    insertionMode: _insertionMode,
    depth: _depth,
  );

  /// Writes what changed, then closes. The writes come first on purpose: they
  /// go through `ref`, and a `ref` whose widget has been popped throws.
  Future<void> _save() async {
    final current = _current();
    final loaded = _loaded;

    if (current.enabled != loaded.enabled) {
      // Writes through `syncSummaryEnabled`, which also flips the `summary`
      // block in every preset — otherwise the active preset silently overrides
      // the switch.
      await syncSummaryEnabled(
        ref,
        charId: widget.charId,
        enabled: current.enabled,
      );
    }
    if (current.ownPrompt != loaded.ownPrompt) {
      await ref
          .read(summaryServiceProvider)
          .setSummaryPrompt(
            sessionId: widget.sessionId,
            prompt: current.ownPrompt,
          );
      ref.read(summaryRevisionProvider.notifier).state++;
    }
    if (current.selection != loaded.selection) {
      await ref
          .read(summaryPromptSelectionProvider.notifier)
          .save(current.selection);
    }
    if (current.compaction != loaded.compaction) {
      await ref
          .read(summaryCompactionSettingsProvider.notifier)
          .save(current.compaction);
    }
    if (current.preamble != loaded.preamble) {
      await ref.read(summaryPreambleProvider.notifier).save(current.preamble);
    }
    if (!identical(_customPrompts, _loadedPrompts)) {
      await ref
          .read(summaryCustomPromptsProvider.notifier)
          .save(_customPrompts);
    }
    if (!identical(_customMergePrompts, _loadedMergePrompts)) {
      await ref
          .read(summaryCustomMergePromptsProvider.notifier)
          .save(_customMergePrompts);
    }
    if (!identical(_customShortenPrompts, _loadedShortenPrompts)) {
      await ref
          .read(summaryCustomShortenPromptsProvider.notifier)
          .save(_customShortenPrompts);
    }
    await _saveBlockSettings(current, loaded);
    if (!mounted) return;
    Navigator.pop(context);
  }

  /// Writes role / insertion mode / depth back onto the effective preset's
  /// `summary` block — settings that were otherwise reachable only from the
  /// preset editor.
  Future<void> _saveBlockSettings(
    _SummarySettings current,
    _SummarySettings loaded,
  ) async {
    final presetId = _presetId;
    if (presetId == null) return;
    if (current.role == loaded.role &&
        current.insertionMode == loaded.insertionMode &&
        current.depth == loaded.depth) {
      return;
    }
    final presets = ref.read(presetListProvider).value ?? const <Preset>[];
    final preset = presets.where((p) => p.id == presetId).firstOrNull;
    if (preset == null) return;
    final index = preset.blocks.indexWhere((b) => b.id == 'summary');
    if (index == -1) return;

    final updated = preset.blocks[index].copyWith(
      role: current.role,
      insertionMode: current.insertionMode,
      depth: current.insertionMode == 'depth'
          ? current.depth
          : preset.blocks[index].depth,
    );
    if (updated == preset.blocks[index]) return;
    final blocks = List<PresetBlock>.from(preset.blocks)..[index] = updated;
    await ref
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(blocks: blocks));
  }

  static String _tailUnitLabel(SummaryManualTailUnit unit) => switch (unit) {
    SummaryManualTailUnit.percent => 'summary_manual_tail_unit_percent'.tr(),
    SummaryManualTailUnit.tokens => 'summary_manual_tail_unit_tokens'.tr(),
  };

  void _pickTailUnit() {
    showGlazePickerSheet(
      context,
      title: 'summary_manual_tail_label'.tr(),
      items: [
        for (final unit in SummaryManualTailUnit.values)
          GlazePickerItem(
            label: _tailUnitLabel(unit),
            isActive: unit == _compaction.manualTailUnit,
            value: unit,
          ),
      ],
      onSelect: (value) => setState(
        () => _compaction = _compaction.copyWith(
          manualTailUnit: value as SummaryManualTailUnit,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SheetView(
      title: 'summary_settings_title'.tr(),
      showBack: true,
      scrollController: _scrollController,
      actions: [
        if (!_loading)
          SheetViewAction(
            icon: const Icon(Icons.check_rounded),
            tooltip: 'btn_save'.tr(),
            onPressed: _save,
          ),
      ],
      // Builder, not this build's `context`: SheetView reports its measured
      // header height as MediaQuery padding to its body subtree only.
      body: _loading
          ? const Center(child: GlazeSpinner())
          : Builder(
              builder: (bodyContext) => ListView(
                controller: _scrollController,
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(bodyContext).top + 12,
                  bottom: MediaQuery.paddingOf(bodyContext).bottom + 24,
                ),
                children: [
                  MenuGroup(
                    items: [
                      MenuSwitchItem(
                        label: 'label_enabled'.tr(),
                        description: 'summary_enabled_hint'.tr(),
                        value: _enabled,
                        onChanged: (v) => setState(() => _enabled = v),
                      ),
                    ],
                  ),
                  MenuGroup(
                    header: 'summary_generation_section'.tr(),
                    items: [
                      MenuSwitchItem(
                        label: 'summary_auto_label'.tr(),
                        description: 'summary_auto_hint'.tr(),
                        value: _compaction.autoEnabled,
                        onChanged: (v) => setState(
                          () => _compaction = _compaction.copyWith(
                            autoEnabled: v,
                          ),
                        ),
                      ),
                      MenuRangeItem(
                        label: 'summary_trigger_label'.tr(),
                        unit: '%',
                        description: 'summary_trigger_hint'.tr(),
                        value: _compaction.triggerPercent.toDouble(),
                        min: SummaryCompactionSettings.minTriggerPercent
                            .toDouble(),
                        max: SummaryCompactionSettings.maxTriggerPercent
                            .toDouble(),
                        divisions:
                            SummaryCompactionSettings.maxTriggerPercent -
                            SummaryCompactionSettings.minTriggerPercent,
                        decimalPlaces: 0,
                        editableValue: true,
                        onChanged: (v) => setState(
                          () => _compaction = _compaction.copyWith(
                            triggerPercent: v.round(),
                            // The line a run compacts to never sits above
                            // the trigger.
                            compactToPercent: math.min(
                              _compaction.compactToPercent,
                              v.round(),
                            ),
                          ),
                        ),
                      ),
                      MenuRangeItem(
                        label: 'summary_compact_to_label'.tr(),
                        unit: '%',
                        description: 'summary_compact_to_hint'.tr(),
                        value: _compaction.compactToPercent.toDouble(),
                        min: SummaryCompactionSettings.minCompactToPercent
                            .toDouble(),
                        max: _compaction.triggerPercent.toDouble(),
                        divisions:
                            _compaction.triggerPercent -
                            SummaryCompactionSettings.minCompactToPercent,
                        decimalPlaces: 0,
                        editableValue: true,
                        onChanged: (v) => setState(
                          () => _compaction = _compaction.copyWith(
                            compactToPercent: v.round().clamp(
                              SummaryCompactionSettings.minCompactToPercent,
                              _compaction.triggerPercent,
                            ),
                          ),
                        ),
                      ),
                      MenuSelectorItem(
                        label: 'summary_manual_tail_label'.tr(),
                        description: 'summary_manual_tail_hint'.tr(),
                        currentValue: _tailUnitLabel(
                          _compaction.manualTailUnit,
                        ),
                        onTap: _pickTailUnit,
                      ),
                      if (_compaction.manualTailUnit ==
                          SummaryManualTailUnit.percent)
                        MenuRangeItem(
                          label: 'summary_manual_tail_percent_label'.tr(),
                          unit: '%',
                          description: 'summary_manual_tail_percent_hint'.tr(),
                          value: _compaction.manualTailPercent.toDouble(),
                          min: SummaryCompactionSettings.minManualTailPercent
                              .toDouble(),
                          max: SummaryCompactionSettings.maxManualTailPercent
                              .toDouble(),
                          divisions:
                              SummaryCompactionSettings.maxManualTailPercent -
                              SummaryCompactionSettings.minManualTailPercent,
                          decimalPlaces: 0,
                          editableValue: true,
                          onChanged: (v) => setState(
                            () => _compaction = _compaction.copyWith(
                              manualTailPercent: v.round(),
                            ),
                          ),
                        )
                      else
                        MenuFieldItem(
                          label: 'summary_manual_tail_tokens_label'.tr(),
                          description: 'summary_manual_tail_tokens_hint'.tr(),
                          controller: _tailTokens,
                          placeholder:
                              '${const SummaryCompactionSettings().manualTailTokens}',
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          // An empty or zero field keeps the last number.
                          onChanged: (text) {
                            final v = int.tryParse(text) ?? 0;
                            if (v < 1) return;
                            setState(
                              () => _compaction = _compaction.copyWith(
                                manualTailTokens: v,
                              ),
                            );
                          },
                        ),
                      MenuRangeItem(
                        label: 'summary_block_target_label'.tr(),
                        description: 'summary_block_target_hint'.tr(),
                        value: _compaction.blockTargetTokens.toDouble(),
                        min: SummaryCompactionSettings.minBlockTargetTokens
                            .toDouble(),
                        max: SummaryCompactionSettings.maxBlockTargetTokens
                            .toDouble(),
                        divisions: 38,
                        decimalPlaces: 0,
                        editableValue: true,
                        onChanged: (v) => setState(
                          () => _compaction = _compaction.copyWith(
                            blockTargetTokens: v.round(),
                          ),
                        ),
                      ),
                      MenuRangeItem(
                        label: 'summary_merge_label'.tr(),
                        unit: '%',
                        description: 'summary_merge_hint'.tr(),
                        value: _compaction.mergePercent.toDouble(),
                        min: SummaryCompactionSettings.minMergePercent
                            .toDouble(),
                        max: SummaryCompactionSettings.maxMergePercent
                            .toDouble(),
                        divisions:
                            SummaryCompactionSettings.maxMergePercent -
                            SummaryCompactionSettings.minMergePercent,
                        decimalPlaces: 0,
                        editableValue: true,
                        onChanged: (v) => setState(
                          () => _compaction = _compaction.copyWith(
                            mergePercent: v.round(),
                          ),
                        ),
                      ),
                      MenuItem(
                        icon: Icons.cable_rounded,
                        label: 'memory_books_generation_connection'.tr(),
                        subtitle: 'summary_connection_hint'.tr(),
                        onTap: _openApiSettings,
                      ),
                    ],
                  ),
                  MenuGroup(
                    header: 'summary_prompts_section'.tr(),
                    items: [
                      MenuSelectorItem(
                        key: const Key('summary_prompt_retell'),
                        label: 'summary_prompt_retell_label'.tr(),
                        currentValue: _ownPrompt != null
                            ? 'summary_prompt_chat_own'.tr()
                            : _retellPreset().label,
                        description: _ownPrompt != null
                            ? 'summary_prompt_chat_own_hint'.tr()
                            : 'summary_prompt_retell_hint'.tr(),
                        onTap: _pickRetell,
                      ),
                      MenuSelectorItem(
                        key: const Key('summary_prompt_merge'),
                        label: 'summary_prompt_merge_label'.tr(),
                        currentValue: _mergePreset().label,
                        description: 'summary_prompt_merge_hint'.tr(),
                        onTap: _pickMerge,
                      ),
                      MenuSelectorItem(
                        key: const Key('summary_prompt_shorten'),
                        label: 'summary_prompt_shorten_label'.tr(),
                        currentValue: _shortenPreset().label,
                        description: 'summary_prompt_shorten_hint'.tr(),
                        onTap: _pickShorten,
                      ),
                      MenuSwitchItem(
                        key: const Key('summary_preamble'),
                        label: 'summary_preamble_label'.tr(),
                        description: 'summary_preamble_hint'.tr(),
                        value: _preambleOn,
                        onChanged: (v) => setState(() => _preambleOn = v),
                      ),
                      if (_preambleOn)
                        MenuFieldItem(
                          fieldKey: const Key('summary_preamble_text'),
                          label: 'summary_preamble_text_label'.tr(),
                          controller: _preambleText,
                          placeholder: SummaryPreamble.defaultText,
                          keyboardType: TextInputType.multiline,
                          minLines: 3,
                          maxLines: 8,
                          // The reset button shows only while the text differs.
                          onChanged: (_) => setState(() {}),
                          onReset:
                              _preambleText.text == SummaryPreamble.defaultText
                              ? null
                              : () => setState(
                                  () => _preambleText.text =
                                      SummaryPreamble.defaultText,
                                ),
                          onExpand: _expandPreamble,
                        ),
                      MenuItem(
                        key: const Key('summary_view_current_prompts'),
                        icon: Icons.visibility_outlined,
                        label: 'summary_prompt_view_current'.tr(),
                        onTap: _viewPrompts,
                      ),
                      MenuItem(
                        key: const Key('summary_manage_prompts'),
                        icon: Icons.edit_note_rounded,
                        label: 'memory_prompt_manage'.tr(),
                        trailing: Icon(
                          Icons.chevron_right,
                          size: 22,
                          color: context.cs.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        onTap: _managePrompts,
                      ),
                    ],
                  ),
                  if (_presetId != null)
                    MenuGroup(
                      header: 'label_injection_point'.tr(),
                      items: [
                        MenuSelectorItem(
                          label: 'label_role'.tr(),
                          currentValue: _roleLabel(_role),
                          onTap: _pickRole,
                        ),
                        MenuSelectorItem(
                          key: const Key('summary_insertion'),
                          label: 'label_insertion'.tr(),
                          currentValue: _insertionLabel(_insertionMode),
                          description: 'summary_insertion_hint'.tr(),
                          onTap: _pickInsertion,
                        ),
                        if (_insertionMode == 'depth')
                          MenuRangeItem(
                            label: 'label_depth'.tr(),
                            value: _depth.toDouble(),
                            min: 1,
                            max: 20,
                            divisions: 19,
                            decimalPlaces: 0,
                            editableValue: true,
                            onChanged: (v) =>
                                setState(() => _depth = v.round()),
                          ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }

  /// The switch and the field as one setting. An emptied field falls back to
  /// the default text rather than leaving the switch on with nothing behind
  /// it.
  SummaryPreamble get _preamble => SummaryPreamble(
    enabled: _preambleOn,
    text: _preambleText.text.trim().isEmpty
        ? SummaryPreamble.defaultText
        : _preambleText.text,
  );

  Future<void> _expandPreamble() => FullscreenEditorScreen.show(
    context,
    title: 'summary_preamble_label'.tr(),
    initialValue: _preambleText.text,
    hintText: SummaryPreamble.defaultText,
    onChanged: (value) {
      if (mounted) setState(() => _preambleText.text = value);
    },
  );

  MemoryPromptPreset _retellPreset() =>
      SummaryPromptPresets.resolve(_selection.retellKey, _customPrompts);

  MemoryPromptPreset _mergePreset() => SummaryMergePromptPresets.resolve(
    _selection.mergeKey,
    _customMergePrompts,
  );

  MemoryPromptPreset _shortenPreset() => SummaryShortenPromptPresets.resolve(
    _selection.shortenKey,
    _customShortenPrompts,
  );

  /// Picking a preset also lets go of the chat's own text, if it had one.
  void _pickRetell() {
    showPromptPresetPicker(
      context,
      title: 'summary_prompt_retell_label'.tr(),
      builtIn: SummaryPromptPresets.builtIn,
      custom: _customPrompts,
      activeKey: _ownPrompt != null ? null : _retellPreset().key,
      onPick: (preset) => setState(() {
        _selection = _selection.copyWith(retellKey: preset.key);
        _ownPrompt = null;
      }),
    );
  }

  void _pickMerge() {
    showPromptPresetPicker(
      context,
      title: 'summary_prompt_merge_label'.tr(),
      builtIn: SummaryMergePromptPresets.builtIn,
      custom: _customMergePrompts,
      activeKey: _mergePreset().key,
      onPick: (preset) => setState(
        () => _selection = _selection.copyWith(mergeKey: preset.key),
      ),
    );
  }

  void _pickShorten() {
    showPromptPresetPicker(
      context,
      title: 'summary_prompt_shorten_label'.tr(),
      builtIn: SummaryShortenPromptPresets.builtIn,
      custom: _customShortenPrompts,
      activeKey: _shortenPreset().key,
      onPick: (preset) => setState(
        () => _selection = _selection.copyWith(shortenKey: preset.key),
      ),
    );
  }

  Future<void> _viewPrompts() => GlazeBottomSheet.show<void>(
    context,
    title: 'summary_prompt_view_current'.tr(),
    child: _CurrentPromptsPreview(
      sections: [
        // First, as it goes in front of each of the prompts below.
        if (_preamble.active)
          (
            title: 'summary_preamble_label'.tr(),
            label: null,
            prompt: _preamble.text,
          ),
        (
          title: 'summary_prompt_retell_label'.tr(),
          label: _ownPrompt != null
              ? 'summary_prompt_chat_own'.tr()
              : _retellPreset().label,
          prompt: _ownPrompt ?? _retellPreset().prompt,
        ),
        (
          title: 'summary_prompt_merge_label'.tr(),
          label: _mergePreset().label,
          prompt: _mergePreset().prompt,
        ),
        (
          title: 'summary_prompt_shorten_label'.tr(),
          label: _shortenPreset().label,
          prompt: _shortenPreset().prompt,
        ),
      ],
    ),
  );

  /// Three libraries, one entry point: which one to manage is asked first.
  void _managePrompts() {
    showGlazePickerSheet(
      context,
      title: 'memory_prompt_manage'.tr(),
      items: [
        GlazePickerItem(
          label: 'summary_prompt_retell_label'.tr(),
          isActive: false,
          value: 'retell',
        ),
        GlazePickerItem(
          label: 'summary_prompt_merge_label'.tr(),
          isActive: false,
          value: 'merge',
        ),
        GlazePickerItem(
          label: 'summary_prompt_shorten_label'.tr(),
          isActive: false,
          value: 'shorten',
        ),
      ],
      onSelect: (library) => switch (library) {
        'merge' => _manageMerge(),
        'shorten' => _manageShorten(),
        _ => _manageRetell(),
      },
    );
  }

  Future<void> _manageRetell() async {
    final result = await GlazeBottomSheet.show<List<MemoryPromptPreset>>(
      context,
      title: 'memory_prompt_manage'.tr(),
      child: CustomPromptManagerSheet(
        customPrompts: _customPrompts,
        builtIn: SummaryPromptPresets.builtIn,
        title: 'summary_prompt_presets_title'.tr(),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _customPrompts = result;
      // A deleted preset leaves the selection on the built-in default.
      _selection = _selection.copyWith(retellKey: _retellPreset().key);
    });
  }

  Future<void> _manageMerge() async {
    final result = await GlazeBottomSheet.show<List<MemoryPromptPreset>>(
      context,
      title: 'memory_prompt_manage'.tr(),
      child: CustomPromptManagerSheet(
        customPrompts: _customMergePrompts,
        builtIn: SummaryMergePromptPresets.builtIn,
        title: 'summary_merge_prompt_presets_title'.tr(),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _customMergePrompts = result;
      _selection = _selection.copyWith(mergeKey: _mergePreset().key);
    });
  }

  Future<void> _manageShorten() async {
    final result = await GlazeBottomSheet.show<List<MemoryPromptPreset>>(
      context,
      title: 'memory_prompt_manage'.tr(),
      child: CustomPromptManagerSheet(
        customPrompts: _customShortenPrompts,
        builtIn: SummaryShortenPromptPresets.builtIn,
        title: 'summary_shorten_prompt_presets_title'.tr(),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _customShortenPrompts = result;
      _selection = _selection.copyWith(shortenKey: _shortenPreset().key);
    });
  }

  /// Summarizing runs on the Memory slot, the same connection memory drafts
  /// use, so this leaves for where that slot is bound rather than binding a
  /// second one here.
  Future<void> _openApiSettings() => showApiSettingsSheet(
    context,
    focusSection: ApiSettingsSection.memoryBook,
  );

  static String _roleLabel(String role) => switch (role) {
    'user' => 'User',
    'assistant' => 'Assistant',
    _ => 'System',
  };

  static String _insertionLabel(String mode) => switch (mode) {
    summaryInPlaceInsertion => 'injection_in_place'.tr(),
    'depth' => 'injection_depth'.tr(),
    _ => 'injection_relative'.tr(),
  };

  void _pickRole() {
    showGlazePickerSheet(
      context,
      title: 'label_role'.tr(),
      items: [
        for (final role in const ['system', 'user', 'assistant'])
          GlazePickerItem(
            label: _roleLabel(role),
            isActive: _role == role,
            value: role,
          ),
      ],
      onSelect: (value) => setState(() => _role = value as String),
    );
  }

  void _pickInsertion() {
    showGlazePickerSheet(
      context,
      title: 'label_insertion'.tr(),
      items: [
        for (final mode in const [summaryInPlaceInsertion, 'relative', 'depth'])
          GlazePickerItem(
            label: _insertionLabel(mode),
            isActive: _insertionMode == mode,
            value: mode,
          ),
      ],
      onSelect: (value) => setState(() => _insertionMode = value as String),
    );
  }
}

/// One snapshot of the form, for telling a real edit from a reopen.
class _SummarySettings {
  final bool enabled;
  final SummaryCompactionSettings compaction;
  final String? ownPrompt;
  final SummaryPromptSelection selection;
  final SummaryPreamble preamble;
  final String role;
  final String insertionMode;
  final int depth;

  const _SummarySettings({
    required this.enabled,
    required this.compaction,
    required this.ownPrompt,
    required this.selection,
    required this.preamble,
    required this.role,
    required this.insertionMode,
    required this.depth,
  });
}

/// The prompts summarizing runs on right now, each under what it is for and,
/// when it is a chosen preset, its name.
class _CurrentPromptsPreview extends StatelessWidget {
  final List<({String title, String? label, String prompt})> sections;

  const _CurrentPromptsPreview({required this.sections});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final section in sections) ...[
                    Text(
                      switch (section.label) {
                        final label? => '${section.title} · $label',
                        null => section.title,
                      },
                      style: TextStyle(
                        color: context.cs.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      section.prompt.trim(),
                      style: TextStyle(
                        color: context.cs.onSurface,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GlazeActionButton(
                icon: Icons.close_rounded,
                label: 'btn_close'.tr(),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
