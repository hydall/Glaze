import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/list_controls.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../../settings/api_settings_screen.dart';
import 'memory_settings_draft.dart';

/// Retrieval — how a memory is matched and where it is injected, plus the link
/// to where its generation API now lives.
///
/// Returned as two lists: [apiSections], which belongs in the always-visible
/// part of the form because it is the one row people come here looking for,
/// and [matchingSections], which is tuning and sits behind a disclosure.
///
/// The generation API *used* to be configured right here, with a connection
/// dropdown and a model dropdown that wrote straight through to
/// `PipelineSettings` on change while every other control on the sheet waited
/// for Save — so Cancel silently kept the new model. Both rows now live with
/// the app's other pipeline slots in API settings.
class MemoryRetrievalSections {
  final MemorySettingsDraft draft;

  /// Called after any mutation of [draft] so the host can rebuild.
  final VoidCallback onChanged;

  /// Whether the active API preset has semantic search on. The whole vector
  /// block is meaningless without it; the stored values are left untouched, so
  /// flipping the API toggle back on brings the previous choices back.
  final bool vectorAvailable;

  const MemoryRetrievalSections({
    required this.draft,
    required this.onChanged,
    required this.vectorAvailable,
  });

  List<Widget> apiSections(BuildContext context) {
    return [
      MenuGroup(
        header: 'tab_api'.tr(),
        description: 'memory_books_api_moved_desc'.tr(),
        items: [
          MenuItem(
            icon: Icons.hub_outlined,
            label: 'memory_books_generation_connection'.tr(),
            trailing: Icon(
              Icons.chevron_right,
              size: 22,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            onTap: () => showApiSettingsSheet(
              context,
              focusSection: ApiSettingsSection.memoryBook,
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> matchingSections(BuildContext context) {
    return [
        MenuGroup(
          header: 'label_embedding_target'.tr(),
          items: [
            MenuSelectorItem(
              label: 'label_embedding_target'.tr(),
              currentValue: draft.injectionTarget == 'macro'
                  ? 'memory_injection_macro'.tr()
                  : 'memory_injection_hard_block'.tr(),
              onTap: () => _pickInjectionTarget(context),
            ),
          ],
        ),
        if (vectorAvailable)
          MenuGroup(
            header: 'memory_section_search'.tr(),
            items: [
              MenuSwitchItem(
                label: 'label_vector_search'.tr(),
                value: draft.vectorSearchEnabled,
                onChanged: (v) {
                  draft.vectorSearchEnabled = v;
                  onChanged();
                },
              ),
              if (draft.vectorSearchEnabled) ...[
                MenuRangeItem(
                  label: 'label_similarity_threshold'.tr(),
                  value: draft.vectorThreshold,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  onChanged: (v) {
                    draft.vectorThreshold = v;
                    onChanged();
                  },
                ),
                MenuSelectorItem(
                  label: 'label_search_type'.tr(),
                  currentValue: _keyMatchLabel(draft.keyMatchMode),
                  onTap: () => _pickKeyMatchMode(context),
                ),
              ],
            ],
          ),
    ];
  }

  void _pickInjectionTarget(BuildContext context) {
    showGlazePickerSheet(
      context,
      title: 'label_embedding_target'.tr(),
      items: [
        GlazePickerItem(
          label: 'memory_injection_hard_block'.tr(),
          isActive: draft.injectionTarget != 'macro',
          value: 'hard_block',
        ),
        GlazePickerItem(
          label: 'memory_injection_macro'.tr(),
          isActive: draft.injectionTarget == 'macro',
          value: 'macro',
        ),
      ],
      onSelect: (value) {
        draft.injectionTarget = value as String;
        onChanged();
      },
    );
  }

  /// Key-match modes had been labelled with the *packing* strings, so the row
  /// read "Glaze" / "Plain" — words about how memories are packed, not about
  /// what a query is matched against.
  static String _keyMatchLabel(String mode) => switch (mode) {
    'glaze' => 'memory_keymatch_glaze'.tr(),
    'both' => 'memory_keymatch_both'.tr(),
    _ => 'memory_keymatch_plain'.tr(),
  };

  void _pickKeyMatchMode(BuildContext context) {
    showGlazePickerSheet(
      context,
      title: 'label_search_type'.tr(),
      items: [
        for (final mode in const ['plain', 'glaze', 'both'])
          GlazePickerItem(
            label: _keyMatchLabel(mode),
            isActive: draft.keyMatchMode == mode,
            value: mode,
          ),
      ],
      onSelect: (value) {
        draft.keyMatchMode = value as String;
        onChanged();
      },
    );
  }
}
