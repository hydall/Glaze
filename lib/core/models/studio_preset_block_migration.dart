/// One-way, idempotent migration of legacy [StudioPresetBlock]s (the old
/// `type` + `section` model) to the target model (`mode` + `injectionPoint` +
/// `targetAgentId`), per `STUDIO_UX_ANALYSIS.md` §5.
///
/// Applied at the single repo choke point ([StudioPresetRepo] normalization),
/// so it covers reads, writes, imports and the seeded default. Migrated blocks
/// have their `section` cleared, which makes the transform a no-op on re-run
/// (blocks the editor creates carry no `section`, so they are never re-derived
/// and their explicit `mode`/`injectionPoint` survive).
library;

import 'studio_config.dart';

/// Sections whose backing services were deleted — dead data (§5).
const _deadSections = {'build', 'brief_parser'};

/// One-time repair shim: built-in blocks whose routing was lost by the
/// canonical codec shipped in nightly #197 (which did not read
/// `injectionPoint` from JSON, defaulting every block to `pregen`). Once the
/// v104 DB migration has persisted the repair for all users, this map and its
/// helpers can be removed — the codec fix in [StudioPresetCodec._block] is the
/// permanent fix. Keep this list exact: arbitrary user blocks must remain
/// movable between stages even when their titles happen to look built-in.
const _canonicalInjectionPoints = <String, String>{
  'final_agent_instruction': 'final',
  'previous_agents': 'final',
  'final_studio_brief_macros': 'final',
  'final_response_shape_contract': 'final',
  'final_jailbreak': 'final',
  'final_narrative_engine': 'final',
  'final_main_prompt': 'final',
  'final_language_pov': 'final',
  'final_prose_style': 'final',
  'final_prose_style_anime': 'final',
  'final_prose_style_ao3': 'final',
  'final_prose_style_universal': 'final',
  'final_genre': 'final',
  'final_user_autonomy': 'final',
  'final_story_mode': 'final',
  'final_lumia_ooc': 'final',
  'cleaner_jailbreak': 'cleaner',
  'cleaner_system': 'cleaner',
  'cleaner_aiism': 'cleaner',
  'cleaner_audit': 'cleaner',
  'cleaner_rules': 'cleaner',
  'cleaner_beauty': 'cleaner',
  'ledger_system': 'ledger',
  'ledger_reconciliation_prompt': 'ledger',
};

bool _hasBrokenCanonicalRouting(StudioPresetBlock block) {
  final expected = _canonicalInjectionPoints[block.id];
  return expected != null && block.injectionPoint != expected;
}

StudioPresetBlock _repairCanonicalRouting(StudioPresetBlock block) {
  final expected = _canonicalInjectionPoints[block.id];
  if (expected == null || block.injectionPoint == expected) return block;
  return block.copyWith(section: '', injectionPoint: expected);
}

/// The retired generic write-loop had no runtime consumer. Remove only its
/// canonical seed block; user-authored blocks remain untouched.
bool _isRetiredWriteLoop(StudioPresetBlock block) =>
    block.id == 'writeloop_system';

bool _isOrphanedBoundary(StudioPresetBlock block, Set<String> blockIds) {
  if (block.groupBoundary == 'none') return false;
  final suffix = block.groupBoundary == 'open' ? '_group_open' : '_group_close';
  if (!block.id.endsWith(suffix)) return true;
  final ownerId = block.id.substring(0, block.id.length - suffix.length);
  return !blockIds.contains(ownerId);
}

bool _isLumiaDefinition(StudioPresetBlock block) =>
    _normalizedTitle(block.title) == 'lumia definition';

bool _isLumiaModifiers(StudioPresetBlock block) =>
    _normalizedTitle(block.title) == 'lumia modifiers';

String _normalizedTitle(String title) => title
    .replaceFirst(RegExp(r'^━[^\p{L}\p{N}]*', unicode: true), '')
    .trim()
    .toLowerCase();

