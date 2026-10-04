/// Folders inside one chat preset.
///
/// A folder is declared data — `Preset.blockFolders` lists them and a block
/// joins one by carrying its id in `PresetBlock.folderId`. Nothing is ever
/// inferred from a block's name or content, so a preset imported from another
/// frontend never grows folders on its own, and a Glaze preset read by another
/// frontend is still an ordinary flat block list with two keys it can ignore.
///
/// A folder comes in two kinds, declared the same way: the default checklist,
/// where every block toggles on its own, and the pick-one folder
/// (`exclusive`), where at most one of its blocks is enabled.
///
/// The flat block order stays authoritative for placement: a folder is drawn
/// where its first block sits, and a folder with no blocks yet is drawn after
/// the block rows.
library;

import 'preset.dart';

/// One row of the preset editor's block list: either a standalone block or a
/// folder with the blocks that belong to it.
class PresetBlockGroup {
  final PresetBlock? standalone;
  final PresetBlockFolder? folder;
  final List<PresetBlock> children;

  const PresetBlockGroup._({
    this.standalone,
    this.folder,
    this.children = const [],
  });

  const PresetBlockGroup.standalone(PresetBlock block)
    : this._(standalone: block);

  const PresetBlockGroup.folder({
    required PresetBlockFolder folder,
    required List<PresetBlock> children,
  }) : this._(folder: folder, children: children);

  bool get isFolder => folder != null;

  /// The enabled block of a pick-one folder, or null when nothing is picked.
  PresetBlock? get selected =>
      children.where((block) => block.enabled).firstOrNull;

  /// Every block the row owns, in emission order.
  List<PresetBlock> get blocks => folder == null ? [standalone!] : children;
}

/// Splits the editor's block list into rows. [blocks] is the list as shown —
/// the caller filters stashed blocks out first.
///
/// A block whose `folderId` names a folder the preset does not declare is
/// treated as top-level, so a hand-edited or partially imported JSON degrades
/// to a plain list instead of hiding blocks.
List<PresetBlockGroup> groupPresetBlocks(
  List<PresetBlock> blocks,
  List<PresetBlockFolder> folders,
) {
  if (folders.isEmpty) {
    return [for (final block in blocks) PresetBlockGroup.standalone(block)];
  }
  final byId = {for (final folder in folders) folder.id: folder};
  final rows = <PresetBlockGroup>[];
  final placed = <String>{};

  for (final block in blocks) {
    final folder = byId[block.folderId];
    if (folder == null) {
      rows.add(PresetBlockGroup.standalone(block));
      continue;
    }
    // The folder is drawn once, at its first block, and owns every block that
    // names it — even if a hand-written JSON interleaves them with others.
    if (!placed.add(folder.id)) continue;
    rows.add(
      PresetBlockGroup.folder(
        folder: folder,
        children: List.unmodifiable(
          blocks.where((b) => b.folderId == folder.id),
        ),
      ),
    );
  }

  // Folders that hold nothing yet have no place in the block order; they are
  // drawn after it, in declaration order, so a folder just created is visible.
  for (final folder in folders) {
    if (placed.contains(folder.id)) continue;
    rows.add(PresetBlockGroup.folder(folder: folder, children: const []));
  }
  return rows;
}

/// Flattens rows back into the block order they describe. A folder's blocks
/// come out contiguously, at the position the folder is drawn.
List<PresetBlock> flattenPresetBlockGroups(List<PresetBlockGroup> rows) => [
  for (final row in rows) ...row.blocks,
];

/// The folder [blockId] belongs to, or null when it is top-level.
PresetBlockFolder? findPresetFolderForBlock(
  List<PresetBlock> blocks,
  List<PresetBlockFolder> folders,
  String blockId,
) {
  final block = blocks.where((b) => b.id == blockId).firstOrNull;
  final folderId = block?.folderId;
  if (folderId == null) return null;
  return folders.where((f) => f.id == folderId).firstOrNull;
}

/// Enables or disables a folder. Block switches are left alone, so re-enabling
/// the folder restores the selection it had.
List<PresetBlockFolder> togglePresetBlockFolder(
  List<PresetBlockFolder> folders,
  String folderId,
  bool enabled,
) => [
  for (final folder in folders)
    folder.id == folderId ? folder.copyWith(enabled: enabled) : folder,
];

