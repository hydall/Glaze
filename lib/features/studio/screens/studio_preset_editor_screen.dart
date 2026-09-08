import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_preset_block_groups.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../widgets/studio_block_editor_dialog.dart';
import '../widgets/studio_preset_group_tile.dart';

/// Screen for editing a [StudioPreset] — its blocks grouped by section.
///
/// Shows all blocks in a section-tabbed view. Each block row shows title,
/// kind, role, order, enabled toggle. Tap to edit; long-press to delete.
/// Add new blocks via FAB. Changes are persisted to DB on every edit.
class StudioPresetEditorScreen extends ConsumerStatefulWidget {
  final String presetId;

  const StudioPresetEditorScreen({super.key, required this.presetId});

  @override
  ConsumerState<StudioPresetEditorScreen> createState() =>
      _StudioPresetEditorScreenState();
}

class _StudioPresetEditorScreenState
    extends ConsumerState<StudioPresetEditorScreen> {
  StudioPreset? _preset;
  bool _loading = true;
  String _activeSection = 'pregen';

  static const _sections = [
    'pregen',
    'final',
    'cleaner',
    'ledger',
    'build',
    'brief_parser',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(studioPresetRepoProvider);
    final preset = await repo.getById(widget.presetId);
    if (!mounted) return;
    setState(() {
      _preset = preset;
      _loading = false;
    });
  }

  Future<void> _save(StudioPreset preset) async {
    final repo = ref.read(studioPresetRepoProvider);
    await repo.upsert(preset);
    setState(() => _preset = preset);
  }

  List<StudioPresetBlock> get _sectionBlocks {
    final blocks = _preset?.blocks ?? const <StudioPresetBlock>[];
    return blocks.where((b) => b.section == _activeSection).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  List<StudioPresetBlockGroup> get _sectionItems =>
      groupStudioPresetBlocks(_sectionBlocks);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _preset?.name.isNotEmpty == true
              ? _preset!.name
              : 'Studio Preset Editor',
        ),
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _preset == null
          ? const Center(child: Text('Preset not found'))
          : Column(
              children: [
                _buildSectionTabs(),
                Expanded(
                  child: _sectionBlocks.isEmpty
                      ? const Center(child: Text('No blocks in this section'))
                      : ListView.builder(
                          itemCount: _sectionItems.length,
                          itemBuilder: (context, index) {
                            final item = _sectionItems[index];
                            if (item.header != null) {
                              return StudioPresetGroupTile(
                                group: item,
                                onSelectExclusive: (id) =>
                                    _selectExclusiveBlock(item, id),
                                onToggle: _toggleBlock,
                                onEdit: _editBlock,
                                onDelete: _deleteBlock,
                              );
                            }
                            return _buildBlockTile(item.standalone!);
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: _loading || _preset == null
          ? null
          : FloatingActionButton(
              onPressed: _addBlock,
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildSectionTabs() {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: _sections.map((section) {
          final isActive = section == _activeSection;
          final count = (_preset?.blocks ?? const <StudioPresetBlock>[])
              .where((b) => b.section == section)
              .length;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: FilterChip(
              label: Text('$section ($count)'),
              selected: isActive,
              onSelected: (_) => setState(() => _activeSection = section),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBlockTile(StudioPresetBlock block) {
    return ListTile(
      title: Text(
        block.title.isNotEmpty ? block.title : block.id,
        style: block.enabled
            ? null
            : const TextStyle(decoration: TextDecoration.lineThrough),
      ),
      subtitle: Text(
        '${block.kind} · ${block.role} · order=${block.order}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Switch(
        value: block.enabled,
        onChanged: (v) => _toggleBlock(block, v),
      ),
      onTap: () => _editBlock(block),
      onLongPress: () => _deleteBlock(block),
    );
  }

  Future<void> _addBlock() async {
    final newBlock = StudioPresetBlock(
      id: 'block_${DateTime.now().millisecondsSinceEpoch}',
      title: 'New Block',
      section: _activeSection,
      order: _sectionBlocks.length,
    );
    final result = await showModalBottomSheet<StudioPresetBlock>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StudioBlockEditorDialog(block: newBlock, isNew: true),
    );
    if (result == null || _preset == null) return;
    final updated = _preset!.copyWith(blocks: [..._preset!.blocks, result]);
    await _save(updated);
  }

  Future<void> _editBlock(StudioPresetBlock block) async {
    final result = await showModalBottomSheet<StudioPresetBlock>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StudioBlockEditorDialog(block: block),
    );
    if (result == null || _preset == null) return;
    final blocks = updateStudioPresetBlockRespectingGroups(
      _preset!.blocks,
      result,
    );
    await _save(_preset!.copyWith(blocks: blocks));
  }

  Future<void> _toggleBlock(StudioPresetBlock block, bool enabled) async {
    if (_preset == null || (block.locked && !enabled)) return;
    final blocks = updateStudioPresetBlockRespectingGroups(
      _preset!.blocks,
      block.copyWith(enabled: enabled),
    );
    await _save(_preset!.copyWith(blocks: blocks));
  }

  Future<void> _selectExclusiveBlock(
    StudioPresetBlockGroup group,
    String selectedId,
  ) async {
    if (_preset == null) return;
    await _save(
      _preset!.copyWith(
        blocks: selectExclusiveStudioBlock(_preset!.blocks, group, selectedId),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _deleteBlock(StudioPresetBlock block) async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'Delete Block',
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description:
            'Delete "${block.title.isNotEmpty ? block.title : block.id}"?',
      ),
      items: [
        BottomSheetItem(
          label: 'Delete',
          centered: true,
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'Cancel',
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true || _preset == null) return;
    final blocks = _preset!.blocks.where((b) => b.id != block.id).toList();
    await _save(_preset!.copyWith(blocks: blocks));
  }
}