/// Older Loom imports split Lumia's one prompt envelope into Definition and
/// Modifiers sections. Collapse the pair into one header while preserving every
/// selectable child block and the Definition section's boundary ownership.
List<StudioPresetBlock> _mergeLumiaSections(List<StudioPresetBlock> blocks) {
  final sorted = [...blocks]..sort((a, b) => a.order.compareTo(b.order));
  final definitionIndex = sorted.indexWhere(_isLumiaDefinition);
  if (definitionIndex < 0) return blocks;
  final modifiersIndex = sorted.indexWhere(
    _isLumiaModifiers,
    definitionIndex + 1,
  );
  if (modifiersIndex < 0) return blocks;

  final definition = sorted[definitionIndex];
  final modifiers = sorted[modifiersIndex];
  final modifierCloseId = '${modifiers.id}_group_close';
  final definitionCloseId = '${definition.id}_group_close';
  final closingBoundary = sorted
      .where(
        (block) => block.id == modifierCloseId || block.id == definitionCloseId,
      )
      .lastOrNull;
  final merged = <StudioPresetBlock>[];

  for (final block in sorted) {
    if (block.id == modifiers.id ||
        block.id == '${modifiers.id}_group_open' ||
        block.id == modifierCloseId) {
      continue;
    }
    if (block.id == definition.id) {
      merged.add(block.copyWith(title: '━ Lumia'));
      continue;
    }
    if (block.id == definitionCloseId) {
      continue;
    }
    merged.add(block);
  }

  if (closingBoundary != null) {
    merged.add(closingBoundary.copyWith(id: definitionCloseId));
  }
  return [
    for (var index = 0; index < merged.length; index++)
      merged[index].copyWith(order: index),
  ];
}

/// True if any block still carries a legacy `section` (the migration signal).
bool studioPresetBlocksNeedMigration(List<StudioPresetBlock> blocks) =>
    blocks.any((b) => b.section.isNotEmpty);

/// Migrates [blocks] to the target model. Returns the same list instance when
/// nothing needs migrating.
List<StudioPresetBlock> migrateStudioPresetBlocksToV2(
  List<StudioPresetBlock> blocks,
) {
  final hasRetiredWriteLoop = blocks.any(_isRetiredWriteLoop);
  final ids = blocks.map((block) => block.id).toSet();
  final hasOrphanedBoundary = blocks.any(
    (block) => _isOrphanedBoundary(block, ids),
  );
  final hasSplitLumia =
      blocks.any(_isLumiaDefinition) && blocks.any(_isLumiaModifiers);
  final hasBrokenCanonicalRouting = blocks.any(_hasBrokenCanonicalRouting);
  if (!studioPresetBlocksNeedMigration(blocks) &&
      !hasRetiredWriteLoop &&
      !hasOrphanedBoundary &&
      !hasSplitLumia &&
      !hasBrokenCanonicalRouting) {
    return blocks;
  }
  final out = <StudioPresetBlock>[];
  for (final b in blocks) {
    if (_isRetiredWriteLoop(b)) continue;
    if (_isOrphanedBoundary(b, ids)) continue;
    if (b.section.isEmpty) {
      out.add(
        _repairCanonicalRouting(b),
      ); // already migrated / editor-created — preserve as-is.
      continue;
    }
    if (_deadSections.contains(b.section)) continue;
    out.add(_repairCanonicalRouting(_migrateBlock(b)));
  }
  return _mergeLumiaSections(out);
}

StudioPresetBlock _migrateBlock(StudioPresetBlock b) {
  // section → injectionPoint (1:1); default 'pregen'.
  final injection = switch (b.section) {
    'final' => 'final',
    'cleaner' => 'cleaner',
    'ledger' => 'ledger',
    _ => 'pregen',
  };
  // Group boundary by id suffix (synthesize from normalizeStudioGroupBoundaries).
  if (b.id.endsWith('_group_open')) {
    return b.copyWith(
      groupBoundary: 'open',
      mode: '',
      injectionPoint: injection,
      section: '',
    );
  }
  if (b.id.endsWith('_group_close') || b.id.endsWith('_prefix_close')) {
    return b.copyWith(
      groupBoundary: 'close',
      mode: '',
      injectionPoint: injection,
      section: '',
    );
  }
  switch (b.type) {
    case StudioBlockType.priorBriefs:
      return b.copyWith(
        mode: 'pregenBrief',
        injectionPoint: injection,
        section: '',
      );
    case StudioBlockType.context:
    case StudioBlockType.history:
      // Context slot: empty `mode` marks it for id-based resolution at
      // runtime; the id is already set to the canonical slot name.
      return b.copyWith(mode: '', injectionPoint: injection, section: '');
    case StudioBlockType.instruction:
      // Tracker instructions carry a targetAgentId (set by nightly #194);
      // route them to the specific agent. Regular instructions emit content.
      if (b.targetAgentId != null && b.targetAgentId!.isNotEmpty) {
        return b.copyWith(
          mode: 'direct',
          injectionPoint: 'specificAgent',
          section: '',
        );
      }
      return b.copyWith(mode: 'direct', injectionPoint: injection, section: '');
  }
}
