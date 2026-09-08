import 'studio_config.dart';

/// One visual row in the Studio preset editor: either a standalone block or
/// an authored section header with the blocks that follow it.
class StudioPresetBlockGroup {
  final StudioPresetBlock? standalone;
  final StudioPresetBlock? header;
  final StudioPresetBlock? openingBoundary;
  final StudioPresetBlock? closingBoundary;
  final List<StudioPresetBlock> children;
  final bool exclusive;

  const StudioPresetBlockGroup._({
    this.standalone,
    this.header,
    this.openingBoundary,
    this.closingBoundary,
    this.children = const [],
    this.exclusive = false,
  });

  const StudioPresetBlockGroup.standalone(StudioPresetBlock block)
    : this._(standalone: block);

  const StudioPresetBlockGroup.section({
    required StudioPresetBlock header,
    StudioPresetBlock? openingBoundary,
    StudioPresetBlock? closingBoundary,
    required List<StudioPresetBlock> children,
    required bool exclusive,
  }) : this._(
         header: header,
         openingBoundary: openingBoundary,
         closingBoundary: closingBoundary,
         children: children,
         exclusive: exclusive,
       );
}

const _exclusiveStudioHeaders = <String>{
  'directives (pick one)',
  'lumia definition',
  'point-of-view',
  'tense',
  'narrative styles',
  'story difficulty',
  'response length controls',
  'cot selections',
};

const _narrativeStyleAddonTitles = <String>{
  'bratty ass narrative',
  'doujinshi narrative',
  'emotional deflections',
};

bool isStudioPresetGroupHeader(StudioPresetBlock block) =>
    block.title.trimLeft().startsWith('━');

final _leadingGroupTags = RegExp(
  r'^\s*(?:(</[A-Za-z][\w-]*>)\s*)?(?:(<[A-Za-z][\w-]*>)\s*)?',
);
final _standaloneClosingTag = RegExp(r'^\s*</[A-Za-z][\w-]*>\s*$');

/// Converts legacy Loom boundaries, where each header closes the previous
/// section and opens its own, into explicit system blocks owned by the group.
List<StudioPresetBlock> normalizeStudioGroupBoundaries(
  List<StudioPresetBlock> blocks,
) {
  if (blocks.any(
    (block) => block.kind == 'group_open' || block.kind == 'group_close',
  )) {
    return blocks;
  }

  final sorted = [...blocks]..sort((a, b) => a.order.compareTo(b.order));
  final output = <StudioPresetBlock>[];
  String? pendingClose;
  String? previousHeaderId;
  String? previousHeaderSection;

  for (final block in sorted) {
    if (!isStudioPresetGroupHeader(block)) {
      output.add(block);
      continue;
    }

    final match = _leadingGroupTags.firstMatch(block.content);
    final previousClose = match?.group(1);
    final ownOpen = match?.group(2);
    final content = match == null
        ? block.content
        : block.content.substring(match.end).trimLeft();

    if (previousClose != null && previousHeaderId == null) {
      output.add(
        StudioPresetBlock(
          id: '${block.id}_prefix_close',
          title: 'Previous section closing tag',
          kind: 'group_close',
          role: 'system',
          content: previousClose,
          section: block.section,
        ),
      );
    } else if (previousClose != null && previousHeaderId != null) {
      output.add(
        StudioPresetBlock(
          id: '${previousHeaderId}_group_close',
          title: 'Closing tag',
          kind: 'group_close',
          role: 'system',
          content: pendingClose ?? previousClose,
          section: previousHeaderSection ?? block.section,
        ),
      );
    }
    if (ownOpen != null) {
      output.add(
        StudioPresetBlock(
          id: '${block.id}_group_open',
          title: 'Opening tag',
          kind: 'group_open',
          role: 'system',
          content: ownOpen,
          section: block.section,
        ),
      );
      pendingClose = '</${ownOpen.substring(1, ownOpen.length - 1)}>';
    }
    output.add(block.copyWith(content: content));
    previousHeaderId = block.id;
    previousHeaderSection = block.section;
  }

  if (pendingClose != null && previousHeaderId != null) {
    final existingClose = output.lastOrNull;
    if (existingClose != null &&
        existingClose != output.first &&
        _standaloneClosingTag.hasMatch(existingClose.content)) {
      output[output.length - 1] = existingClose.copyWith(
        id: '${previousHeaderId}_group_close',
        title: 'Closing tag',
        kind: 'group_close',
        role: 'system',
        content: pendingClose,
      );
    } else {
      output.add(
        StudioPresetBlock(
          id: '${previousHeaderId}_group_close',
          title: 'Closing tag',
          kind: 'group_close',
          role: 'system',
          content: pendingClose,
          section: output.last.section,
        ),
      );
    }
  }

  return [
    for (var index = 0; index < output.length; index++)
      output[index].copyWith(order: index),
  ];
}

