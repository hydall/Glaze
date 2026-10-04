import '../../core/llm/studio_controller_ontology.dart';
import '../../core/models/studio_config.dart';
import '../../core/models/studio_preset_block_groups.dart';

/// Toggles a Studio agent on/off in [preset], cascading dependency rules.
///
/// Locked-on agents (e.g. the final responder) are immutable. Disabling an
/// agent that others depend on (`requiresSpecId`) also disables the dependents,
/// remembering their prior state in [StudioPreset.agentEnabledBeforeDependencyOff]
/// so re-enabling the requirement restores them.
///
/// When a controller has a macro-block (`{{studio_<specId>_brief}}`) and a
/// list of alternative block IDs in
/// [StudioPreset.controllerAlternativeBlockIds], toggling the controller
/// manages those blocks with a radio-button semantic:
/// - ON: the macro-block is enabled; the currently-enabled alternative blocks
///   are saved in [StudioPreset.agentBlockRestoreState] and then disabled.
///   Blocks NOT in the alternative list (add-ons) are left untouched.
/// - OFF: the macro-block is disabled and the saved alternatives are restored.
StudioPreset applyStudioAgentToggle(
  StudioPreset preset,
  String specId,
  bool enabled,
) {
  final spec = StudioControllerOntology.specs
      .where((s) => s.id == specId)
      .firstOrNull;
  if (spec == null || spec.lockedOn) return preset;
  final updated = Map<String, bool>.from(preset.agentEnabled)
    ..[specId] = enabled;
  final restored = Map<String, bool>.from(
    preset.agentEnabledBeforeDependencyOff,
  );

  if (!enabled) {
    for (final s in StudioControllerOntology.specs) {
      if (s.requiresSpecId == specId) {
        restored[s.id] = updated[s.id] ?? true;
        updated[s.id] = false;
      }
    }
  } else {
    for (final s in StudioControllerOntology.specs) {
      if (s.requiresSpecId == specId && restored.containsKey(s.id)) {
        updated[s.id] = restored[s.id]!;
        restored.remove(s.id);
      }
    }
  }

  // Controller radio-folder: manage the macro-block and its alternatives.
  var blocks = preset.blocks;
  final restoreState = Map<String, List<String>>.from(
    preset.agentBlockRestoreState,
  );

  final macroBlock = findControllerMacroBlock(blocks, specId);
  if (macroBlock != null) {
    final alternativeIds =
        preset.controllerAlternativeBlockIds[specId] ?? const <String>[];

    if (enabled) {
      // Save which alternatives are currently enabled, then disable them.
      final saved = <String>[];
      for (final altId in alternativeIds) {
        final alt = blocks.where((b) => b.id == altId).firstOrNull;
        if (alt != null && alt.enabled && altId != macroBlock.id) {
          saved.add(altId);
        }
      }
      if (saved.isNotEmpty) {
        restoreState[specId] = saved;
      }
      blocks = blocks
          .map(
            (block) {
              if (block.id == macroBlock.id) {
                return block.copyWith(enabled: true);
              }
              if (alternativeIds.contains(block.id)) {
                return block.copyWith(enabled: false);
              }
              return block;
            },
          )
          .toList(growable: false);
    } else {
      // Disable the macro-block and restore the saved alternatives.
      blocks = blocks
          .map(
            (block) => block.id == macroBlock.id
                ? block.copyWith(enabled: false)
                : block,
          )
          .toList(growable: false);
      final savedIds = restoreState.remove(specId);
      if (savedIds != null) {
        blocks = blocks
            .map(
              (block) => savedIds.contains(block.id)
                  ? block.copyWith(enabled: true)
                  : block,
            )
            .toList(growable: false);
      }
    }
  }

  return preset.copyWith(
    agentEnabled: updated,
    agentEnabledBeforeDependencyOff: restored,
    blocks: blocks,
    agentBlockRestoreState: restoreState,
  );
}
