import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/summary_service.dart';
import '../../../core/models/preset.dart';
import '../../../core/state/preset_resolution.dart';
import '../../../core/state/summary_providers.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../presets/preset_list_provider.dart';

/// Everything about the summary except the summary itself.
///
/// The Summary tab used to be one long form: the text, the master switch (in
/// the sheet header, as a bare `Switch`), the prompt template, the auto
/// interval and the injection point, all in one scroll. Only the first of
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
    return showModalBottomSheet<void>(
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
  final TextEditingController _promptCtrl = TextEditingController();

  bool _loading = true;
  bool _enabled = true;
  int _autoInterval = 0;

  /// Null until the effective preset is resolved, or when it carries no
  /// `summary` block — the injection section stays hidden in both cases.
  String? _presetId;
  String _role = 'system';
  String _insertionMode = 'relative';
  int _depth = 1;

  /// What was loaded, so Save writes only what actually changed. Writing the
  /// prompt unconditionally would be harmless; writing the interval or the
  /// preset back is not — both are global state other chats read.
  late _SummarySettings _loaded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = ref.read(summaryServiceProvider);
    final enabled = await service.isSummaryEnabled(widget.sessionId);
    final prompt = await service.getSummaryPrompt(widget.sessionId);
    final interval = await ref.read(summaryAutoIntervalProvider.future);
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

    _promptCtrl.text = prompt ?? '';
    setState(() {
      _enabled = enabled;
      _autoInterval = interval;
      _presetId = block == null ? null : preset?.id;
      _role = block?.role ?? _role;
      _insertionMode = block?.insertionMode ?? _insertionMode;
      _depth = block?.depth ?? _depth;
      _loaded = _current();
      _loading = false;
    });
  }

  _SummarySettings _current() => _SummarySettings(
    enabled: _enabled,
    autoInterval: _autoInterval,
    prompt: _promptCtrl.text,
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
    if (current.prompt.trim() != loaded.prompt.trim()) {
      await ref
          .read(summaryServiceProvider)
          .setSummaryPrompt(
            sessionId: widget.sessionId,
            prompt: current.prompt,
          );
      ref.read(summaryRevisionProvider.notifier).state++;
    }
    if (current.autoInterval != loaded.autoInterval) {
      await ref
          .read(summaryAutoIntervalProvider.notifier)
          .set(current.autoInterval);
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
                      MenuRangeItem(
                        label: 'summary_auto_interval_label'.tr(),
                        description: 'summary_auto_interval_hint'.tr(),
                        value: _autoInterval.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 100,
                        decimalPlaces: 0,
                        editableValue: true,
                        onChanged: (v) =>
                            setState(() => _autoInterval = v.round()),
                      ),
                      MenuFieldItem(
                        label: 'summary_prompt_label'.tr(),
                        description: 'summary_prompt_hint'.tr(),
                        controller: _promptCtrl,
                        placeholder: defaultSummaryPrompt,
                        maxLines: 6,
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
                          label: 'label_insertion'.tr(),
                          currentValue: _insertionLabel(_insertionMode),
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

  static String _roleLabel(String role) => switch (role) {
    'user' => 'User',
    'assistant' => 'Assistant',
    _ => 'System',
  };

  static String _insertionLabel(String mode) =>
      mode == 'depth' ? 'injection_depth'.tr() : 'injection_relative'.tr();

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
        for (final mode in const ['relative', 'depth'])
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
  final int autoInterval;
  final String prompt;
  final String role;
  final String insertionMode;
  final int depth;

  const _SummarySettings({
    required this.enabled,
    required this.autoInterval,
    required this.prompt,
    required this.role,
    required this.insertionMode,
    required this.depth,
  });
}
