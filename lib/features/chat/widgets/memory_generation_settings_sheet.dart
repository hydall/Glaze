import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/memory_book.dart';
import '../../../core/services/memory_prompt_presets.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import 'custom_prompt_manager_sheet.dart';
import 'memory/settings/memory_capture_tab.dart';
import 'memory/settings/memory_retrieval_tab.dart';
import 'memory/settings/memory_selection_tab.dart';
import 'memory/settings/memory_settings_draft.dart';

/// Memory generation settings.
///
/// Was a single 1223-line class of Material controls inside a
/// `GlazeBottomSheet` body — which lays its child out unbounded, so a form
/// this size never had a viewport of its own. It is a [SheetView] now, with
/// the form split across three tabs and every row from the kit's menu set:
/// the `SegmentedButton`s became [MenuSelectorItem] pickers, the
/// `SwitchListTile`s [MenuSwitchItem], the bare `Slider`s and the
/// `DropdownButton<int>`s (which built one entry per step — two hundred of
/// them for the auto-create interval) [MenuRangeItem], and the `AlertDialog`
/// help popups became the rows' own descriptions.
class MemoryGenerationSettingsSheet extends ConsumerStatefulWidget {
  final MemoryBookSettings settings;
  final String? sessionId;

  const MemoryGenerationSettingsSheet({
    super.key,
    required this.settings,
    this.sessionId,
  });

  /// Presents the sheet and returns the edit, or null when it was dismissed.
  ///
  /// Presentation moved here from the caller because the sheet is no longer a
  /// `GlazeBottomSheet` body: it is a screen-shaped sheet and has to be shown
  /// as one.
  static Future<MemorySettingsSheetResult?> show(
    BuildContext context, {
    required MemoryBookSettings settings,
    String? sessionId,
  }) {
    return showModalBottomSheet<MemorySettingsSheetResult>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryGenerationSettingsSheet(
        settings: settings,
        sessionId: sessionId,
      ),
    );
  }

  @override
  ConsumerState<MemoryGenerationSettingsSheet> createState() =>
      _MemoryGenerationSettingsSheetState();
}

class _MemoryGenerationSettingsSheetState
    extends ConsumerState<MemoryGenerationSettingsSheet> {
  static const int _tabCount = 3;

  late final MemorySettingsDraft _draft;
  int _tab = 0;

  /// One per tab. `SheetView` coordinates its drag-to-expand with the body's
  /// scroll position, and during a slide both tab bodies are alive — sharing
  /// one controller would attach it to two scroll views at once.
  final List<ScrollController> _scrollControllers = List.generate(
    _tabCount,
    (_) => ScrollController(),
  );

  @override
  void initState() {
    super.initState();
    _draft = MemorySettingsDraft.from(
      widget.settings,
      vectorThreshold: ref.read(memoryGlobalSettingsProvider).vectorThreshold,
    );
  }

  @override
  void dispose() {
    for (final controller in _scrollControllers) {
      controller.dispose();
    }
    _draft.dispose();
    super.dispose();
  }

  List<MemoryPromptPreset> get _customPrompts =>
      MemoryPromptPreset.fromJsonList(
        ref.read(memoryGlobalSettingsProvider).customPrompts,
      );

  void _onChanged() => setState(() {});

  void _save() {
    Navigator.pop(
      context,
      MemorySettingsSheetResult(
        settings: _draft.toSettings(widget.settings),
        vectorThreshold: _draft.vectorThreshold,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final custom = _customPrompts;
    return SheetView(
      title: 'memory_books_settings_title'.tr(),
      showBack: true,
      scrollController: _scrollControllers[_tab],
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check_rounded),
          tooltip: 'btn_save'.tr(),
          onPressed: _save,
        ),
      ],
      headerBottom: GlazeTabBar(
        tabs: [
          GlazeTabItem(
            label: 'memory_tab_capture'.tr(),
            icon: Icons.auto_awesome_motion_outlined,
          ),
          GlazeTabItem(
            label: 'memory_tab_selection'.tr(),
            icon: Icons.filter_alt_outlined,
          ),
          GlazeTabItem(
            label: 'memory_tab_retrieval'.tr(),
            icon: Icons.travel_explore_outlined,
          ),
        ],
        activeIndex: _tab,
        onChanged: (index) => setState(() => _tab = index),
      ),
      body: SwipeTabSwitcher(
        index: _tab,
        length: _tabCount,
        onChanged: (index) => setState(() => _tab = index),
        child: TabSlideSwitcher(
          index: _tab,
          child: switch (_tab) {
            0 => MemoryCaptureTab(
              controller: _scrollControllers[0],
              draft: _draft,
              customPrompts: custom,
              onChanged: _onChanged,
              onViewPrompt: _viewCurrentPrompt,
              onManagePrompts: _openPromptManager,
            ),
            1 => MemorySelectionTab(
              controller: _scrollControllers[1],
              draft: _draft,
              onChanged: _onChanged,
              budgetPercent: widget.settings.maxInjectionBudgetPercent,
            ),
            _ => MemoryRetrievalTab(
              controller: _scrollControllers[2],
              draft: _draft,
              onChanged: _onChanged,
            ),
          },
        ),
      ),
    );
  }

  Future<void> _viewCurrentPrompt() async {
    final custom = _customPrompts;
    final preset =
        MemoryPromptPresets.find(_draft.promptPreset, custom) ??
        MemoryPromptPresets.builtIn.first;
    await GlazeBottomSheet.show<void>(
      context,
      title: preset.label,
      child: MemoryPromptPreviewSheet(preset: preset),
    );
  }

  void _openPromptManager() async {
    final custom = _customPrompts;
    final result = await GlazeBottomSheet.show<List<MemoryPromptPreset>>(
      context,
      title: 'memory_prompt_presets_title'.tr(),
      child: CustomPromptManagerSheet(customPrompts: custom),
    );
    if (!mounted || result == null) return;
    final notifier = ref.read(memoryGlobalSettingsProvider.notifier);
    final current = ref.read(memoryGlobalSettingsProvider);
    final repo = ref.read(memoryBookRepoProvider);
    final selected = MemoryPromptPresets.validSelection(
      _draft.promptPreset,
      result,
    );
    await notifier.save(
      current.copyWith(
        customPrompts: MemoryPromptPreset.toJsonList(result),
        promptPreset: MemoryPromptPresets.validSelection(
          current.promptPreset,
          result,
        ),
      ),
    );
    // Preset definitions are global, while selections are stored per book.
    // Complete the repair even if this sheet is dismissed during persistence.
    await repo.repairPromptPresetSelections(result.map((preset) => preset.key));
    if (!mounted) return;
    ref.invalidate(memoryBookProvider);
    setState(() => _draft.promptPreset = selected);
  }
}

class MemorySettingsSheetResult {
  final MemoryBookSettings settings;
  final double vectorThreshold;

  const MemorySettingsSheetResult({
    required this.settings,
    required this.vectorThreshold,
  });
}
