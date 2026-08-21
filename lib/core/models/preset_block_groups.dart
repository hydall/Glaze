/// Folders for chat presets, authored exactly the way an agentic preset
/// authors them: a block whose name starts with `━` opens a folder and owns
/// every block that follows it until the next header.
///
/// Nothing extra is persisted — the flat block order stays authoritative — so
/// an imported SillyTavern preset that already uses divider prompts gets its
/// folders for free, and a preset saved by an older build still loads.
library;

import 'preset.dart';

final _headerOrnament = RegExp(r'^━[^\p{L}\p{N}]*', unicode: true);

/// Whether [block] opens a folder. Stashed blocks are not part of the visible
/// list, so they never open one.
bool isPresetGroupHeader(PresetBlock block) =>
    !block.isStashed && block.name.trimLeft().startsWith('━');

/// The folder's display name — the header's name without its `━…` ornament.
String presetGroupTitle(PresetBlock header) {
  final title = header.name.replaceFirst(_headerOrnament, '').trim();
  return title.isEmpty ? header.name.trim() : title;
}

/// The header block name a folder named [name] is stored under.
String presetGroupHeaderName(String name) => '━ ${name.trim()}';

/// One row of the preset editor's block list: either a standalone block or a
/// folder header with the blocks it owns.
class PresetBlockGroup {
  final PresetBlock? standalone;
  final PresetBlock? header;
  final List<PresetBlock> children;

  const PresetBlockGroup._({
    this.standalone,
    this.header,
    this.children = const [],
  });

  const PresetBlockGroup.standalone(PresetBlock block)
    : this._(standalone: block);

  const PresetBlockGroup.folder({
    required PresetBlock header,
    required List<PresetBlock> children,
  }) : this._(header: header, children: children);

  bool get isFolder => header != null;

  /// Every block the row owns, in emission order.
  List<PresetBlock> get blocks => header == null
      ? [standalone!]
      : [header!, ...children];
}

/// Splits the editor's block list into rows. [blocks] is the list as shown —
/// the caller filters stashed blocks out first.
List<PresetBlockGroup> groupPresetBlocks(List<PresetBlock> blocks) {
  final rows = <PresetBlockGroup>[];
  PresetBlock? header;
  var children = <PresetBlock>[];

  void flush() {
    final current = header;
    if (current == null) return;
    rows.add(
      PresetBlockGroup.folder(
        header: current,
        children: List.unmodifiable(children),
      ),
    );
    header = null;
    children = <PresetBlock>[];
  }

  for (final block in blocks) {
    if (isPresetGroupHeader(block)) {
      flush();
      header = block;
    } else if (header != null) {
      children.add(block);
    } else {
      rows.add(PresetBlockGroup.standalone(block));
    }
  }
  flush();
  return rows;
}

/// Flattens rows back into the block order they describe.
List<PresetBlock> flattenPresetBlockGroups(List<PresetBlockGroup> rows) => [
  for (final row in rows) ...row.blocks,
];

/// The folder [blockId] currently sits in, or null when it is a standalone row
/// or a folder header itself.
PresetBlockGroup? findPresetGroupForBlock(
  List<PresetBlock> blocks,
  String blockId,
) {
  for (final row in groupPresetBlocks(blocks)) {
    if (row.children.any((block) => block.id == blockId)) return row;
  }
  return null;
}

/// Enables or disables a whole folder by flipping its header. Child switches
/// keep their own state, so re-enabling the folder restores the selection.
List<PresetBlock> togglePresetBlockGroup(
  List<PresetBlock> blocks,
  PresetBlockGroup group,
  bool enabled,
) {
  final headerId = group.header?.id;
  if (headerId == null) return blocks;
  return [
    for (final block in blocks)
      block.id == headerId ? block.copyWith(enabled: enabled) : block,
  ];
}

/// Moves one ordinary block to the end of [target]'s children. Headers never
/// move into a folder — nesting folders is not supported.
List<PresetBlock> movePresetBlockIntoGroup({
  required List<PresetBlock> blocks,
  required String blockId,
  required PresetBlockGroup target,
}) {
  final header = target.header;
  if (header == null || header.id == blockId) return blocks;
  final source = blocks.where((block) => block.id == blockId).firstOrNull;
  if (source == null || isPresetGroupHeader(source)) return blocks;
  if (target.children.any((block) => block.id == blockId)) return blocks;

  final next = [...blocks]..removeWhere((block) => block.id == blockId);
  var insertAt = next.indexWhere((block) => block.id == header.id);
  if (insertAt < 0) return blocks;
  insertAt++;
  while (insertAt < next.length && !isPresetGroupHeader(next[insertAt])) {
    insertAt++;
  }
  next.insert(insertAt, source);
  return next;
}

/// Takes one block out of its folder and appends it to the list as a
/// standalone row. A block that is not in a folder is left where it is.
List<PresetBlock> movePresetBlockOutOfGroups({
  required List<PresetBlock> blocks,
  required String blockId,
}) {
  final source = blocks.where((block) => block.id == blockId).firstOrNull;
  if (source == null || isPresetGroupHeader(source)) return blocks;
  if (findPresetGroupForBlock(blocks, blockId) == null) return blocks;
  return [
    ...blocks.where((block) => block.id != blockId),
    source,
  ];
}

/// Removes a folder while keeping its blocks: only the header is dropped, so
/// the children stay in place as standalone rows.
List<PresetBlock> dissolvePresetBlockGroup({
  required List<PresetBlock> blocks,
  required PresetBlockGroup group,
}) {
  final headerId = group.header?.id;
  if (headerId == null) return blocks;
  return [
    for (final block in blocks)
      if (block.id != headerId) block,
  ];
}

/// Applies folder enablement to a flat block list: every block owned by a
/// disabled folder is reported as disabled, so prompt assembly and token
/// accounting skip it without the folder state having to be threaded through
/// them. Stashed blocks are passed through untouched — they are already out of
/// the prompt, and a stashed block never opens a folder.
List<PresetBlock> applyPresetFolderEnablement(List<PresetBlock> blocks) {
  final resolved = <PresetBlock>[];
  var inFolder = false;
  var folderEnabled = true;

  for (final block in blocks) {
    if (block.isStashed) {
      resolved.add(block);
      continue;
    }
    if (isPresetGroupHeader(block)) {
      inFolder = true;
      folderEnabled = block.enabled;
      resolved.add(block);
      continue;
    }
    resolved.add(
      inFolder && !folderEnabled && block.enabled
          ? block.copyWith(enabled: false)
          : block,
    );
  }
  return resolved;
}
