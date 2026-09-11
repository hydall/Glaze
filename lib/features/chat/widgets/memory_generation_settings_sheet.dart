import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/memory_book.dart';
import '../../../core/services/memory_prompt_presets.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'custom_prompt_manager_sheet.dart';
import 'memory/settings/memory_capture_tab.dart';
import 'memory/settings/memory_retrieval_tab.dart';
import 'memory/settings/memory_selection_tab.dart';
import 'memory/settings/memory_settings_draft.dart';

/// Memory generation settings.
///
/// Was a single 1223-line class of Material controls inside a
/// `GlazeBottomSheet` body — which lays its child out unbounded, so a form
/// this size never had a viewport of its own. It is a [SheetView] now, built
/// from the kit's menu rows: the `SegmentedButton`s became [MenuSelectorItem]
/// pickers, the `SwitchListTile`s [MenuSwitchItem], the bare `Slider`s and the
/// `DropdownButton<int>`s (which built one entry per step — two hundred of
/// them for the auto-create interval) [MenuRangeItem], and the `AlertDialog`
/// help popups became the rows' own descriptions.
///
/// One scroll, not a tab set. Splitting the form across three tabs read as
/// tidier on paper and was worse in the hand: [GlazeTabBar] scrolls past ~2.35
/// tabs, so at phone width the third tab sat off-screen with no affordance
/// saying it existed. What the form actually needed was for the two thirds
/// nobody tunes daily to be *collapsed*, which is what
/// [MenuCollapsibleSection] is for.
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
  late final MemorySettingsDraft _draft;
  final ScrollController _scrollController = ScrollController();

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
    _scrollController.dispose();
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
    final capture = MemoryCaptureSections(
      draft: _draft,
      customPrompts: _customPrompts,
      onChanged: _onChanged,
      onViewPrompt: _viewCurrentPrompt,
      onManagePrompts: _openPromptManager,
    );
    final selection = MemorySelectionSections(
      draft: _draft,
      onChanged: _onChanged,
      budgetPercent: widget.settings.maxInjectionBudgetPercent,
    );
    final retrieval = MemoryRetrievalSections(
      draft: _draft,
      onChanged: _onChanged,
      vectorAvailable: ref.watch(vectorSearchAvailableProvider),
    );

    return SheetView(
      title: 'memory_books_settings_title'.tr(),
      showBack: true,
      scrollController: _scrollController,
      actions: [
        SheetViewAction(
          icon: const Icon(Icons.check_rounded),
          tooltip: 'btn_save'.tr(),
          onPressed: _save,
        ),
      ],
      // Builder, not this build's `context`: SheetView reports its measured
      // header height as MediaQuery padding *to its body subtree*, so reading
      // it from the context that creates the SheetView returns zero and the
      // first row lays out underneath the header.
      body: Builder(
        builder: (bodyContext) => ListView(
          controller: _scrollController,
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(bodyContext).top + 12,
            bottom: MediaQuery.paddingOf(bodyContext).bottom + 24,
          ),
          children: [
            ...capture.build(context),
            ...retrieval.apiSections(context),
            MenuCollapsibleSection(
              label: 'memory_section_budget'.tr(),
              children: selection.budgetSections(context),
            ),
            MenuCollapsibleSection(
              label: 'memory_selector_settings'.tr(),
              children: selection.selectorSections(context),
            ),
            MenuCollapsibleSection(
              label: 'memory_section_search'.tr(),
              children: retrieval.matchingSections(context),
            ),
          ],
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
