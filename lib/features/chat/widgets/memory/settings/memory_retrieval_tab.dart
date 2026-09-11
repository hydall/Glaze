import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/state/lorebook_embedding_provider.dart';
import '../../../../../shared/theme/app_colors.dart';
import '../../../../../shared/widgets/list_controls.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../../settings/api_settings_screen.dart';
import 'memory_settings_draft.dart';

/// "Retrieval" — how a memory is matched and where it is injected.
///
/// This is also where the generation API *used* to be configured, with a
/// connection dropdown and a model dropdown that wrote straight through to
/// `PipelineSettings` on change while every other control on the sheet waited
/// for Save — so Cancel silently kept the new model. Both rows now live with
/// the app's other pipeline slots in API settings, and what is left here is a
/// link to them.
class MemoryRetrievalTab extends ConsumerWidget {
  final MemorySettingsDraft draft;

  /// Called after any mutation of [draft] so the host can rebuild.
  final VoidCallback onChanged;

  final ScrollController? controller;

  const MemoryRetrievalTab({
    super.key,
    required this.draft,
    required this.onChanged,
    this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The whole vector section is meaningless while semantic search is off for
    // the active API preset. The stored values are left untouched — flipping
    // the API toggle back on brings the previous choices back.
    final vectorAvailable = ref.watch(vectorSearchAvailableProvider);
    return ListView(
      controller: controller,
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 12,
        bottom: MediaQuery.paddingOf(context).bottom + 24,
      ),
      children: [
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
            header: 'search'.tr(),
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
      ],
    );
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

  static String _keyMatchLabel(String mode) => switch (mode) {
    'glaze' => 'memory_packing_glaze'.tr(),
    'both' => 'memory_packing_both'.tr(),
    _ => 'memory_packing_plain'.tr(),
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
