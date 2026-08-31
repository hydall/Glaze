import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/memory_draft_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'auto-generation fills newly planned drafts and releases its lease',
    () async {
      final harness = await _createHarness(autoGenerate: true);
      addTearDown(harness.dispose);
      final lease = harness.stage.reserveAutoGeneration(harness.session);
      expect(lease, isNotNull);
      expect(harness.container.read(memoryActiveDraftsProvider), {'s1'});

      await harness.stage.run(harness.session, generationLease: lease);

      final book = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId('s1');
      expect(harness.calls(), 1);
      expect(book!.pendingDrafts, hasLength(1));
      expect(book.pendingDrafts.single.content, 'Generated memory');
      expect(book.pendingDrafts.single.status, 'pending_approval');
      expect(book.pendingDrafts.single.messageIds, ['u1', 'a1']);
      expect(harness.container.read(memoryActiveDraftsProvider), isEmpty);
    },
  );

  test(
    'disabled auto-generation creates an empty draft without an LLM call',
    () async {
      final harness = await _createHarness(autoGenerate: false);
      addTearDown(harness.dispose);

      expect(harness.stage.reserveAutoGeneration(harness.session), isNull);
      await harness.stage.run(harness.session);

      final book = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId('s1');
      expect(harness.calls(), 0);
      expect(book!.pendingDrafts.single.status, 'pending_generation');
      expect(book.pendingDrafts.single.content, isEmpty);
    },
  );

  test(
    'generation failure leaves the draft retryable and releases lease',
    () async {
      final harness = await _createHarness(
        autoGenerate: true,
        generationError: StateError('provider failed'),
      );
      addTearDown(harness.dispose);
      final lease = harness.stage.reserveAutoGeneration(harness.session);

      await harness.stage.run(harness.session, generationLease: lease);

      final book = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId('s1');
      expect(book!.pendingDrafts.single.status, 'needs_regeneration');
      expect(book.pendingDrafts.single.error, contains('provider failed'));
      expect(harness.container.read(memoryActiveDraftsProvider), isEmpty);
    },
  );
}

Future<_Harness> _createHarness({
  required bool autoGenerate,
  Object? generationError,
}) async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [appDbProvider.overrideWithValue(db)],
  );
  await container
      .read(memoryGlobalSettingsProvider.notifier)
      .save(
        MemoryGlobalSettings(
          autoGenerateEnabled: autoGenerate,
          autoCreateInterval: 2,
          autoCreateLagMessages: 0,
          batchSize: 1,
        ),
      );

  var calls = 0;
  final stageProvider = Provider<MemoryDraftStage>((ref) {
    late AsyncValue<ChatState> state = const AsyncData(ChatState());
    final abortHandler = AbortHandler(
      ref: ref,
      charId: 'c1',
      setState: (next) => state = next,
      getState: () => state,
      mutateSession: (_, _) async => null,
      loadSession: (_) async => null,
    );
    return MemoryDraftStage(
      StageContext(
        ref: ref,
        charId: 'c1',
        abortHandler: abortHandler,
        setState: (next) => state = next,
        getState: () => state,
      ),
      generate:
          ({
            required draft,
            required settings,
            required pipeline,
            required historyText,
          }) async {
            calls++;
            if (generationError != null) throw generationError;
            expect(historyText, contains('User turn'));
            return draft.copyWith(
              content: 'Generated memory',
              keys: ['memory'],
              status: 'pending_approval',
              generatedAt: 100,
              updatedAt: 100,
            );
          },
    );
  });
  return _Harness(
    container: container,
    db: db,
    stage: container.read(stageProvider),
    session: const ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      sessionVars: {},
      messages: [
        ChatMessage(id: 'u1', role: 'user', content: 'User turn'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'Assistant turn'),
      ],
    ),
    calls: () => calls,
  );
}

class _Harness {
  const _Harness({
    required this.container,
    required this.db,
    required this.stage,
    required this.session,
    required this.calls,
  });

  final ProviderContainer container;
  final AppDatabase db;
  final MemoryDraftStage stage;
  final ChatSession session;
  final int Function() calls;

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}
