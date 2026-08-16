import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_codec.dart';

void main() {
  test('canonicalizes persisted block arrays and rejects malformed shapes', () {
    final encoded = StudioPresetCodec.canonicalizeBlocksJson(
      jsonEncode([
        {'id': 'history', 'kind': 'chat_history'},
      ]),
    );
    final decoded = jsonDecode(encoded) as List;
    expect(decoded.single['type'], 'history');
    expect(decoded.single, isNot(contains('kind')));
    expect(
      () => StudioPresetCodec.canonicalizeBlocksJson('{}'),
      throwsFormatException,
    );
  });

  test('canonicalizes legacy blocks and writes no kind', () {
    final result = StudioPresetCodec.decodePreset({
      'id': 'legacy',
      'name': 'Legacy',
      'blocks': [
        {
          'id': 'continuity_task_universal',
          'name': 'Continuity task',
          'kind': 'tracker_instruction',
          'content': 'Track continuity',
          'section': 'pregen',
        },
        {'id': 'history', 'kind': 'chat_history'},
        {'id': 'static', 'kind': 'static_context'},
        {'id': 'memory', 'kind': 'memory'},
        {'id': 'briefs', 'kind': 'previous_agents'},
      ],
    });

    expect(result.warnings, isEmpty);
    expect(result.preset.blocks[0].targetAgentId, 'continuity');
    expect(result.preset.blocks[0].title, 'Continuity task');
    expect(result.preset.blocks[1].type, StudioBlockType.history);
    expect(
      result.preset.blocks[2].contextSlot,
      StudioContextSlot.staticContext,
    );
    expect(result.preset.blocks[3].contextSlot, StudioContextSlot.memory);
    expect(result.preset.blocks[4].type, StudioBlockType.priorBriefs);
    final canonical = StudioPresetCodec.canonicalizePresetJson({
      'id': 'legacy',
      'blocks': [
        {'id': 'history', 'kind': 'chat_history'},
      ],
    });
    for (final block in canonical['blocks'] as List<dynamic>) {
      expect(block as Map<String, dynamic>, isNot(contains('kind')));
    }
  });

  test('controller block mappings survive preset canonicalization', () {
    final canonical = StudioPresetCodec.canonicalizePresetJson({
      'id': 'controller-folders',
      'blocks': const <Map<String, dynamic>>[],
      'agentBlockRestoreState': {
        'guard_ru': ['ru_quality', 'ru_dialogue'],
      },
      'controllerAlternativeBlockIds': {
        'guard_ru': ['ru_contract', 'ru_quality'],
        'guard_en': ['en_contract'],
      },
    });

    expect(canonical['agentBlockRestoreState'], {
      'guard_ru': ['ru_quality', 'ru_dialogue'],
    });
    expect(canonical['controllerAlternativeBlockIds'], {
      'guard_ru': ['ru_contract', 'ru_quality'],
      'guard_en': ['en_contract'],
    });
  });

  test('unresolved and ambiguous tracker aliases fail closed', () {
    for (final json in [
      {'id': 'mystery', 'kind': 'tracker_instruction', 'content': 'Task'},
      {
        'id': 'continuity_dialogue',
        'kind': 'tracker_instruction',
        'content': 'Task',
      },
    ]) {
      final result = StudioPresetCodec.canonicalizeBlock(json);
      expect(result.block.enabled, isFalse);
      expect(result.block.targetAgentId, isNull);
      expect(result.warning, isNotNull);
    }
  });

  test(
    'unknown content is preserved and unknown blank blocks are disabled',
    () {
      final content = StudioPresetCodec.canonicalizeBlock({
        'id': 'future',
        'kind': 'future_kind',
        'content': 'Keep me',
        'role': 'user',
        'locked': true,
        'order': 9,
        'section': 'final',
      });
      final blank = StudioPresetCodec.canonicalizeBlock({
        'id': 'blank',
        'kind': 'future_kind',
      });

      expect(content.block.type, StudioBlockType.instruction);
      expect(content.block.content, 'Keep me');
      expect(content.block.role, 'user');
      expect(content.block.locked, isTrue);
      expect(content.block.order, 9);
      expect(content.block.section, 'final');
      expect(blank.block.enabled, isFalse);
      expect(blank.warning, isNotNull);
    },
  );

  test('canonicalization is idempotent', () {
    final once = StudioPresetCodec.canonicalizeBlockJson({
      'id': 'dynamic',
      'kind': 'dynamic_context',
      'enabled': true,
    });
    final twice = StudioPresetCodec.canonicalizeBlockJson(once);

    expect(twice, once);
  });

  test('canonical blocks keep their pipeline section on round-trip', () {
    const source = StudioPreset(
      id: 'pipeline-sections',
      agents: [],
      blocks: [
        StudioPresetBlock(
          id: 'final_main_prompt',
          section: '',
          injectionPoint: 'final',
          mode: 'direct',
        ),
        StudioPresetBlock(
          id: 'cleaner_system',
          section: '',
          injectionPoint: 'cleaner',
          mode: 'direct',
        ),
        StudioPresetBlock(
          id: 'ledger_system',
          section: '',
          injectionPoint: 'ledger',
          mode: 'direct',
        ),
        StudioPresetBlock(
          id: 'ledger_reconciliation_prompt',
          section: '',
          injectionPoint: 'ledger',
          mode: 'agentResponse',
          sourceAgentId: 'ledger',
          groupBoundary: 'close',
          isStatic: true,
        ),
      ],
    );

    final restored = StudioPresetCodec.decodePreset(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source.toJson())) as Map),
    ).preset;

    expect(restored.blocks.map((block) => block.injectionPoint), [
      'final',
      'cleaner',
      'ledger',
      'ledger',
    ]);
    expect(restored.blocks.last.mode, 'agentResponse');
    expect(restored.blocks.last.sourceAgentId, 'ledger');
    expect(restored.blocks.last.groupBoundary, 'close');
    expect(restored.blocks.last.isStatic, isTrue);
  });

  test('canonical injection point does not require a legacy section', () {
    final block = StudioPresetCodec.canonicalizeBlock({
      'id': 'ledger_reconciliation_prompt',
      'type': 'instruction',
      'injectionPoint': 'ledger',
      'mode': 'direct',
    }).block;

    expect(block.section, isEmpty);
    expect(block.injectionPoint, 'ledger');
  });

  test('canonicalizes imported agents and defaults runtime fields', () {
    final decoded = StudioPresetCodec.decodePreset({
      'id': 'imported',
      'agents': [
        {'id': 'agent_session_continuity_123', 'sourceBlockNames': 'legacy'},
        {'id': 'unknown', 'enabled': true},
      ],
    });

    expect(decoded.preset.agents[0].controllerId, 'continuity');
    expect(decoded.preset.agents[1].enabled, isFalse);
    expect(decoded.preset.maxFinalHistoryMessages, 30);
    expect(decoded.preset.expensiveApiConfigId, isEmpty);
    final canonical = StudioPresetCodec.canonicalizePresetJson({
      'id': 'imported',
      'agents': [
        {'id': 'agent_session_continuity_123'},
      ],
    });
    expect((canonical['agents'] as List).single['controllerId'], 'continuity');
  });

  test(
    'missing agents gets preset-scoped defaults but explicit empty stays empty',
    () {
      final missing = StudioPresetCodec.decodePreset({
        'id': 'legacy-preset',
        'updatedAt': 42,
      }).preset;
      final explicit = StudioPresetCodec.decodePreset({
        'id': 'explicit-empty',
        'agents': <dynamic>[],
      }).preset;

      expect(missing.agents, isNotEmpty);
      expect(
        missing.agents.every((agent) => agent.id.contains('legacy-preset')),
        isTrue,
      );
      expect(explicit.agents, isEmpty);
    },
  );

  test('canonical runtime round-trips broadcast blocks', () {
    const runtime = StudioRuntimeSettings(
      broadcastBlocks: ['\uFEFFfirst\r\nline', 'second\nline', 'последний'],
    );

    final canonical = StudioPresetCodec.canonicalizePresetJson({
      'id': 'runtime',
      'runtime': runtime.toJson(),
    });
    final restored = StudioPresetCodec.decodePreset(canonical).preset.runtime;

    expect(restored, runtime);
    expect(restored.version, 1);
    expect(restored.broadcastBlocks, runtime.broadcastBlocks);
  });

  test(
    'absent and malformed runtime default without affecting other fields',
    () {
      final absent = StudioPresetCodec.decodePreset({'id': 'absent'});
      final malformed = StudioPresetCodec.decodePreset({
        'id': 'malformed',
        'blocks': [
          {'id': 'history', 'kind': 'chat_history'},
        ],
        'agents': [
          {'id': 'agent_session_continuity_123'},
        ],
        'runtime': 'not-an-object',
      });

      expect(absent.preset.runtime, const StudioRuntimeSettings());
      expect(absent.warnings, isEmpty);
      expect(malformed.preset.runtime, const StudioRuntimeSettings());
      expect(malformed.warnings, hasLength(1));
      expect(malformed.preset.blocks.single.type, StudioBlockType.history);
      expect(malformed.preset.agents.single.controllerId, 'continuity');
      expect(
        StudioPresetCodec.canonicalizePresetJson({'id': 'absent'})['runtime'],
        jsonDecode(jsonEncode(const StudioRuntimeSettings())),
      );
    },
  );

  test('Ledger engine defaults current and unknown values fail to current', () {
    final absent = StudioPresetCodec.decodePreset({'id': 'absent'}).preset;
    final unknown = StudioPresetCodec.decodePreset({
      'id': 'future',
      'runtime': {'ledgerEngine': 'futureEngine'},
    }).preset;
    final legacy = StudioPresetCodec.decodePreset({
      'id': 'legacy',
      'runtime': {'ledgerEngine': 'legacyTurnOnly'},
    }).preset;

    expect(absent.runtime.ledgerEngine, StudioLedgerEngine.currentReconciled);
    expect(unknown.runtime.ledgerEngine, StudioLedgerEngine.currentReconciled);
    expect(legacy.runtime.ledgerEngine, StudioLedgerEngine.currentReconciled);
  });
}
