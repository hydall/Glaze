import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';

/// What a failed memory draft leaves behind: the persisted draft, and the
/// failure the sheet turns into a toast.
typedef _Failure = ({MemoryDraft draft, MemoryDraftJobFailure published});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const draftId = 'draft-1';
  var sequence = 0;

  /// Runs one draft generation that fails with [error], and reports what the
  /// user is left looking at.
  Future<_Failure> generationFailing(Object error) async {
    SharedPreferences.setMockInitialValues({});
    ChatSessionService.clearCache();
    final id = ++sequence;
    final charId = 'c$id';
    final sessionId = 's$id';
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        memoryDraftGeneratorProvider.overrideWithValue(
          ({
            required draft,
            required settings,
            required pipeline,
            required messages,
            required charId,
            required sessionId,
            required sessionVars,
            cancelToken,
          }) => Future<MemoryDraft>.error(error),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
    });

    await container
        .read(characterRepoProvider)
        .put(Character(id: charId, name: 'Alice'));
    await container
        .read(chatRepoProvider)
        .put(
          ChatSession(
            id: sessionId,
            characterId: charId,
            sessionIndex: 0,
            messages: const [
              ChatMessage(
                id: 'm1',
                role: 'user',
                content: 'Hello',
                timestamp: 1,
              ),
            ],
          ),
        );
    await container
        .read(memoryBookRepoProvider)
        .put(
          MemoryBook(
            id: 'memorybook_$sessionId',
            sessionId: sessionId,
            pendingDrafts: const [
              MemoryDraft(
                id: draftId,
                messageIds: ['m1'],
                content: 'old content',
              ),
            ],
          ),
        );
    await container.read(chatProvider(charId).future);

    await container
        .read(memoryDraftJobsProvider.notifier)
        .generate(sessionId: sessionId, charId: charId, draftId: draftId);

    final persisted = (await container
        .read(memoryBookRepoProvider)
        .getBySessionId(sessionId))!;
    final published = container.read(memoryDraftJobsProvider).lastFailure;
    return (
      draft: persisted.pendingDrafts.single,
      published:
          published ?? (throw StateError('the failure was never published')),
    );
  }

  /// The rejection a provider answers a blocked prompt with. `toString()` on
  /// this is Dio's own explanation of what a DioException is, which is what
  /// both the card and the toast used to show.
  DioException blockedByProvider() {
    final options = RequestOptions(path: '/chat/completions');
    return DioException.badResponse(
      statusCode: 400,
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: 400,
        data: const {
          'error': {'message': 'Content blocked by provider policy'},
        },
      ),
    );
  }

  test('a failed draft keeps the provider reason, not the Dio dump', () async {
    final failure = await generationFailing(blockedByProvider());

    expect(failure.draft.error, isNotNull);
    expect(failure.draft.error, isNot(contains('DioException')));
    expect(failure.draft.error, contains('HTTP 400'));
    expect(
      failure.draft.error!.split('\n').last,
      'Content blocked by provider policy',
    );
    // The card shows two lines: the reason has to be inside them.
    expect(failure.draft.error!.split('\n'), hasLength(2));
  });

  test('the toast says the same thing the card does', () async {
    final failure = await generationFailing(blockedByProvider());

    expect(failure.published.message, failure.draft.error);
  });

  test('the draft keeps its content and asks to be generated again', () async {
    final failure = await generationFailing(blockedByProvider());

    expect(failure.draft.content, 'old content');
    expect(failure.draft.status, 'needs_regeneration');
  });

  test('a failure that is not a provider rejection still reads', () async {
    final failure = await generationFailing(
      StateError('memory pipeline produced nothing'),
    );

    expect(failure.draft.error, contains('memory pipeline produced nothing'));
  });

  test('a failure on a draft that had content reads as a retry', () async {
    // The sheet titles the toast differently for a first attempt and for a
    // regeneration, and it is no longer the sheet that knows which this was —
    // the request may well have outlived it.
    final failure = await generationFailing(blockedByProvider());

    expect(failure.published.wasRegeneration, isTrue);
    expect(failure.published.seq, greaterThan(0));
  });
}
