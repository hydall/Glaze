import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/api_config.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/preset_switcher.dart';
import '../settings/api_list_provider.dart';
import '../settings/api_preset_selection_provider.dart';
import '../settings/api_preset_sort.dart';

/// The embedding presets sheet and the actions around it: switching, adding
/// and deleting presets of the Embeddings screen's own list.
///
/// The editor that owns the open preset hands in two hooks, so a pending
/// debounced save lands on the right row: [flushPendingSave] before the
/// selection moves (the edits belong to the preset being left), and
/// [cancelPendingSave] before a delete (a late save would write the row back).
class EmbeddingPresetActions {
  final BuildContext context;
  final WidgetRef ref;
  final VoidCallback flushPendingSave;
  final VoidCallback cancelPendingSave;

  EmbeddingPresetActions({
    required this.context,
    required this.ref,
    required this.flushPendingSave,
    required this.cancelPendingSave,
  });

  /// Whether the presets sheet is on screen. A bulk delete can outlive it, and
  /// closing "the sheet" once it is gone would pop whatever took its place.
  bool _sheetOpen = false;

  EmbeddingPresetListNotifier get _presets =>
      ref.read(embeddingPresetListProvider.notifier);

  /// Moves the embedding side onto [id] (or, with null, back onto the
  /// repository's first preset) and remembers it across launches.
  Future<void> _activate(String? id) async {
    ref.read(activeEmbeddingPresetIdProvider.notifier).state = id;
    final prefs = ref.read(sharedPreferencesProvider).value;
    if (prefs == null) return;
    if (id != null) {
      await prefs.setString(kActiveEmbeddingConfigIdKey, id);
    } else {
      await prefs.remove(kActiveEmbeddingConfigIdKey);
    }
  }

  /// The presets sheet. Its rows are built from the providers on every
  /// rebuild, so sorting, dragging, deleting or selecting updates the open
  /// sheet in place.
  Future<void> showSheet() async {
    _sheetOpen = true;
    await PresetSwitcher.show(
      context,
      title: 'settings_embedding_config_title'.tr(),
      sort: PresetSwitcherSort(
        sort: apiPresetSortProvider,
        reorderArmed: apiPresetReorderArmedProvider,
      ),
      addAction: PresetSwitcherAction(
        icon: Icons.add_circle_outline_rounded,
        label: 'settings_new_config_tooltip'.tr(),
        closesSwitcher: true,
        onTap: createNew,
      ),
      selection: PresetSwitcherSelection(
        isActive: (ref) => ref.watch(apiPresetSelectionProvider).active,
        header: (_, ref) =>
            _buildSelectionActions(ref.watch(apiPresetSelectionProvider)),
      ),
      entriesBuilder: (_, sheetRef) {
        final list =
            sheetRef.watch(embeddingPresetListProvider).value ??
            const <ApiConfig>[];
        final sort =
            sheetRef.watch(apiPresetSortProvider).value ??
            const ApiPresetSortState();
        final selection = sheetRef.watch(apiPresetSelectionProvider);
        final reordering =
            sort.mode == ApiPresetSortMode.manual &&
            sheetRef.watch(apiPresetReorderArmedProvider);
        // The active id falls back to the repository's first preset, the same
        // one activeEmbeddingConfigProvider picks — sorting only reorders what
        // is shown, so it must not move the highlight to another row.
        final activeId =
            sheetRef.watch(activeEmbeddingPresetIdProvider) ??
            (list.isNotEmpty ? list.first.id : null);
        return [
          for (final config in list)
            _entry(
              sheetRef,
              config,
              activeId,
              selection: selection,
              reordering: reordering,
            ),
        ];
      },
    );
    _sheetOpen = false;
    if (!context.mounted) return;
    // The selection and the armed drag belong to the open sheet, not to the
    // screen behind it.
    ref.read(apiPresetSelectionProvider.notifier).clear();
    ref.read(apiPresetReorderArmedProvider.notifier).state = false;
  }

