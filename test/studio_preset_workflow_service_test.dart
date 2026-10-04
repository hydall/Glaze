import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/application/sync_repo_interfaces.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/studio/services/studio_preset_workflow_service.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('StudioPresetWorkflowService', () {
    test('creates a copy of the global active preset and selects it', () async {
      final store = _MemoryStudioPresetStore([
        const StudioPreset(id: 'default', name: 'Default'),
        const StudioPreset(
          id: 'active',
          name: 'Source',
          blocks: [StudioPresetBlock(id: 'block', content: 'source')],
          agentEnabled: {'continuity': false},
          updatedAt: 12,
        ),
      ]);
      var activeId = 'active';
      final service = _service(
        store: store,
        readActive: () async => activeId,
        writeActive: (id) async => activeId = id,
        now: 100,
      );

      final result = await service.createPreset(
        name: '  My Copy  ',
        availablePresets: await service.loadPresets(),
      );

      expect(result, isNotNull);
      expect(result!.preset.id, 'studio_100');
      expect(result.preset.name, 'My Copy');
      expect(result.preset.blocks.single.content, 'source');
      expect(result.preset.agentEnabled, {'continuity': false});
      expect(result.preset.updatedAt, 100);
      expect(activeId, 'studio_100');
      expect((await store.getById('active'))!.updatedAt, 12);
      expect(result.presets.map((preset) => preset.name), [
        'Default',
        'My Copy',
        'Source',
      ]);
    });

    test(
      'import normalizes identity and keeps presets landing in the same second',
      () async {
        final store = _MemoryStudioPresetStore();
        var activeId = 'default';
        final service = _service(
          store: store,
          readActive: () async => activeId,
          writeActive: (id) async => activeId = id,
          now: 200,
        );
        const first = StudioPreset(
          id: 'exported-id',
          name: 'Exported',
          blocks: [StudioPresetBlock(id: 'first', content: 'First')],
          agentEnabled: {'final': false},
          updatedAt: 1,
        );
        const second = StudioPreset(
          id: 'other-exported-id',
          name: 'Other',
          blocks: [StudioPresetBlock(id: 'second', content: 'Second')],
          updatedAt: 2,
        );

        final firstResult = await service.importPreset(
          imported: first,
          name: '  Imported  ',
        );
        final secondResult = await service.importPreset(
          imported: second,
          name: 'Replacement',
        );

        expect(firstResult!.preset.id, 'studio_200');
        expect(firstResult.preset.name, 'Imported');
        expect(firstResult.preset.agentEnabled, {'final': false});
        // The clock only ticks in seconds, so importing several files at once
        // hands them all the same stamp — the id has to step past the taken one
        // instead of overwriting the preset already stored under it.
        expect(secondResult!.preset.id, 'studio_201');
        expect(secondResult.presets, hasLength(2));
        expect(secondResult.presets.map((preset) => preset.name), [
          'Imported',
          'Replacement',
        ]);
        expect(
          secondResult.presets
              .firstWhere((preset) => preset.name == 'Replacement')
              .blocks
              .single
              .id,
          'second',
        );
        expect(activeId, 'studio_201');
      },
    );

    test('deleting the active preset falls back to global default', () async {
      final store = _MemoryStudioPresetStore([
        const StudioPreset(id: 'default', name: 'Default'),
        const StudioPreset(id: 'custom', name: 'Custom'),
      ]);
      var activeId = 'custom';
      final service = _service(
        store: store,
        readActive: () async => activeId,
        writeActive: (id) async => activeId = id,
      );

      final presets = await service.deletePreset('custom');

      expect(presets.map((preset) => preset.id), ['default']);
      expect(activeId, 'default');
    });

    test(
      'active selection is global and independent of session configs',
      () async {
        final store = _MemoryStudioPresetStore();
        var globalActiveId = 'default';
        final firstSessionService = _service(
          store: store,
          readActive: () async => globalActiveId,
          writeActive: (id) async => globalActiveId = id,
        );
        final secondSessionService = _service(
          store: store,
          readActive: () async => globalActiveId,
          writeActive: (id) async => globalActiveId = id,
        );
        const firstConfig = StudioPreset(
          id: 'session-a',
          expensiveApiConfigId: 'api-a',
        );
        const secondConfig = StudioPreset(
          id: 'session-b',
          expensiveApiConfigId: 'api-b',
        );

        await firstSessionService.selectPreset('shared-preset');

        expect(globalActiveId, 'shared-preset');
        await secondSessionService.selectPreset('other-shared-preset');
        expect(globalActiveId, 'other-shared-preset');
        expect(firstConfig.expensiveApiConfigId, 'api-a');
        expect(secondConfig.expensiveApiConfigId, 'api-b');
      },
    );

    test('rejects invalid typed blocks before persistence', () async {
      final store = _MemoryStudioPresetStore();
      var activeId = 'default';
      final service = _service(
        store: store,
        readActive: () async => activeId,
        writeActive: (id) async => activeId = id,
      );

      await expectLater(
        service.importPreset(
          imported: const StudioPreset(
            id: 'invalid',
            blocks: [
              StudioPresetBlock(id: 'context', type: StudioBlockType.context),
            ],
          ),
          name: 'Invalid',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(await store.getAll(), isEmpty);
      expect(activeId, 'default');
    });
  });
}

StudioPresetWorkflowService _service({
  required _MemoryStudioPresetStore store,
  required Future<String> Function() readActive,
  required Future<void> Function(String) writeActive,
  int now = 1,
}) {
  return StudioPresetWorkflowService(store, readActive, writeActive, () => now);
}

class _MemoryStudioPresetStore implements SyncStudioPresetStore {
  final Map<String, StudioPreset> _presets;

  _MemoryStudioPresetStore([List<StudioPreset> presets = const []])
    : _presets = {for (final preset in presets) preset.id: preset};

  @override
  Future<void> delete(String id) async {
    _presets.remove(id);
  }

  @override
  Future<List<StudioPreset>> getAll() async => _presets.values.toList();

  @override
  Future<StudioPreset?> getById(String id) async => _presets[id];

  @override
  Future<void> put(StudioPreset preset) async {
    _presets[preset.id] = preset;
  }
}