/// Groups the flat runtime block list for presentation only. Authored Loom
/// header blocks define group boundaries, so no extra DB metadata is needed.
List<StudioPresetBlockGroup> groupStudioPresetBlocks(
  List<StudioPresetBlock> blocks,
) {
  final sorted = [...blocks]..sort((a, b) => a.order.compareTo(b.order));
  final boundaries = {
    for (final block in sorted)
      if (block.kind == 'group_open' || block.kind == 'group_close')
        block.id: block,
  };
  final result = <StudioPresetBlockGroup>[];
  StudioPresetBlock? header;
  var children = <StudioPresetBlock>[];

  void flush() {
    final current = header;
    if (current == null) return;
    final isNarrativeStyles =
        _normalizedHeaderTitle(current.title) == 'narrative styles';
    final groupedChildren = isNarrativeStyles
        ? children
              .where(
                (block) => !_narrativeStyleAddonTitles.contains(
                  block.title.trim().toLowerCase(),
                ),
              )
              .toList(growable: false)
        : children;
    result.add(
      StudioPresetBlockGroup.section(
        header: current,
        openingBoundary: boundaries['${current.id}_group_open'],
        closingBoundary: boundaries['${current.id}_group_close'],
        children: List.unmodifiable(groupedChildren),
        exclusive: _isExclusiveHeader(current.title),
      ),
    );
    if (isNarrativeStyles) {
      for (final child in children) {
        if (_narrativeStyleAddonTitles.contains(
          child.title.trim().toLowerCase(),
        )) {
          result.add(StudioPresetBlockGroup.standalone(child));
        }
      }
    }
    header = null;
    children = <StudioPresetBlock>[];
  }

  for (final block in sorted) {
    if (block.kind == 'group_open' || block.kind == 'group_close') continue;
    final startsTenseSubgroup =
        header != null &&
        _isPointOfViewHeader(header!.title) &&
        block.title.toLowerCase().contains('tense modifier');
    if (startsTenseSubgroup) {
      flush();
      header = StudioPresetBlock(
        id: '${block.id}_group',
        title: 'Tense',
        section: block.section,
        order: block.order,
      );
    }
    if (isStudioPresetGroupHeader(block)) {
      flush();
      header = block;
    } else if (header != null) {
      children.add(block);
    } else {
      result.add(StudioPresetBlockGroup.standalone(block));
    }
  }
  flush();
  return result;
}

/// Enables [selectedId] and disables every sibling in an exclusive group.
List<StudioPresetBlock> selectExclusiveStudioBlock(
  List<StudioPresetBlock> blocks,
  StudioPresetBlockGroup group,
  String selectedId,
) {
  if (!group.exclusive) return blocks;
  final ids = group.children.map((block) => block.id).toSet();
  if (!ids.contains(selectedId)) return blocks;
  if (group.children.any(
    (block) => block.locked && block.enabled && block.id != selectedId,
  )) {
    return blocks;
  }
  return blocks
      .map(
        (block) => ids.contains(block.id)
            ? block.copyWith(enabled: block.id == selectedId)
            : block,
      )
      .toList(growable: false);
}

/// Replaces a block and preserves the one-enabled invariant of its visual
/// exclusive group, regardless of whether the change came from the dropdown,
/// switch, or full block editor.
List<StudioPresetBlock> updateStudioPresetBlockRespectingGroups(
  List<StudioPresetBlock> blocks,
  StudioPresetBlock updated,
) {
  final existing = blocks.where((block) => block.id == updated.id).firstOrNull;
  if (existing?.locked == true && !updated.enabled) {
    updated = updated.copyWith(enabled: true);
  }
  var result = blocks
      .map((block) => block.id == updated.id ? updated : block)
      .toList(growable: false);
  if (!updated.enabled) return result;
  for (final group in groupStudioPresetBlocks(result)) {
    if (group.exclusive &&
        group.children.any((block) => block.id == updated.id)) {
      result = selectExclusiveStudioBlock(result, group, updated.id);
      break;
    }
  }
  return result;
}

bool _isPointOfViewHeader(String title) =>
    title.toLowerCase().contains('point-of-view');

bool _isExclusiveHeader(String title) {
  return _exclusiveStudioHeaders.contains(_normalizedHeaderTitle(title));
}

String _normalizedHeaderTitle(String title) {
  return title
      .replaceFirst(RegExp(r'^━[^\p{L}\p{N}]*', unicode: true), '')
      .trim()
      .toLowerCase();
}
