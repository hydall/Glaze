import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/character_provider.dart';
import '../../../core/utils/id_generator.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/list_controls.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/preset_switcher.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../models/block_config.dart';
import '../models/extension_preset.dart';
import '../providers/extension_preset_sort.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import '../screens/preset_editor/sections/blocks_section.dart';
import '../screens/preset_editor/sections/profiles_section.dart';
import '../services/block_transfer_service.dart';
import '../services/card_blocks.dart';
import 'ext_blocks_permissions_sheet.dart';

/// Which way the add-block sheet was answered.
enum _AddBlockChoice { import, create }

/// External Blocks control panel, opened from the magic drawer and from Tools.
///
/// The panel is the preset pill, the preset's API card and its blocks — tapping
/// a block opens that block's settings, and managing the presets themselves
/// lives behind the pill. There is no master on/off switch: the feature is
/// always available, and which preset runs is the only choice to make.
class ExtBlocksSettingsSheet extends ConsumerWidget {
  const ExtBlocksSettingsSheet({this.charId, super.key});

  /// The chat's character, when the panel is opened from a chat: its card's
  /// own blocks are listed under the preset's.
  final String? charId;

  static const _transfer = BlockTransferService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(extensionsSettingsProvider);
    final presets = ref.watch(extensionPresetsProvider);
    final activePreset = settings.activePresetId != null
        ? presets.where((p) => p.id == settings.activePresetId).firstOrNull
        : null;

