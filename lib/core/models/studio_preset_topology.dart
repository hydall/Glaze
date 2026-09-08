import '../llm/studio/studio_brief_macro_renderer.dart';
import 'studio_config.dart';
import 'studio_preset_block_groups.dart';

/// Creates a local preset whose persisted blocks and controller toggles match
/// an execution topology. Runtime gating remains a second line of defence for
/// stale Studio agent rows; it does not own prompt content.
StudioPreset prepareStudioPresetForMode(
  StudioPreset source, {
  required String id,
  required String name,
  required StudioExecutionMode mode,
  required int updatedAt,
}) {
  const assistedTaskIds = {
    'continuity_task_universal',
    'narrative_task_universal',
    'beauty_task',
  };
  final allowedAgents = switch (mode) {
    StudioExecutionMode.legacy => null,
    StudioExecutionMode.direct => const {'final'},
    StudioExecutionMode.assisted => const {
      'continuity',
      'narrative',
      'beauty',
      'final',
    },
  };

  final agentEnabled = Map<String, bool>.from(source.agentEnabled);
  if (allowedAgents != null) {
    for (final specId in const {
      'continuity',
      'agency',
      'narrative',
      'dialogue',
      'guard',
      'world',
      'meta',
      'beauty',
      'final',
    }) {
      agentEnabled[specId] = allowedAgents.contains(specId);
    }
  }

  final blocks = <StudioPresetBlock>[];
  for (final block in source.blocks) {
    var candidate = block;
    if (mode == StudioExecutionMode.direct &&
        StudioBriefMacroRenderer.hasAnyStudioBriefMacro(block.content)) {
      final content = StudioBriefMacroRenderer.stripStudioBriefMacros(
        block.content,
      );
      if (content.trim().isEmpty) continue;
      candidate = block.copyWith(content: content);
    }
    if (candidate.kind == 'tracker_instruction') {
      if (mode == StudioExecutionMode.direct) continue;
      if (mode == StudioExecutionMode.assisted &&
          !assistedTaskIds.contains(block.id)) {
        continue;
      }
      if (mode == StudioExecutionMode.assisted) {
        candidate = candidate.copyWith(enabled: true);
      }
    }
    if (mode == StudioExecutionMode.direct && block.id == 'beauty_extractor') {
      blocks.add(candidate.copyWith(enabled: false));
    } else if (mode != StudioExecutionMode.legacy &&
        block.id == 'cleaner_beauty') {
      // Direct derives Beauty in post-cleaner. Assisted passes its pregen
      // Beauty brief into the same post-cleaner stage.
      blocks.add(candidate.copyWith(enabled: true));
    } else {
      blocks.add(candidate);
    }
  }

  return source.copyWith(
    id: id,
    name: name,
    blocks: mode == StudioExecutionMode.legacy
        ? blocks
        : normalizeStudioGroupBoundaries(blocks),
    agentEnabled: agentEnabled,
    executionMode: mode,
    updatedAt: updatedAt,
  );
}
