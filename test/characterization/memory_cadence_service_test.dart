import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_cadence_repo.dart';
import 'package:glaze_flutter/core/llm/memory_cadence_service.dart';

void main() {
  late AppDatabase db;
  late MemoryCadenceRepo repo;
  late MemoryCadenceService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = MemoryCadenceRepo(db);
    service = MemoryCadenceService(repo);
  });

  tearDown(() async => db.close());

  group('MemoryCadenceService (Phase G4)', () {
    test('fast mode never runs', () async {
      await service.incrementAssistant('s1');
      final should = await service.shouldRun(
        's1',
        'graph',
        memoryMode: 'fast',
        cadenceInterval: 3,
      );
      expect(should, isFalse);
    });

    test('runs when assistant count reaches interval', () async {
      await service.incrementAssistant('s1');
      await service.incrementAssistant('s1');
      await service.incrementAssistant('s1');
      final should = await service.shouldRun(
        's1',
        'graph',
        memoryMode: 'balanced',
        cadenceInterval: 3,
      );
      expect(should, isTrue);
    });

    test('does not run before interval', () async {
      await service.incrementAssistant('s1');
      await service.incrementAssistant('s1');
      final should = await service.shouldRun(
        's1',
        'graph',
        memoryMode: 'balanced',
        cadenceInterval: 3,
      );
      expect(should, isFalse);
    });

    test('markRun resets counter', () async {
      await service.incrementAssistant('s1');
      await service.incrementAssistant('s1');
      await service.incrementAssistant('s1');
      await service.markRun('s1', 'graph');
      final should = await service.shouldRun(
        's1',
        'graph',
        memoryMode: 'balanced',
        cadenceInterval: 3,
      );
      expect(should, isFalse);
    });

    test('zero interval never runs', () async {
      await service.incrementAssistant('s1');
      final should = await service.shouldRun(
        's1',
        'graph',
        memoryMode: 'balanced',
        cadenceInterval: 0,
      );
      expect(should, isFalse);
    });
  });
}