  /// What the sheet header shows while presets are selected: the count and the
  /// bulk actions, in place of the sort and add controls.
  Widget _buildSelectionActions(ApiPresetSelectionState selection) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${selection.count} ${'selected_count'.tr()}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: context.cs.onSurfaceVariant,
          ),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline_rounded, color: context.cs.error),
          tooltip: 'action_delete'.tr(),
          onPressed: () => _confirmDeleteSelected(selection),
        ),
        IconButton(
          icon: Icon(Icons.close_rounded, color: context.cs.onSurfaceVariant),
          tooltip: 'btn_cancel'.tr(),
          onPressed: () =>
              ref.read(apiPresetSelectionProvider.notifier).clear(),
        ),
      ],
    );
  }

  PresetSwitcherEntry _entry(
    WidgetRef sheetRef,
    ApiConfig config,
    String? activeId, {
    required ApiPresetSelectionState selection,
    required bool reordering,
  }) {
    final isSelected = selection.contains(config.id);
    final endpoint = config.embeddingEndpoint.isNotEmpty
        ? config.embeddingEndpoint
        : config.endpoint;
    return PresetSwitcherEntry(
      id: config.id,
      label: embeddingPresetName(config),
      sublabel: endpoint.isNotEmpty
          ? endpoint.replaceAll(RegExp(r'https?://'), '').split('/').first
          : null,
      isActive: selection.active ? isSelected : config.id == activeId,
      isSelected: isSelected,
      // While selecting, the radio button gives way to a check mark.
      icon: selection.active
          ? (isSelected
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded)
          : null,
      closeOnTap: !selection.active,
      onLongPress: reordering
          ? null
          : () => sheetRef
                .read(apiPresetSelectionProvider.notifier)
                .start(config.id),
      menu: [
        if (!selection.active)
          PresetSwitcherAction(
            icon: Icons.delete_outline_rounded,
            label: 'action_delete'.tr(),
            isDestructive: true,
            onTap: () => _delete({config.id}),
          ),
      ],
      onSelect: () {
        if (selection.active) {
          sheetRef.read(apiPresetSelectionProvider.notifier).toggle(config.id);
          return;
        }
        flushPendingSave();
        _activate(config.id);
      },
    );
  }

  /// Removes [ids] and, when the open preset was among them, lets the
  /// embedding side fall back to the first preset left.
  Future<void> _delete(Set<String> ids) async {
    cancelPendingSave();
    final activeId = ref.read(activeEmbeddingConfigProvider)?.id;
    for (final id in ids) {
      if (!context.mounted) return;
      await _presets.remove(id);
    }
    if (!context.mounted) return;
    if (activeId != null && ids.contains(activeId)) await _activate(null);
  }

  void _confirmDeleteSelected(ApiPresetSelectionState selection) {
    final ids = selection.ids.toSet();
    if (ids.isEmpty) return;
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'api_delete_many_confirm'.plural(ids.length),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(apiPresetSelectionProvider.notifier).clear();
            await _delete(ids);
            if (!context.mounted) return;
            final remaining = await ref.read(
              embeddingPresetListProvider.future,
            );
            // An empty sheet would be a header and nothing else.
            if (remaining.isEmpty && context.mounted && _sheetOpen) {
              Navigator.of(context, rootNavigator: true).pop();
            }
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  /// Asks for a name, creates an embedding preset and makes it the one the
  /// embedding side runs on.
  Future<void> createNew() async {
    await GlazeBottomSheet.show<void>(
      context,
      title: 'settings_new_config_title'.tr(),
      input: BottomSheetInput(
        placeholder: 'My embeddings',
        confirmLabel: 'btn_create'.tr(),
        onConfirm: (name) async {
          Navigator.of(context, rootNavigator: true).pop();
          final trimmed = name.trim();
          if (trimmed.isEmpty) return;
          flushPendingSave();
          final config = ApiConfig(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: trimmed,
            mode: kEmbeddingPresetMode,
          );
          await _presets.put(config);
          await _activate(config.id);
        },
      ),
    );
  }
}

/// The label a preset goes by in the pill and the sheet.
String embeddingPresetName(ApiConfig? config) {
  if (config == null) return 'no_active_connections'.tr();
  if (config.name.isNotEmpty) return config.name;
  if (config.embeddingModel.isNotEmpty) return config.embeddingModel;
  return 'unnamed_entry'.tr();
}
