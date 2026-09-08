import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_topology.dart';

void main() {
  const source = StudioPreset(
    id: 'source',
    name: 'Source',
    blocks: [
      StudioPresetBlock(
        id: 'continuity_task_universal',
        kind: 'tracker_instruction',
        content: 'Authored continuity task.',
      ),
      StudioPresetBlock(id: 'agency_task', kind: 'tracker_instruction'),
      StudioPresetBlock(
        id: 'narrative_task_universal',
        kind: 'tracker_instruction',
        content: 'Authored narrative task.',
      ),
      StudioPresetBlock(id: 'beauty_task', kind: 'tracker_instruction'),
      StudioPresetBlock(id: 'beauty_extractor', section: 'build'),
      StudioPresetBlock(
        id: 'cleaner_beauty',
        section: 'cleaner',
        enabled: false,
      ),
      StudioPresetBlock(
        id: 'optional_style',
        section: 'final',
        enabled: false,
        content: 'Optional authored style.',
      ),
      StudioPresetBlock(
        id: 'studio_briefs',
        section: 'final',
        content: '{{studio_continuity_brief}} {{studio_narrative_brief}}',
      ),
      StudioPresetBlock(
        id: 'mixed_briefs',
        section: 'final',
        content:
            'Keep this independent instruction.\n{{STUDIO_AGENT_BRIEFS}}\n'
            '{{studio_tracker_briefs}}',
      ),
      StudioPresetBlock(
        id: 'final_response_shape_contract',
        section: 'final',
        content: 'Authored final contract.',
      ),
    ],
  );

  test('direct preset has no pregen tasks and keeps cleaner beauty', () {
    final preset = prepareStudioPresetForMode(
      source,
      id: 'direct',
      name: 'Direct',
      mode: StudioExecutionMode.direct,
      updatedAt: 1,
    );

    expect(
      preset.blocks.where((b) => b.kind == 'tracker_instruction'),
      isEmpty,
    );
    expect(
      preset.blocks.any(
        (b) => b.content.toLowerCase().contains(
          RegExp(r'\{\{studio_.+_briefs?\}\}'),
        ),
      ),
      isFalse,
    );
    expect(
      preset.blocks.firstWhere((b) => b.id == 'mixed_briefs').content,
      'Keep this independent instruction.\n\n',
    );
    expect(
      preset.blocks.firstWhere((b) => b.id == 'beauty_extractor').enabled,
      isFalse,
    );
    expect(
      preset.blocks.firstWhere((b) => b.id == 'cleaner_beauty').enabled,
      isTrue,
    );
    expect(
      preset.blocks.firstWhere((b) => b.id == 'optional_style').enabled,
      isFalse,
    );
    expect(
      preset.blocks
          .firstWhere((b) => b.id == 'final_response_shape_contract')
          .content,
      'Authored final contract.',
    );
    expect(preset.agentEnabled['final'], isTrue);
    expect(preset.agentEnabled['continuity'], isFalse);
    expect(preset.agentEnabled['beauty'], isFalse);
  });

  test('assisted preset includes continuity, narrative, and beauty', () {
    final preset = prepareStudioPresetForMode(
      source,
      id: 'assisted',
      name: 'Assisted',
      mode: StudioExecutionMode.assisted,
      updatedAt: 1,
    );

    expect(
      preset.blocks
          .where((b) => b.kind == 'tracker_instruction')
          .map((b) => b.id),
      ['continuity_task_universal', 'narrative_task_universal', 'beauty_task'],
    );
    expect(preset.agentEnabled['continuity'], isTrue);
    expect(preset.agentEnabled['narrative'], isTrue);
    expect(preset.agentEnabled['meta'], isFalse);
    expect(preset.agentEnabled['beauty'], isTrue);
    expect(
      preset.blocks.firstWhere((b) => b.id == 'beauty_extractor').enabled,
      isTrue,
    );
    expect(
      preset.blocks
          .firstWhere((b) => b.id == 'continuity_task_universal')
          .content,
      'Authored continuity task.',
    );
    expect(
      preset.blocks
          .firstWhere((b) => b.id == 'narrative_task_universal')
          .content,
      'Authored narrative task.',
    );
    expect(
      preset.blocks
          .firstWhere((b) => b.id == 'final_response_shape_contract')
          .content,
      'Authored final contract.',
    );
  });
}
