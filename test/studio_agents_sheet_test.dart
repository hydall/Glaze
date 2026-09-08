import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/chat/widgets/studio_agents_sheet.dart';

void main() {
  group('StudioAgentsSheet beauty toggle', () {
    const preset = StudioPreset(
      id: 'p1',
      blocks: [
        StudioPresetBlock(id: 'beauty_extractor', section: 'build'),
        StudioPresetBlock(id: 'beauty_task', section: 'pregen'),
        StudioPresetBlock(id: 'cleaner_beauty', section: 'cleaner'),
        StudioPresetBlock(id: 'narrative_task', section: 'pregen'),
      ],
    );

    test('disabling Beauty disables every Beauty pipeline block', () {
      final result = applyStudioAgentToggle(preset, 'beauty', false);

      expect(
        result.blocks
            .where(
              (block) =>
                  block.id.startsWith('beauty') || block.id == 'cleaner_beauty',
            )
            .every((block) => !block.enabled),
        isTrue,
      );
      expect(
        result.blocks
            .singleWhere((block) => block.id == 'narrative_task')
            .enabled,
        isTrue,
      );
    });

    test('enabling Beauty enables every Beauty pipeline block', () {
      final disabled = preset.copyWith(
        blocks: preset.blocks
            .map(
              (block) => block.id.contains('beauty')
                  ? block.copyWith(enabled: false)
                  : block,
            )
            .toList(),
      );

      final result = applyStudioAgentToggle(disabled, 'beauty', true);

      expect(
        result.blocks
            .where(
              (block) =>
                  block.id.startsWith('beauty') || block.id == 'cleaner_beauty',
            )
            .every((block) => block.enabled),
        isTrue,
      );
    });
  });
}
