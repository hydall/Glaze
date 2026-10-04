import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_migration.dart';

void main() {
  group('migrateStudioPresetBlocksToV2', () {
    test('maps priorBriefs type → pregenBrief and clears legacy section', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(
          id: 'previous_agents',
          type: StudioBlockType.priorBriefs,
          section: 'final',
        ),
      ]);
      expect(out, hasLength(1));
      expect(out.single.mode, 'pregenBrief');
      expect(out.single.injectionPoint, 'final');
      expect(out.single.section, isEmpty);
    });

    test(
      'routes instruction with targetAgentId to specificAgent injection',
      () {
        final out = migrateStudioPresetBlocksToV2(const [
          StudioPresetBlock(
            id: 'continuity_task',
            type: StudioBlockType.instruction,
            targetAgentId: 'continuity',
            section: 'pregen',
          ),
          StudioPresetBlock(
            id: 'agency_task',
            type: StudioBlockType.instruction,
            targetAgentId: 'agency',
            section: 'pregen',
          ),
          StudioPresetBlock(
            id: 'guard_task',
            type: StudioBlockType.instruction,
            targetAgentId: 'guard',
            section: 'pregen',
          ),
        ]);
        expect(out.map((b) => b.injectionPoint), everyElement('specificAgent'));
        expect(out.map((b) => b.targetAgentId), [
          'continuity',
          'agency',
          'guard',
        ]);
        expect(out.map((b) => b.mode), everyElement('direct'));
      },
    );

    test(
      'instruction without targetAgentId keeps its section as injection',
      () {
        final out = migrateStudioPresetBlocksToV2(const [
          StudioPresetBlock(
            id: 'a',
            type: StudioBlockType.instruction,
            section: 'pregen',
          ),
          StudioPresetBlock(
            id: 'b',
            type: StudioBlockType.instruction,
            section: 'final',
          ),
          StudioPresetBlock(
            id: 'c',
            type: StudioBlockType.instruction,
            section: 'cleaner',
          ),
          StudioPresetBlock(
            id: 'd',
            type: StudioBlockType.instruction,
            section: 'ledger',
          ),
        ]);
        expect(out.map((b) => b.injectionPoint), [
          'pregen',
          'final',
          'cleaner',
          'ledger',
        ]);
        expect(out.map((b) => b.mode), everyElement('direct'));
      },
    );

    test('drops dead build/brief_parser sections', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(
          id: 'r',
          type: StudioBlockType.instruction,
          section: 'build',
        ),
        StudioPresetBlock(
          id: 'p',
          type: StudioBlockType.instruction,
          section: 'brief_parser',
        ),
        StudioPresetBlock(
          id: 'keep',
          type: StudioBlockType.instruction,
          section: 'pregen',
        ),
      ]);
      expect(out.map((b) => b.id), ['keep']);
    });

    test(
      'group boundaries by id suffix move to groupBoundary with empty mode',
      () {
        final out = migrateStudioPresetBlocksToV2(const [
          StudioPresetBlock(
            id: 'grp_group_open',
            type: StudioBlockType.instruction,
            section: 'pregen',
          ),
          StudioPresetBlock(
            id: 'grp_group_close',
            type: StudioBlockType.instruction,
            section: 'pregen',
          ),
        ]);
        expect(out[0].groupBoundary, 'open');
        expect(out[1].groupBoundary, 'close');
        expect(out.map((b) => b.mode), everyElement(''));
      },
    );

    test('context/history types get an empty mode', () {
      final out = migrateStudioPresetBlocksToV2(const [
        StudioPresetBlock(
          id: 'chat_history',
          type: StudioBlockType.history,
          section: 'final',
        ),
      ]);
      expect(out.single.id, 'chat_history');
      expect(out.single.mode, isEmpty);
      expect(out.single.injectionPoint, 'final');
    });

    test('is idempotent and leaves editor-created blocks untouched', () {
      final legacy = [
        const StudioPresetBlock(
          id: 'continuity_task',
          type: StudioBlockType.instruction,
          targetAgentId: 'continuity',
          section: 'pregen',
        ),
        // Editor-created block: section cleared, explicit new fields
        // (mirrors what StudioPresetEditorBody._addBlock produces).
        const StudioPresetBlock(
          id: 'custom',
          section: '',
          mode: 'direct',
          injectionPoint: 'final',
        ),
      ];
      final once = migrateStudioPresetBlocksToV2(legacy);
      final twice = migrateStudioPresetBlocksToV2(once);
      expect(studioPresetBlocksNeedMigration(once), isFalse);
      expect(twice, same(once)); // no-op on the second pass
      final custom = once.firstWhere((b) => b.id == 'custom');
      expect(custom.injectionPoint, 'final');
      expect(custom.mode, 'direct');
    });

    test('repairs built-in blocks corrupted before the codec fix', () {
      final corrupted = [
        const StudioPresetBlock(
          id: 'final_main_prompt',
          section: '',
          injectionPoint: 'pregen',
        ),
        const StudioPresetBlock(
          id: 'cleaner_system',
          section: '',
          injectionPoint: 'final',
        ),
        const StudioPresetBlock(
          id: 'cleaner_audit',
          section: '',
          injectionPoint: 'pregen',
        ),
        const StudioPresetBlock(
          id: 'ledger_system',
          section: '',
          injectionPoint: 'pregen',
        ),
        const StudioPresetBlock(
          id: 'ledger_reconciliation_prompt',
          section: '',
          injectionPoint: 'final',
        ),
        const StudioPresetBlock(
          id: 'custom',
          section: '',
          injectionPoint: 'final',
        ),
      ];

      final repaired = migrateStudioPresetBlocksToV2(corrupted);

      expect(repaired.map((block) => block.injectionPoint), [
        'final',
        'cleaner',
        'cleaner',
        'ledger',
        'ledger',
        'final',
      ]);
      expect(migrateStudioPresetBlocksToV2(repaired), same(repaired));
    });
  });
}
