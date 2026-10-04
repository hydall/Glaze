import 'studio_config.dart';
import 'studio_preset_block_groups.dart';

/// One block row of the editor in its final on-screen position: the group it
/// renders and the section it now sits in. Dropping a row under a different
/// section header is how a block is re-targeted, so the injection point travels
/// with the placement rather than with the block it came from.
class StudioPresetRowPlacement {
  final StudioPresetBlockGroup entry;
  final String injectionPoint;

  const StudioPresetRowPlacement({
    required this.entry,
    required this.injectionPoint,
  });
}

/// Every block a dashboard row owns, in the order it must be emitted.
///
/// A section row carries its opening tag, header, children and closing tag as
/// one unit, so dragging a section moves — and re-targets — the whole thing.
List<StudioPresetBlock> studioPresetEntryBlocks(StudioPresetBlockGroup entry) {
  if (entry.header == null) return [entry.standalone!];
  return [
    ?entry.openingBoundary,
    entry.header!,
    ...entry.children,
    ?entry.closingBoundary,
  ];
}

/// Rewrites `order` — and `injectionPoint` where a row changed section — so the
/// preset's blocks follow the row order in [rows].
///
/// Only the slots currently held by those rows are permuted: any block the
/// grouper did not surface, such as an orphaned boundary tag, keeps the
/// position it already had, so a drag can never silently drop or relocate it.
/// Returns [all] unchanged when the rows and the slots they claim do not line
/// up.
List<StudioPresetBlock> reorderStudioPresetBlocks({
  required List<StudioPresetBlock> all,
  required List<StudioPresetRowPlacement> rows,
}) {
  final existingIds = {for (final block in all) block.id};
  final flattened = <StudioPresetBlock>[];
  for (final row in rows) {
    for (final block in studioPresetEntryBlocks(row.entry)) {
      // The grouper synthesizes a "Tense" header that has no stored block; it
      // owns no slot and must not enter the permutation.
      if (!existingIds.contains(block.id)) continue;
      flattened.add(
        block.injectionPoint == row.injectionPoint
            ? block
            : block.copyWith(injectionPoint: row.injectionPoint),
      );
    }
  }
  final movedIds = {for (final block in flattened) block.id};
  if (movedIds.length != flattened.length) return all;

  final sorted = [...all]..sort((a, b) => a.order.compareTo(b.order));
  final slots = <int>[
    for (var i = 0; i < sorted.length; i++)
      if (movedIds.contains(sorted[i].id)) i,
  ];
  if (slots.length != flattened.length) return all;

  for (var i = 0; i < slots.length; i++) {
    sorted[slots[i]] = flattened[i];
  }
  return [for (var i = 0; i < sorted.length; i++) sorted[i].copyWith(order: i)];
}

/// Moves one ordinary block to the end of [targetGroup]. The flat runtime order
/// remains authoritative: the block is inserted immediately before the
/// folder's closing boundary and adopts the folder's injection point.
List<StudioPresetBlock> moveStudioPresetBlockToGroup({
  required List<StudioPresetBlock> all,
  required String blockId,
  required StudioPresetBlockGroup targetGroup,
}) {
  final header = targetGroup.header;
  if (header == null || blockId == header.id) return all;
  final source = all.where((block) => block.id == blockId).firstOrNull;
  if (source == null ||
      isStudioPresetGroupHeader(source) ||
      isStudioGroupBoundary(source)) {
    return all;
  }
  if (targetGroup.children.any((block) => block.id == blockId)) return all;

  final sorted = [...all]..sort((a, b) => a.order.compareTo(b.order));
  sorted.removeWhere((block) => block.id == blockId);
  final closeId = targetGroup.closingBoundary?.id;
  var insertAt = closeId == null
      ? sorted.indexWhere((block) => block.id == header.id) + 1
      : sorted.indexWhere((block) => block.id == closeId);
  if (insertAt < 0) return all;
  if (closeId == null) {
    final childIds = targetGroup.children.map((block) => block.id).toSet();
    while (insertAt < sorted.length && childIds.contains(sorted[insertAt].id)) {
      insertAt++;
    }
  }
  sorted.insert(
    insertAt,
    source.copyWith(injectionPoint: header.injectionPoint),
  );
  return [
    for (var index = 0; index < sorted.length; index++)
      sorted[index].copyWith(order: index),
  ];
}

/// Removes an ordinary block from its folder and appends it to an injection
/// point as a standalone row.
List<StudioPresetBlock> moveStudioPresetBlockToSection({
  required List<StudioPresetBlock> all,
  required String blockId,
  required String injectionPoint,
}) {
  final source = all.where((block) => block.id == blockId).firstOrNull;
  if (source == null ||
      isStudioPresetGroupHeader(source) ||
      isStudioGroupBoundary(source)) {
    return all;
  }
  final currentGroup = groupStudioPresetBlocks(
    all
        .where((block) => block.injectionPoint == source.injectionPoint)
        .toList(),
  ).where((group) => group.children.any((block) => block.id == blockId));
  if (currentGroup.isEmpty && source.injectionPoint == injectionPoint) {
    return all;
  }

  final sorted = [...all]..sort((a, b) => a.order.compareTo(b.order));
  sorted.removeWhere((block) => block.id == blockId);
  sorted.add(source.copyWith(injectionPoint: injectionPoint));
  return [
    for (var index = 0; index < sorted.length; index++)
      sorted[index].copyWith(order: index),
  ];
}

/// Removes a folder's structural blocks while preserving its child prompts as
/// standalone rows in their current order.
List<StudioPresetBlock> dissolveStudioPresetBlockGroup({
  required List<StudioPresetBlock> all,
  required StudioPresetBlockGroup group,
}) {
  final header = group.header;
  if (header == null) return all;
  final removedIds = {
    header.id,
    ?group.openingBoundary?.id,
    ?group.closingBoundary?.id,
  };
  final remaining =
      all
          .where((block) => !removedIds.contains(block.id))
          .toList(growable: false)
        ..sort((a, b) => a.order.compareTo(b.order));
  return [
    for (var index = 0; index < remaining.length; index++)
      remaining[index].copyWith(order: index),
  ];
}
