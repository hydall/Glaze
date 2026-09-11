import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../../core/services/memory_prompt_presets.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/list_controls.dart';
import '../../../../../shared/widgets/menu_group.dart';
import 'memory_settings_draft.dart';

/// Capture — when a draft is created and what prompt writes it. The part of
/// the form that is worth reading on the way in, so it is never behind a
/// disclosure.
///
/// A section list rather than a screen: the settings sheet is one scroll, not
/// a tab set. Three tabs put a third of the form behind a strip that scrolls
/// past ~2.35 tabs, which on a phone meant the last tab was simply off-screen.
///
/// Every row here was a Material control: `SwitchListTile`, a
/// `SegmentedButton` for the mode, a `DropdownButton<int>` that built one
/// item per step (two hundred of them for the interval), and a
/// `GestureDetector` over a translucent `Container` for the prompt picker.
class MemoryCaptureSections {
  final MemorySettingsDraft draft;
  final List<MemoryPromptPreset> customPrompts;

  /// Called after any mutation of [draft] so the host can rebuild.
  final VoidCallback onChanged;

  final VoidCallback onViewPrompt;
  final VoidCallback onManagePrompts;

  const MemoryCaptureSections({
    required this.draft,
    required this.customPrompts,
    required this.onChanged,
    required this.onViewPrompt,
    required this.onManagePrompts,
  });

  List<Widget> build(BuildContext context) {
    return [
        MenuGroup(
          items: [
            MenuSwitchItem(
              label: 'label_enabled'.tr(),
              value: draft.enabled,
              onChanged: (v) {
                draft.enabled = v;
                onChanged();
              },
            ),
            MenuSelectorItem(
              label: 'memory_mode'.tr(),
              currentValue: _modeLabel(draft.memoryMode),
              description: _modeDescription(draft.memoryMode),
              onTap: () => _pickMode(context),
            ),
          ],
        ),
        MenuGroup(
          header: 'memory_books_section_automation'.tr(),
          items: [
            MenuSwitchItem(
              label: 'memory_books_auto_create'.tr(),
              description: 'memory_books_auto_create_desc'.tr(),
              value: draft.autoCreate,
              onChanged: (v) {
                draft.autoCreate = v;
                onChanged();
              },
            ),
            MenuSwitchItem(
              label: 'memory_books_auto_generate'.tr(),
              description: 'memory_books_auto_generate_desc'.tr(),
              value: draft.autoGenerate,
              onChanged: (v) {
                draft.autoGenerate = v;
                onChanged();
              },
            ),
            if (draft.autoCreate) ...[
              MenuSwitchItem(
                label: 'memory_books_delayed_automation'.tr(),
                description: 'memory_books_delayed_automation_desc'.tr(),
                value: draft.useDelayedAutomation,
                onChanged: (v) {
                  draft.useDelayedAutomation = v;
                  onChanged();
                },
              ),
              MenuRangeItem(
                label: 'memory_books_auto_create_interval'.tr(),
                value: draft.autoCreateInterval.toDouble(),
                min: 1,
                max: 200,
                divisions: 199,
                decimalPlaces: 0,
                editableValue: true,
                onChanged: (v) {
                  draft.autoCreateInterval = v.round();
                  onChanged();
                },
              ),
              MenuRangeItem(
                label: 'memory_books_auto_create_lag'.tr(),
                // The help text used to hide behind a "?" that opened an
                // AlertDialog; as a description it is simply readable.
                description: 'memory_books_auto_create_lag_help'.tr(),
                value: draft.autoCreateLagMessages.toDouble(),
                min: 0,
                max: 50,
                divisions: 50,
                decimalPlaces: 0,
                editableValue: true,
                onChanged: (v) {
                  draft.autoCreateLagMessages = v.round();
                  onChanged();
                },
              ),
            ],
            MenuRangeItem(
              label: 'memory_books_batch_size'.tr(),
              value: draft.batchSize.toDouble(),
              min: 1,
              max: 50,
              divisions: 49,
              decimalPlaces: 0,
              editableValue: true,
              onChanged: (v) {
                draft.batchSize = v.round();
                onChanged();
              },
            ),
          ],
        ),
        MenuGroup(
          header: 'memory_prompt_section'.tr(),
          items: [
            MenuSelectorItem(
              label: 'memory_prompt_choose'.tr(),
              currentValue: MemoryPromptPresets.label(
                draft.promptPreset,
                customPrompts,
              ),
              onTap: () => _pickPrompt(context),
            ),
            MenuItem(
              key: const Key('memory_view_current_prompt'),
              icon: Icons.visibility_outlined,
              label: 'memory_prompt_view_current'.tr(),
              onTap: onViewPrompt,
            ),
            MenuItem(
              icon: Icons.tune_rounded,
              label: 'memory_prompt_manage'.tr(),
              trailing: Icon(
                Icons.chevron_right,
                size: 22,
                color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              onTap: onManagePrompts,
            ),
          ],
        ),
    ];
  }

  // ── Pickers ──────────────────────────────────────────────────────

  static String _modeLabel(String mode) => switch (mode) {
    'legacy' => 'memory_mode_legacy'.tr(),
    'balanced' => 'memory_mode_balanced'.tr(),
    _ => 'memory_mode_fast'.tr(),
  };

  static String _modeDescription(String mode) => switch (mode) {
    'legacy' => 'memory_mode_legacy_desc'.tr(),
    'balanced' => 'memory_mode_balanced_desc'.tr(),
    _ => 'memory_mode_fast_desc'.tr(),
  };

  void _pickMode(BuildContext context) {
    showGlazePickerSheet(
      context,
      title: 'memory_mode'.tr(),
      items: [
        for (final mode in const ['legacy', 'fast', 'balanced'])
          GlazePickerItem(
            label: _modeLabel(mode),
            hint: _modeDescription(mode),
            isActive: draft.memoryMode == mode,
            value: mode,
          ),
      ],
      onSelect: (value) {
        draft.memoryMode = value as String;
        onChanged();
      },
    );
  }

  void _pickPrompt(BuildContext context) {
    showGlazePickerSheet(
      context,
      title: 'memory_prompt_choose'.tr(),
      items: [
        for (final preset in MemoryPromptPresets.builtIn)
          GlazePickerItem(
            label: preset.label,
            isActive: preset.key == draft.promptPreset,
            value: preset.key,
          ),
        for (final preset in customPrompts)
          GlazePickerItem(
            label: preset.label,
            hint: 'memory_custom_label'.tr(),
            isActive: preset.key == draft.promptPreset,
            value: preset.key,
          ),
      ],
      onSelect: (value) {
        draft.promptPreset = value as String;
        onChanged();
      },
    );
  }
}