/// Renames a folder.
List<PresetBlockFolder> renamePresetBlockFolder(
  List<PresetBlockFolder> folders,
  String folderId,
  String name,
) => [
  for (final folder in folders)
    folder.id == folderId ? folder.copyWith(name: name.trim()) : folder,
];

/// Moves one block into [folder], placing it after the folder's last block (or
/// at the end of the list while the folder is still empty).
///
/// Joining a pick-one folder that already has its pick arrives disabled — the
/// one-enabled rule holds however a block gets in.
List<PresetBlock> movePresetBlockIntoFolder({
  required List<PresetBlock> blocks,
  required String blockId,
  required PresetBlockFolder folder,
}) {
  final source = blocks.where((block) => block.id == blockId).firstOrNull;
  if (source == null || source.folderId == folder.id) return blocks;

  final takesThePick =
      folder.exclusive &&
      blocks.any(
        (block) =>
            block.folderId == folder.id && block.enabled && block.id != blockId,
      );
  final next = [...blocks]..removeWhere((block) => block.id == blockId);
  final lastMember = next.lastIndexWhere(
    (block) => block.folderId == folder.id,
  );
  final insertAt = lastMember == -1 ? next.length : lastMember + 1;
  next.insert(
    insertAt,
    source.copyWith(
      folderId: folder.id,
      enabled: takesThePick ? false : source.enabled,
    ),
  );
  return next;
}

/// Enables [blockId] and disables every other block of its pick-one folder.
List<PresetBlock> selectExclusivePresetBlock({
  required List<PresetBlock> blocks,
  required String folderId,
  required String blockId,
}) => [
  for (final block in blocks)
    block.folderId == folderId
        ? block.copyWith(enabled: block.id == blockId)
        : block,
];

/// Switches a folder between checklist and pick-one. Turning pick-one on keeps
/// the first enabled block as the pick and disables the rest, so the folder is
/// never left with two.
({List<PresetBlockFolder> folders, List<PresetBlock> blocks})
setPresetFolderExclusive({
  required List<PresetBlockFolder> folders,
  required List<PresetBlock> blocks,
  required String folderId,
  required bool exclusive,
}) {
  final nextFolders = [
    for (final folder in folders)
      folder.id == folderId ? folder.copyWith(exclusive: exclusive) : folder,
  ];
  if (!exclusive) return (folders: nextFolders, blocks: blocks);

  final pick = blocks
      .where((block) => block.folderId == folderId && block.enabled)
      .firstOrNull;
  if (pick == null) return (folders: nextFolders, blocks: blocks);
  return (
    folders: nextFolders,
    blocks: selectExclusivePresetBlock(
      blocks: blocks,
      folderId: folderId,
      blockId: pick.id,
    ),
  );
}

/// Takes one block out of its folder. It keeps its place in the list, so the
/// row simply steps out of the folder it was drawn in.
List<PresetBlock> movePresetBlockOutOfFolder({
  required List<PresetBlock> blocks,
  required String blockId,
}) {
  final source = blocks.where((block) => block.id == blockId).firstOrNull;
  if (source == null || source.folderId == null) return blocks;
  return [
    for (final block in blocks)
      block.id == blockId ? block.copyWith(folderId: null) : block,
  ];
}

/// Drops a folder's membership: its blocks stay where they are and become
/// top-level rows.
List<PresetBlock> clearPresetFolderMembership(
  List<PresetBlock> blocks,
  String folderId,
) => [
  for (final block in blocks)
    block.folderId == folderId ? block.copyWith(folderId: null) : block,
];

/// Applies folder enablement to a flat block list: every block in a disabled
/// folder is reported as disabled, so prompt assembly and token accounting skip
/// it without folders having to be threaded through them. A block naming a
/// folder the preset does not declare is left alone.
List<PresetBlock> applyPresetFolderEnablement(
  List<PresetBlock> blocks,
  List<PresetBlockFolder> folders,
) {
  final disabled = {
    for (final folder in folders)
      if (!folder.enabled) folder.id,
  };
  if (disabled.isEmpty) return blocks;
  return [
    for (final block in blocks)
      block.enabled && disabled.contains(block.folderId)
          ? block.copyWith(enabled: false)
          : block,
  ];
}

/// The preset as prompt assembly sees it: folder enablement resolved into the
/// blocks' own `enabled` flags.
Preset resolvePresetFolders(Preset preset) {
  if (preset.blockFolders.isEmpty) return preset;
  return preset.copyWith(
    blocks: applyPresetFolderEnablement(preset.blocks, preset.blockFolders),
  );
}
