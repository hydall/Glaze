import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/services/cleaner_run_registry.dart';

void main() {
  const key = CleanerRunKey(sessionId: 'session', messageId: 'message');

  test('latest same-key run cancels and waits for prior cleanup', () async {
    final registry = CleanerRunRegistry();
    final firstStarted = Completer<void>();
    final allowCleanup = Completer<void>();
    final events = <String>[];
    late CancelToken firstToken;

    final first = registry.run(key, (lease) async {
      firstToken = CancelToken();
      lease.registerCancelToken(firstToken);
      events.add('first-start');
      firstStarted.complete();
      await firstToken.whenCancel;
      events.add('first-cleanup-start');
      await allowCleanup.future;
      events.add('first-cleanup-end');
    });
    await firstStarted.future;

    final second = registry.run(key, (_) async {
      events.add('second-start');
    });
    await firstToken.whenCancel;
    await Future<void>.delayed(Duration.zero);

    expect(events, ['first-start', 'first-cleanup-start']);
    allowCleanup.complete();
    await Future.wait([first, second]);
    expect(events, [
      'first-start',
      'first-cleanup-start',
      'first-cleanup-end',
      'second-start',
    ]);
  });

  test('superseded queued run never starts', () async {
    final registry = CleanerRunRegistry();
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    var secondStarted = false;
    var thirdStarted = false;

    final first = registry.run(key, (_) async {
      firstStarted.complete();
      await finishFirst.future;
    });
    await firstStarted.future;
    final second = registry.run(key, (_) async => secondStarted = true);
    final third = registry.run(key, (_) async => thirdStarted = true);

    finishFirst.complete();
    await Future.wait([first, second, third]);
    expect(secondStarted, isFalse);
    expect(thirdStarted, isTrue);
  });

  test('distinct keys do not block each other', () async {
    final registry = CleanerRunRegistry();
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    var distinctStarted = false;

    final first = registry.run(key, (_) async {
      firstStarted.complete();
      await finishFirst.future;
    });
    await firstStarted.future;
    await registry.run(
      const CleanerRunKey(sessionId: 'session', messageId: 'other'),
      (_) async => distinctStarted = true,
    );

    expect(distinctStarted, isTrue);
    finishFirst.complete();
    await first;
  });

  test('shared-state ownership follows the latest distinct-key run', () async {
    final registry = CleanerRunRegistry();
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    late CleanerRunLease firstLease;
    late CleanerRunLease secondLease;

    final first = registry.run(key, (lease) async {
      firstLease = lease;
      firstStarted.complete();
      await finishFirst.future;
    });
    await firstStarted.future;
    await registry.run(
      const CleanerRunKey(sessionId: 'other', messageId: 'message'),
      (lease) async {
        secondLease = lease;
        expect(firstLease.isCurrent, isTrue);
        expect(firstLease.ownsSharedState, isFalse);
        expect(secondLease.ownsSharedState, isTrue);
      },
    );

    expect(firstLease.ownsSharedState, isFalse);
    finishFirst.complete();
    await first;
  });
}
