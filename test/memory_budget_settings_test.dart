import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_book_api_settings.dart';
import 'package:glaze_flutter/core/models/memory_pipeline_settings.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'memory global settings persists maxInjectedTokens and preset',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(memoryGlobalSettingsProvider.notifier)
          .save(
            const MemoryGlobalSettings(
              maxInjectedTokens: 6000,
              memoryBudgetPreset: 'medium',
              memoryMode: 'balanced',
            ),
          );

      final prefs = await SharedPreferences.getInstance();
      final json =
          jsonDecode(prefs.getString('memorySettings')!)
              as Map<String, dynamic>;

      expect(json['maxInjectedTokens'], 6000);
      expect(json['memoryBudgetPreset'], 'medium');
      expect(json['memoryMode'], 'balanced');
    },
  );

  test(
    'pipeline settings survive a cold start: saved values reload via load()',
    () async {
      // Regression: pipelineSettingsProvider.load() must actually be reachable
      // and round-trip the persisted SharedPreferences value. Previously the
      // notifier seeded defaults and load() was never wired into startup, so
      // after a restart every read returned defaults (and the first save
      // overwrote the persisted config with defaults).
      SharedPreferences.setMockInitialValues({});

      // First "session": user configures + saves.
      final container1 = ProviderContainer();
      await container1
          .read(pipelineSettingsProvider.notifier)
          .save(
            const PipelineSettings(
              cleaner: CleanerSettings(
                postCleanerBannedWords: 'suddenly, palpable',
              ),
              memoryPipeline: MemoryPipelineSettings(auxTimeoutMs: 30000),
            ),
          );
      container1.dispose();

      // Cold start: a brand-new container starts from defaults and must load
      // the persisted values (this is the call wired into loadActiveSelections).
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);

      // Before load(), state is defaults (proves load() is what restores it).
      expect(
        container2.read(pipelineSettingsProvider).cleaner.postCleanerBannedWords,
        '',
      );

      await container2.read(pipelineSettingsProvider.notifier).load();

      final loaded = container2.read(pipelineSettingsProvider);
      expect(loaded.cleaner.postCleanerBannedWords, 'suddenly, palpable');
      expect(loaded.memoryPipeline.auxTimeoutMs, 30000);
    },
  );

  test(
    'memory global settings loads legacy percent-only data as auto',
    () async {
      SharedPreferences.setMockInitialValues({
        'memorySettings': jsonEncode({
          'maxInjectedEntries': 7,
          'injectionTarget': 'hard_block',
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(memoryGlobalSettingsProvider.notifier).load();

      final settings = container.read(memoryGlobalSettingsProvider);
      expect(settings.maxInjectedTokens, isNull);
      expect(settings.memoryBudgetPreset, 'auto');
      expect(settings.memoryMode, 'fast');
    },
  );

  test('memory global settings persists advanced selector tuning', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(memoryGlobalSettingsProvider.notifier)
        .save(
          const MemoryGlobalSettings(
            memoryPackingMode: 'chunk_first',
            memoryExcerptTokensPerChunk: 300,
            memoryExcerptChunksPerEntry: 4,
            diversityAware: false,
            diversityPenalty: 0.3,
            recencyBoost: false,
            recencyHalfLifeDays: 2,
            importanceBoost: false,
            importanceWeight: 1.25,
            sourceWindowExclusion: false,
            factualContinuityGuardEnabled: true,
            queryIncludeAssistant: false,
            queryRecentTurns: 4,
            queryMaxChars: 750,
          ),
        );

    await container
        .read(pipelineSettingsProvider.notifier)
        .save(
          const PipelineSettings(
            memoryPipeline: MemoryPipelineSettings(
              auxTimeoutMs: 4500,
            ),
            memoryBookApi: MemoryBookApiSettings(
              generationSource: 'custom',
              generationModel: 'mem-mini',
              generationEndpoint: 'https://mem.example/v1',
              generationApiKey: 'mem-key',
            ),
          ),
        );

    final prefs = await SharedPreferences.getInstance();
    final memoryJson =
        jsonDecode(prefs.getString('memorySettings')!) as Map<String, dynamic>;
    final pipelineJson =
        jsonDecode(prefs.getString('pipelineSettings')!)
            as Map<String, dynamic>;

    expect(memoryJson['memoryPackingMode'], 'chunk_first');
    expect(memoryJson['memoryExcerptTokensPerChunk'], 300);
    expect(memoryJson['memoryExcerptChunksPerEntry'], 4);
    expect(memoryJson['diversityAware'], false);
    expect(memoryJson['diversityPenalty'], 0.3);
    expect(memoryJson['recencyBoost'], false);
    expect(memoryJson['recencyHalfLifeDays'], 2);
    expect(memoryJson['importanceBoost'], false);
    expect(memoryJson['importanceWeight'], 1.25);
    expect(memoryJson['sourceWindowExclusion'], false);
    expect(memoryJson['factualContinuityGuardEnabled'], true);
    expect(memoryJson['queryIncludeAssistant'], false);
    expect(memoryJson['queryRecentTurns'], 4);
    expect(memoryJson['queryMaxChars'], 750);

    final pipelineMp = pipelineJson['memoryPipeline'] as Map<String, dynamic>;
    expect(pipelineMp['auxTimeoutMs'], 4500);
    final pipelineMb = pipelineJson['memoryBookApi'] as Map<String, dynamic>;
    expect(pipelineMb['generationSource'], 'custom');
    expect(pipelineMb['generationModel'], 'mem-mini');
    expect(pipelineMb['generationEndpoint'], 'https://mem.example/v1');
    expect(pipelineMb['generationApiKey'], 'mem-key');
  });

  test('new memory books inherit advanced selector tuning', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    await container
        .read(memoryGlobalSettingsProvider.notifier)
        .save(
          const MemoryGlobalSettings(
            diversityAware: false,
            memoryMode: 'balanced',
            memoryPackingMode: 'chunk_first',
            memoryExcerptTokensPerChunk: 300,
            memoryExcerptChunksPerEntry: 4,
            recencyBoost: false,
            importanceWeight: 1.5,
            sourceWindowExclusion: false,
            factualContinuityGuardEnabled: true,
            queryIncludeAssistant: false,
            queryRecentTurns: 3,
            queryMaxChars: 900,
          ),
        );

    await container
        .read(pipelineSettingsProvider.notifier)
        .save(
          const PipelineSettings(
            memoryPipeline: MemoryPipelineSettings(
              auxTimeoutMs: 4500,
            ),
          ),
        );

    final repo = container.read(memoryBookRepoProvider);
    final book = await repo.ensureForSession('session_advanced');

    expect(book.settings.diversityAware, false);
    expect(book.settings.memoryMode, 'balanced');
    expect(book.settings.memoryPackingMode, 'chunk_first');
    expect(book.settings.memoryExcerptTokensPerChunk, 300);
    expect(book.settings.memoryExcerptChunksPerEntry, 4);
    expect(book.settings.recencyBoost, false);
    expect(book.settings.importanceWeight, 1.5);
    expect(book.settings.sourceWindowExclusion, false);
    expect(book.settings.factualContinuityGuardEnabled, true);
    expect(book.settings.queryIncludeAssistant, false);
    expect(book.settings.queryRecentTurns, 3);
    expect(book.settings.queryMaxChars, 900);

    // Pipeline settings are now a singleton global — the same instance is
    // returned by the StateNotifierProvider for every session.
    final pipeline = container.read(pipelineSettingsProvider);
    expect(pipeline.memoryPipeline.auxTimeoutMs, 4500);
  });

  test('memory book settings update persists selector inputs', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    final repo = container.read(memoryBookRepoProvider);
    await repo.put(const MemoryBook(id: 'mb1', sessionId: 'session_update'));
    await repo.updateSettings(
      'session_update',
      const MemoryBookSettings(
        memoryMode: 'balanced',
        memoryPackingMode: 'chunk_first',
        memoryExcerptTokensPerChunk: 300,
        memoryExcerptChunksPerEntry: 4,
        diversityAware: false,
        factualContinuityGuardEnabled: true,
        queryIncludeAssistant: false,
        queryRecentTurns: 5,
        queryMaxChars: 1250,
      ),
    );

    final updated = await repo.getBySessionId('session_update');
    expect(updated!.settings.diversityAware, false);
    expect(updated.settings.memoryMode, 'balanced');
    expect(updated.settings.memoryPackingMode, 'chunk_first');
    expect(updated.settings.memoryExcerptTokensPerChunk, 300);
    expect(updated.settings.memoryExcerptChunksPerEntry, 4);
    expect(updated.settings.factualContinuityGuardEnabled, true);
    expect(updated.settings.queryIncludeAssistant, false);
    expect(updated.settings.queryRecentTurns, 5);
    expect(updated.settings.queryMaxChars, 1250);
  });

  test('memory book can be copied to branched session', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    final repo = container.read(memoryBookRepoProvider);
    await repo.put(
      const MemoryBook(
        id: 'memorybook_char_0',
        sessionId: 'char_0',
        entries: [
          MemoryEntry(
            id: 'mem_1',
            content: 'important fact',
            messageIds: ['m1'],
          ),
        ],
        pendingDrafts: [
          MemoryDraft(id: 'draft_1', messageIds: ['m2']),
        ],
        settings: MemoryBookSettings(batchSize: 7),
        lastProcessedMessageCount: 12,
      ),
    );

    await repo.copyForSessionBranch(
      fromSessionId: 'char_0',
      toSessionId: 'char_1',
      messageIds: const {'m1', 'm2'},
    );

    final copied = await repo.getBySessionId('char_1');
    expect(copied, isNotNull);
    expect(copied!.id, 'memorybook_char_1');
    expect(copied.sessionId, 'char_1');
    expect(copied.entries.single.id, 'mem_1@char_1');
    expect(copied.entries.single.content, 'important fact');
    expect(copied.pendingDrafts.single.id, 'draft_1@char_1');
    expect(copied.settings.batchSize, 7);
    expect(copied.lastProcessedMessageCount, 0);
  });

  test('legacy memory entries recover messageRange from range title', () {
    final entry = MemoryEntry.fromJson({
      'id': 'mem_legacy',
      'title': '91-105',
      'content': 'remembered events',
      'keys': <String>[],
      'messageIds': <String>['m1'],
      'status': 'active',
    });

    expect(entry.messageRange, const MessageRange(start: 91, end: 105));
  });
}
