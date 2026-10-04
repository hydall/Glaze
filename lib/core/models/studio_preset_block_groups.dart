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
  'text formatting',
  'cot selections',
};

final _studioBriefMacro = RegExp(r'\{\{studio_(\w+)_briefs?\}\}');

const _independentNarrativeStyleTitles = <String>{
  'bratty ass narrative',
  'doujinshi narrative',
  'emotional deflections',
};

bool isStudioPresetGroupHeader(StudioPresetBlock block) =>
    block.title.trimLeft().startsWith('━');

/// A structural group boundary — detected by the transient `kind` synthesized in
/// [normalizeStudioGroupBoundaries] or by the persisted `groupBoundary` field
/// after the §5 migration cleared `kind`.
bool isStudioGroupOpen(StudioPresetBlock block) =>
    block.groupBoundary == 'open' || block.id.endsWith('_group_open');

bool isStudioGroupClose(StudioPresetBlock block) =>
    block.groupBoundary == 'close' ||
    block.id.endsWith('_group_close') ||
    block.id.endsWith('_prefix_close');

bool isStudioGroupBoundary(StudioPresetBlock block) =>
    isStudioGroupOpen(block) || isStudioGroupClose(block);

final _leadingGroupTags = RegExp(
  r'^\s*(?:(</[A-Za-z][\w-]*>)\s*)?(?:(<[A-Za-z][\w-]*>)\s*)?',
);
final _standaloneClosingTag = RegExp(r'^\s*</[A-Za-z][\w-]*>\s*$');

