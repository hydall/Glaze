import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
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
import 'package:glaze_flutter/features/memory/controllers/memory_book_write_queue.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_draft_generation_controller.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_settings_mapper.dart';

/// What a failed memory draft leaves behind: the persisted draft, and the
/// string the tab shows in a toast.
typedef _Failure = ({MemoryDraft draft, String reported});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const draftId = 'draft-1';
  var sequence = 0;

  /// Runs one draft generation that fails with [error], and reports what the
  /// user is left looking at.
  Future<_Failure> generationFailing(
    WidgetTester tester,
    Object error,
  ) async {
    SharedPreferences.setMockInitialValues({});
    ChatSessionService.clearCache();
    final id = ++sequence;
    final charId = 'c$id';
    final sessionId = 's$id';
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
    });

    await container
        .read(characterRepoProvider)
        .put(Character(id: charId, name: 'Alice'));
    await container.read(chatRepoProvider).put(
      ChatSession(
        id: sessionId,
        characterId: charId,
        sessionIndex: 0,
        messages: const [
          ChatMessage(id: 'm1', role: 'user', content: 'Hello', timestamp: 1),
        ],
      ),
    );
    var book = MemoryBook(
      id: 'memorybook_$sessionId',
      sessionId: sessionId,
      pendingDrafts: const [
        MemoryDraft(id: draftId, messageIds: ['m1'], content: 'old content'),
      ],
    );
    await container.read(memoryBookRepoProvider).put(book);
    await container.read(chatProvider(charId).future);

    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, child) {
            widgetRef = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    final queue = MemoryBookWriteQueue(
      readLatest: () => book,
      publish: (updated) => book = updated,
      persist: container.read(memoryBookRepoProvider).put,
    );
    final controller = MemoryDraftGenerationController(
      ref: widgetRef,
      charId: charId,
      sessionId: sessionId,
      settingsMapper: const MemorySettingsMapper(),
      bookGetter: () => book,
      persistMutation: queue.mutate,
      generate:
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
    );
    addTearDown(controller.dispose);

    String? reported;
    await controller.generateDraft(
      draftId,
      onStart: () {},
      onComplete: () => fail('generation was supposed to fail'),
      onError: (message) => reported = message,
    );
    await tester.pump();

    final persisted = (await container
        .read(memoryBookRepoProvider)
        .getBySessionId(sessionId))!;
    return (
      draft: persisted.pendingDrafts.single,
      reported: reported ?? (throw StateError('onError was never called')),
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

  testWidgets('a failed draft keeps the provider reason, not the Dio dump', (
    tester,
  ) async {
    final failure = await generationFailing(tester, blockedByProvider());

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

  testWidgets('the toast says the same thing the card does', (tester) async {
    final failure = await generationFailing(tester, blockedByProvider());

    expect(failure.reported, failure.draft.error);
  });

  testWidgets('the draft keeps its content and asks to be generated again', (
    tester,
  ) async {
    final failure = await generationFailing(tester, blockedByProvider());

    expect(failure.draft.content, 'old content');
    expect(failure.draft.status, 'needs_regeneration');
  });

  testWidgets('a failure that is not a provider rejection still reads', (
    tester,
  ) async {
    final failure = await generationFailing(
      tester,
      StateError('memory pipeline produced nothing'),
    );

    expect(failure.draft.error, contains('memory pipeline produced nothing'));
  });
}
