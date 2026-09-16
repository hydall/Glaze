import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/id_generator.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/preset_switcher.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../models/block_config.dart';
import '../models/extension_preset.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import '../screens/preset_editor/sections/blocks_section.dart';
import '../services/block_transfer_service.dart';
import 'ext_blocks_permissions_sheet.dart';

/// Ext Blocks control panel, opened from the magic drawer and from Tools.
///
/// It is the quick surface: pick the preset, see its blocks, toggle one, and
/// move blocks in or out as files. Managing the presets themselves sits behind
/// the pill in the group header rather than as rows of its own, so the panel
/// reads as a switch and a list. Anything that needs room — editing a block,
/// connection profiles — lives in the preset editor, one tap away.
class ExtBlocksSettingsSheet extends ConsumerWidget {
  const ExtBlocksSettingsSheet({super.key});

  static const _transfer = BlockTransferService();

  /// The "no preset" row. Real presets carry a generated id, so this cannot
  /// collide with one.
  static const _noPresetId = '__none__';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(extensionsSettingsProvider);
    final presets = ref.watch(extensionPresetsProvider);
    final activePreset = settings.activePresetId != null
        ? presets.where((p) => p.id == settings.activePresetId).firstOrNull
        : null;

    return SheetView(
      title: 'extblocks_sheet_title'.tr(),
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
            MenuGroup(
              header: 'extblocks_preset_section'.tr(),
              description: 'extblocks_sheet_subtitle'.tr(),
              // Everything a preset list needs — pick, create, import, export,
              // delete — is behind this one pill, so the panel itself stays a
              // switch and a list of blocks.
              headerTrailing: PresetPill(
                label: activePreset?.name ?? 'extblocks_preset_none'.tr(),
                onTap: () => _showPresetSwitcher(context, ref),
              ),
              items: [
                MenuSwitchItem(
                  label: 'extblocks_enabled'.tr(),
                  description: 'extblocks_enabled_desc'.tr(),
                  value: settings.enabled,
                  onChanged: (value) => ref
                      .read(extensionsSettingsProvider.notifier)
                      .update(settings.copyWith(enabled: value)),
                ),
                if (activePreset != null)
                  MenuItem(
                    icon: Icons.verified_user_outlined,
                    label: 'extblocks_permissions'.tr(),
                    subtitle: 'extblocks_permissions_desc'.tr(),
                    onTap: () => ExtBlocksPermissionsSheet.show(
                      context,
                      activePreset.id,
                    ),
                  ),
              ],
            ),
            if (activePreset == null)
              _Hint(text: 'extblocks_no_preset_hint'.tr())
            else
              _BlocksGroup(
                preset: activePreset,
                onImport: () => _importBlocks(context, ref, activePreset),
              ),
          ],
        ),
      ),
    );
  }

  /// The preset list: rows pick, the header creates and imports, and each row
  /// carries its own export and delete.
  void _showPresetSwitcher(BuildContext context, WidgetRef ref) {
    PresetSwitcher.show(
      context,
      title: 'extblocks_preset_pick'.tr(),
      headerActions: [
        PresetSwitcherHeaderAction(
          icon: Icons.file_download_outlined,
          tooltip: 'extblocks_preset_import'.tr(),
          // Stays open: the imported preset appears in the list under it.
          onTap: () => _importPreset(context, ref),
        ),
        PresetSwitcherHeaderAction(
          icon: Icons.add_circle_outline_rounded,
          tooltip: 'extblocks_preset_create'.tr(),
          closesSheet: true,
          onTap: () => _createPreset(ref),
        ),
      ],
      entriesBuilder: (sheetContext, sheetRef) {
        final activeId = sheetRef
            .watch(extensionsSettingsProvider)
            .activePresetId;
        final presets = sheetRef.watch(extensionPresetsProvider);
        return [
          PresetSwitcherEntry(
            id: _noPresetId,
            label: 'extblocks_preset_none'.tr(),
            isActive: activeId == null,
            onSelect: () => sheetRef
                .read(extensionsSettingsProvider.notifier)
                .selectPreset(null),
          ),
          for (final preset in presets)
            PresetSwitcherEntry(
              id: preset.id,
              label: preset.name,
              sublabel:
                  '${'extblocks_blocks_section'.tr()}: ${preset.blocks.length}',
              isActive: activeId == preset.id,
              actions: [
                PresetSwitcherRowAction(
                  icon: Icons.file_upload_outlined,
                  onTap: () => _exportPreset(sheetContext, preset),
                ),
                PresetSwitcherRowAction(
                  icon: Icons.delete_outline_rounded,
                  color: sheetContext.cs.error,
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

  Future<void> _importBlocks(
    BuildContext context,
    WidgetRef ref,
    ExtensionPreset preset,
  ) async {
    final result = await _transfer.importBlocks(
      startOrder: preset.blocks.length,
    );
    if (!context.mounted || result.cancelled) return;

    if (result.blocks.isNotEmpty) {
      await ref
          .read(extensionPresetsProvider.notifier)
          .update(
            preset.copyWith(blocks: [...preset.blocks, ...result.blocks]),
          );
    }
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

/// The active preset's blocks, read-only apart from the enable toggle.
///
/// Editing opens the preset editor rather than a second editor here, so there
/// is one place where a block's settings live.
class _BlocksGroup extends ConsumerWidget {
  const _BlocksGroup({required this.preset, required this.onImport});

  final ExtensionPreset preset;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = preset.blocks.toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    return MenuGroup(
      header: '${'extblocks_blocks_section'.tr()} (${blocks.length})',
      items: [
        if (blocks.isEmpty)
          _Hint(text: 'extblocks_blocks_empty'.tr())
        else
          for (final block in blocks)
            MenuScriptItem(
              name: block.name.isEmpty
                  ? 'extblocks_block_unnamed'.tr()
                  : block.name,
              subtitle: _subtitle(block),
              enabled: block.enabled,
              onToggle: (value) => _toggle(ref, block, value),
              onTap: () {
                Navigator.pop(context);
                context.push('/extensions/preset-editor/${preset.id}');
              },
              onMore: () => _showActions(context, ref, block),
            ),
        MenuItem(
          icon: Icons.file_download_outlined,
          label: 'extblocks_blocks_import'.tr(),
          onTap: onImport,
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

  void _toggle(WidgetRef ref, BlockConfig block, bool enabled) {
    ref
        .read(extensionPresetsProvider.notifier)
        .update(
          preset.copyWith(
            blocks: [
              for (final b in preset.blocks)
                if (b.id == block.id) b.copyWith(enabled: enabled) else b,
            ],
          ),
        );
  }

  void _showActions(BuildContext context, WidgetRef ref, BlockConfig block) {
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
            _duplicate(ref, block);
          },
        ),
        BottomSheetItem(
          label: 'extblocks_block_delete'.tr(),
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () {
            Navigator.pop(context);
            _delete(ref, block);
          },
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context, BlockConfig block) async {
    try {
      final path = await const BlockTransferService().exportBlock(block);
      if (!context.mounted || path.isEmpty) return;
      GlazeToast.show(context, 'extblocks_export_done'.tr(args: [path]));
    } catch (e) {
      if (!context.mounted) return;
      GlazeToast.show(context, 'extblocks_export_failed'.tr(args: ['$e']));
    }
  }

  void _duplicate(WidgetRef ref, BlockConfig block) {
    final copy = block.copyWith(
      id: generateId(),
      name: '${block.name} (2)',
      order: preset.blocks.length,
    );
    ref
        .read(extensionPresetsProvider.notifier)
        .update(preset.copyWith(blocks: [...preset.blocks, copy]));
  }

  void _delete(WidgetRef ref, BlockConfig block) {
    ref
        .read(extensionPresetsProvider.notifier)
        .update(
          preset.copyWith(
            blocks: preset.blocks.where((b) => b.id != block.id).toList(),
          ),
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