/// Converts legacy Loom boundaries, where each header closes the previous
/// section and opens its own, into explicit system blocks owned by the group.
List<StudioPresetBlock> normalizeStudioGroupBoundaries(
  List<StudioPresetBlock> blocks,
) {
  if (blocks.any(isStudioGroupBoundary)) {
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
        role: 'system',
        content: pendingClose,
      );
    } else {
      output.add(
        StudioPresetBlock(
          id: '${previousHeaderId}_group_close',
          title: 'Closing tag',
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
/// header blocks and explicit closing boundaries define group spans, so no
/// extra DB metadata is needed.
List<StudioPresetBlockGroup> groupStudioPresetBlocks(
  List<StudioPresetBlock> blocks,
) {
  final sorted = [...blocks]..sort((a, b) => a.order.compareTo(b.order));
  final boundaries = {
    for (final block in sorted)
      if (isStudioGroupBoundary(block)) block.id: block,
  };
  final result = <StudioPresetBlockGroup>[];
  StudioPresetBlock? header;
  var children = <StudioPresetBlock>[];

  void flush() {
    final current = header;
    if (current == null) return;
    result.add(
      StudioPresetBlockGroup.section(
        header: current,
        openingBoundary: boundaries['${current.id}_group_open'],
        closingBoundary: boundaries['${current.id}_group_close'],
        children: List.unmodifiable(children),
        exclusive: _isExclusiveHeader(current.title),
      ),
    );
    header = null;
    children = <StudioPresetBlock>[];
  }

  for (final block in sorted) {
    if (isStudioGroupClose(block)) {
      flush();
      continue;
    }
    if (isStudioGroupOpen(block)) continue;
    // Stored block order can interleave stages after older routing repairs.
    // A visual group belongs to exactly one injection point; never let an
    // exclusive `final` group swallow adjacent cleaner/ledger blocks.
    if (header != null && block.injectionPoint != header!.injectionPoint) {
      flush();
    }
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
        injectionPoint: block.injectionPoint,
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

/// Enables or disables a visual group while preserving all child selections.
List<StudioPresetBlock> toggleStudioPresetBlockGroup(
  List<StudioPresetBlock> blocks,
  StudioPresetBlockGroup group,
  bool enabled,
) {
  final headerId = group.header?.id;
  if (headerId == null) return blocks;
  return blocks
      .map(
        (block) =>
            block.id == headerId ? block.copyWith(enabled: enabled) : block,
      )
      .toList(growable: false);
}

bool isIndependentStudioGroupChild(
  StudioPresetBlockGroup group,
  StudioPresetBlock block,
) {
  return _normalizedHeaderTitle(group.header?.title ?? '') ==
          'narrative styles' &&
      _independentNarrativeStyleTitles.contains(
        block.title.trim().toLowerCase(),
      );
}

/// Applies folder enablement and folds structural boundary rows into the
/// authored blocks they wrap.
List<StudioPresetBlock> resolveEnabledStudioPresetBlocks(
  List<StudioPresetBlock> blocks,
) {
  final sorted = [...blocks]..sort((a, b) => a.order.compareTo(b.order));
  final output = <StudioPresetBlock>[];
  String? pendingOpen;
  int? groupStart;
  var groupEnabled = true;

  for (final block in sorted) {
    if (isStudioGroupOpen(block)) {
      pendingOpen = block.content.trim();
      continue;
    }
    if (isStudioGroupClose(block)) {
      final start = groupStart;
      if (groupEnabled && start != null) {
        for (var index = output.length - 1; index >= start; index--) {
          if (!output[index].enabled) continue;
          output[index] = output[index].copyWith(
            content: _joinStudioBoundary(output[index].content, block.content),
          );
          break;
        }
      } else if (start == null && output.isNotEmpty) {
        output[output.length - 1] = output.last.copyWith(
          content: _joinStudioBoundary(output.last.content, block.content),
        );
      }
      pendingOpen = null;
      groupStart = null;
      groupEnabled = true;
      continue;
    }

    if (isStudioPresetGroupHeader(block)) {
      groupEnabled = block.enabled;
      groupStart = output.length;
      if (groupEnabled) {
        final opening = pendingOpen;
        output.add(
          opening == null || opening.isEmpty
              ? block
              : block.copyWith(
                  content: _joinStudioBoundary(opening, block.content),
                ),
        );
      }
      pendingOpen = null;
      continue;
    }

    if (groupStart != null && !groupEnabled) continue;
    if (block.enabled) output.add(block);
  }

  return output;
}

String _joinStudioBoundary(String first, String second) {
  final left = first.trim();
  final right = second.trim();
  if (left.isEmpty) return right;
  if (right.isEmpty) return left;
  return '$left\n$right';
}

/// Enables [selectedId] and disables every sibling in an exclusive group.
List<StudioPresetBlock> selectExclusiveStudioBlock(
  List<StudioPresetBlock> blocks,
  StudioPresetBlockGroup group,
  String selectedId,
) {
  if (!group.exclusive) return blocks;
  final ids = group.children
      .where((block) => !isIndependentStudioGroupChild(group, block))
      .map((block) => block.id)
      .toSet();
  if (!ids.contains(selectedId)) return blocks;
  if (group.children.any(
    (block) =>
        ids.contains(block.id) &&
        block.locked &&
        block.enabled &&
        block.id != selectedId,
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

/// Finds the macro block for a controller spec by looking for the
/// `{{studio_<specId>_brief}}` macro in block content.
StudioPresetBlock? findControllerMacroBlock(
  List<StudioPresetBlock> blocks,
  String specId,
) {
  final macro = '{{studio_${specId}_brief}}';
  final macroPlural = '{{studio_${specId}_briefs}}';
  for (final block in blocks) {
    if (block.content.contains(macro) || block.content.contains(macroPlural)) {
      return block;
    }
  }
  return null;
}

/// Finds the [StudioPresetBlockGroup] that contains [blockId], or `null` if
/// the block is standalone or not found.
StudioPresetBlockGroup? findGroupForBlock(
  List<StudioPresetBlock> blocks,
  String blockId,
) {
  for (final group in groupStudioPresetBlocks(blocks)) {
    if (group.standalone?.id == blockId) return group;
    if (group.children.any((block) => block.id == blockId)) return group;
  }
  return null;
}

/// Returns the id of the currently enabled child in [group], or `null` if
/// none is enabled. Excludes independent children.
String? enabledChildInGroup(StudioPresetBlockGroup group) {
  for (final block in group.children) {
    if (isIndependentStudioGroupChild(group, block)) continue;
    if (block.enabled) return block.id;
  }
  return null;
}

/// The controller specId whose macro block this block carries, or `null`.
/// A macro block contains `{{studio_<specId>_brief}}` or
/// `{{studio_<specId>_briefs}}` in its content.
String? controllerSpecIdForMacroBlock(StudioPresetBlock block) {
  final m = _studioBriefMacro.firstMatch(block.content);
  return m?.group(1);
}

/// The controller specId for which [blockId] is listed as an alternative,
/// or `null`. Checks [StudioPreset.controllerAlternativeBlockIds].
String? controllerSpecIdForAlternativeBlock(
  StudioPreset preset,
  String blockId,
) {
  for (final entry in preset.controllerAlternativeBlockIds.entries) {
    if (entry.value.contains(blockId)) return entry.key;
  }
  return null;
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
        !isIndependentStudioGroupChild(group, updated) &&
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