    return SheetView(
      titleWidget: Text(
        'extblocks_sheet_title'.tr(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: context.cs.onSurface,
        ),
      ),
      // The header inset SheetView reports lives inside its own subtree,
      // so the padding must be read from a context below it — the outer
      // one puts the first row under the header strip.
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            0,
            MediaQuery.paddingOf(context).top + 12,
            0,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            // The dropdown heads the list: it says which preset everything
            // below belongs to. Permissions sit at the other end of the same
            // row — they are the preset's, not a setting among the blocks.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                // spaceBetween rather than a Spacer: a Flexible next to a
                // Spacer would split the free space with the pill and leave
                // the chip short of the cards' right edge.
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: PresetPill(
                      label: activePreset?.name ?? 'extblocks_preset_none'.tr(),
                      onTap: () => _showPresetSwitcher(context, ref),
                    ),
                  ),
                  if (activePreset != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: GlazeActionChip(
                        icon: Icons.verified_user_outlined,
                        label: 'extblocks_permissions'.tr(),
                        tooltip: 'extblocks_permissions'.tr(),
                        onTap: () => ExtBlocksPermissionsSheet.show(
                          context,
                          activePreset.id,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (activePreset == null)
              _Hint(text: 'extblocks_no_preset_hint'.tr())
            else ...[
              ProfilesSection(preset: activePreset),
              _BlocksGroup(
                header: 'extblocks_blocks_section'.tr(),
                blocks: activePreset.blocks,
                save: (blocks) => ref
                    .read(extensionPresetsProvider.notifier)
                    .update(activePreset.copyWith(blocks: blocks)),
              ),
              if (charId case final charId?)
                _BlocksGroup(
                  header: 'extblocks_card_blocks_section'.tr(),
                  blocks: cardBlocksOf(
                    ref.watch(characterByIdProvider(charId)),
                  ),
                  save: (blocks) => saveCardBlocks(ref.read, charId, blocks),
                  hint: 'extblocks_card_blocks_hint'.tr(),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// The preset list: rows pick, the header holds the sort control and the
  /// list's own menu, and each preset carries its own menu.
  void _showPresetSwitcher(BuildContext context, WidgetRef ref) {
    PresetSwitcher.show(
      context,
      title: 'extblocks_preset_pick'.tr(),
      sort: PresetSwitcherSort(
        sort: extensionPresetSortProvider,
        reorderArmed: extensionPresetReorderArmedProvider,
      ),
      menu: [
        PresetSwitcherAction(
          icon: Icons.add_circle_outline_rounded,
          label: 'extblocks_preset_create'.tr(),
          closesSwitcher: true,
          onTap: () => _createPreset(ref),
        ),
        PresetSwitcherAction(
          icon: Icons.file_download_outlined,
          label: 'extblocks_preset_import'.tr(),
          // Stays open: the imported preset appears in the list under it.
          onTap: () => _importPreset(context, ref),
        ),
      ],
      entriesBuilder: (sheetContext, sheetRef) {
        final activeId = sheetRef
            .watch(extensionsSettingsProvider)
            .activePresetId;
        return [
          for (final preset in sheetRef.watch(extensionPresetsProvider))
            PresetSwitcherEntry(
              id: preset.id,
              label: preset.name,
              sublabel:
                  '${'extblocks_blocks_section'.tr()}: ${preset.blocks.length}',
              isActive: activeId == preset.id,
              createdAt: preset.createdAt,
              menu: [
                PresetSwitcherAction(
                  icon: Icons.file_upload_outlined,
                  label: 'extblocks_preset_export'.tr(),
                  onTap: () => _exportPreset(sheetContext, preset),
                ),
                PresetSwitcherAction(
                  icon: Icons.delete_outline_rounded,
                  label: 'extblocks_preset_delete'.tr(),
                  isDestructive: true,
                  onTap: () =>
                      _confirmDeletePreset(sheetContext, sheetRef, preset),
                ),
              ],
              onSelect: () => sheetRef
                  .read(extensionsSettingsProvider.notifier)
                  .selectPreset(preset.id),
            ),
        ];
      },
    );
  }

  Future<void> _createPreset(WidgetRef ref) async {
    final presets = ref.read(extensionPresetsProvider);
    final preset = ExtensionPreset(
      id: generateId(),
      name: 'extblocks_preset_default_name'.tr(args: ['${presets.length + 1}']),
      blocks: const [],
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(extensionPresetsProvider.notifier).add(preset);
    await ref.read(extensionsSettingsProvider.notifier).selectPreset(preset.id);
  }

  /// Deleting a preset takes its blocks with it, so it asks first.
  void _confirmDeletePreset(
    BuildContext context,
    WidgetRef ref,
    ExtensionPreset preset,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'extblocks_preset_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline_rounded,
        description: 'extblocks_preset_delete_confirm'.tr(
          args: [preset.name, '${preset.blocks.length}'],
        ),
      ),
      items: [
        BottomSheetItem(
          label: 'action_delete'.tr(),
          icon: Icons.delete_outline_rounded,
          isDestructive: true,
          onTap: () {
            Navigator.pop(context);
            _deletePreset(ref, preset);
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          onTap: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Future<void> _deletePreset(WidgetRef ref, ExtensionPreset preset) async {
    final wasActive =
        ref.read(extensionsSettingsProvider).activePresetId == preset.id;
    await ref.read(extensionPresetsProvider.notifier).delete(preset.id);
    if (!wasActive) return;
    // The panel would otherwise keep showing a preset that no longer exists.
    final remaining = ref.read(extensionPresetsProvider);
    await ref
        .read(extensionsSettingsProvider.notifier)
        .selectPreset(remaining.isEmpty ? null : remaining.first.id);
  }

  Future<void> _importPreset(BuildContext context, WidgetRef ref) async {
    final preset = await _transfer.importPreset();
    if (!context.mounted) return;
    if (preset == null) {
      GlazeToast.show(context, 'extblocks_import_none'.tr());
      return;
    }
    await ref.read(extensionPresetsProvider.notifier).add(preset);
    await ref.read(extensionsSettingsProvider.notifier).selectPreset(preset.id);
    if (!context.mounted) return;
    GlazeToast.show(
      context,
      'extblocks_import_done'.tr(args: ['${preset.blocks.length}']),
    );
  }

  Future<void> _exportPreset(
    BuildContext context,
    ExtensionPreset preset,
  ) async {
    try {
      final path = await _transfer.exportPreset(preset);
      if (!context.mounted || path.isEmpty) return;
      GlazeToast.show(context, 'extblocks_export_done'.tr(args: [path]));
    } catch (e) {
      if (!context.mounted) return;
      GlazeToast.show(context, 'extblocks_export_failed'.tr(args: ['$e']));
    }
  }
}

/// Blocks saved together — the active preset's, or the card's own. Tapping
/// one opens its settings; the overflow menu holds the file and lifecycle
/// actions.
class _BlocksGroup extends ConsumerWidget {
  const _BlocksGroup({
    required this.header,
    required this.blocks,
    required this.save,
    this.hint,
  });

  final String header;
  final List<BlockConfig> blocks;
  final Future<void> Function(List<BlockConfig> blocks) save;

  /// Shown under the header while the group is empty.
  final String? hint;

  static const _transfer = BlockTransferService();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sorted = blocks.toList()..sort((a, b) => a.order.compareTo(b.order));

    return MenuGroup(
      header: '$header (${sorted.length})',
      items: [
        if (sorted.isEmpty)
          _Hint(text: hint ?? 'extblocks_blocks_empty'.tr())
        else
          for (final block in sorted)
            MenuScriptItem(
              name: block.name.isEmpty
                  ? 'extblocks_block_unnamed'.tr()
                  : block.name,
              subtitle: _subtitle(block),
              enabled: block.enabled,
              onToggle: (value) => _replace(block.copyWith(enabled: value)),
              onTap: () => showBlockEditSheet(context, block, onSave: _replace),
              onMore: () => _showActions(context, block),
            ),
        MenuItem(
          icon: Icons.add_circle_outline_rounded,
          label: 'extblocks_block_add'.tr(),
          onTap: () => _addBlock(context),
        ),
      ],
    );
  }

  /// Adds a note to the type/trigger line when the runtime cannot run this
  /// type yet, so an imported rewrite block does not look simply broken.
  String _subtitle(BlockConfig block) {
    final base = blockSubtitle(block);
    if (block.type.isRunnable) return base;
    return '$base • ${'extblocks_not_executed'.tr()}';
  }

  Future<void> _replace(BlockConfig block) => save([
    for (final b in blocks)
      if (b.id == block.id) block else b,
  ]);

  void _showActions(BuildContext context, BlockConfig block) {
    GlazeBottomSheet.show<void>(
      context,
      title: block.name.isEmpty ? 'extblocks_block_unnamed'.tr() : block.name,
      items: [
        BottomSheetItem(
          label: 'extblocks_block_export'.tr(),
          icon: Icons.file_upload_outlined,
          onTap: () {
            Navigator.pop(context);
            _export(context, block);
          },
        ),
        BottomSheetItem(
          label: 'extblocks_block_duplicate'.tr(),
          icon: Icons.copy_outlined,
          onTap: () {
            Navigator.pop(context);
            _duplicate(block);
          },
        ),
        BottomSheetItem(
          label: 'extblocks_block_delete'.tr(),
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () {
            Navigator.pop(context);
            save(blocks.where((b) => b.id != block.id).toList());
          },
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context, BlockConfig block) async {
    try {
      final path = await _transfer.exportBlock(block);
      if (!context.mounted || path.isEmpty) return;
      GlazeToast.show(context, 'extblocks_export_done'.tr(args: [path]));
    } catch (e) {
      if (!context.mounted) return;
      GlazeToast.show(context, 'extblocks_export_failed'.tr(args: ['$e']));
    }
  }

  void _duplicate(BlockConfig block) {
    final copy = block.copyWith(
      id: generateId(),
      name: '${block.name} (2)',
      order: blocks.length,
    );
    save([...blocks, copy]);
  }

  /// The add row: importing a file and starting a blank block are two ways to
  /// put a block into the group, so they sit behind one entry point. The
  /// choice comes back as the sheet's result rather than popping and opening
  /// the editor inside the tap, which would race the sheet's exit animation.
  Future<void> _addBlock(BuildContext context) async {
    final choice = await GlazeBottomSheet.show<_AddBlockChoice>(
      context,
      title: 'extblocks_block_add'.tr(),
      items: [
        BottomSheetItem(
          label: 'extblocks_block_import'.tr(),
          icon: Icons.file_download_outlined,
          onTap: () => Navigator.pop(context, _AddBlockChoice.import),
        ),
        BottomSheetItem(
          label: 'extblocks_block_create'.tr(),
          icon: Icons.add_circle_outline_rounded,
          onTap: () => Navigator.pop(context, _AddBlockChoice.create),
        ),
      ],
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case _AddBlockChoice.import:
        await _importBlocks(context);
      case _AddBlockChoice.create:
        await _createBlock(context);
    }
  }

  /// A blank block added to the end of the group, then opened straight in the
  /// editor so its type and settings can be filled in.
  Future<void> _createBlock(BuildContext context) async {
    final block = BlockConfig(
      id: generateId(),
      name: 'new_block'.tr(),
      enabled: true,
      order: blocks.length,
    );
    final added = [...blocks, block];
    await save(added);
    if (!context.mounted) return;
    showBlockEditSheet(
      context,
      block,
      onSave: (updated) => save([
        for (final b in added)
          if (b.id == updated.id) updated else b,
      ]),
    );
  }

  Future<void> _importBlocks(BuildContext context) async {
    final result = await _transfer.importBlocks(startOrder: blocks.length);
    if (!context.mounted || result.cancelled) return;

    if (result.blocks.isNotEmpty) await save([...blocks, ...result.blocks]);
    if (!context.mounted) return;

    if (result.unreadable.isNotEmpty) {
      GlazeToast.show(
        context,
        'extblocks_import_unreadable'.tr(args: [result.unreadable.join(', ')]),
      );
      return;
    }
    GlazeToast.show(
      context,
      result.isEmpty
          ? 'extblocks_import_none'.tr()
          : 'extblocks_import_done'.tr(args: ['${result.blocks.length}']),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 16),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
