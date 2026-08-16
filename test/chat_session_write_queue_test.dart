import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/chat_session_write_queue.dart';

/// Regression tests for the shared session write queue.
///
/// Message deletion publishes the shortened list optimistically and commits in
/// the background, while every other session mutation (variation switch, edit,
/// hide) commits by re-reading the *durable* row. Run concurrently, the second
/// reads the pre-delete message list and writes it straight back — which is how
/// deleted messages came back the moment you flipped a variation.
void main() {
  test('operations run in enqueue order, never overlapping', () async {
    final queue = ChatSessionWriteQueue();
    final events = <String>[];

    final first = Completer<void>();
    final second = Completer<void>();

    final a = queue.run(() async {
      events.add('a:start');
      await first.future;
      events.add('a:end');
      return 'a';
    });
    final b = queue.run(() async {
      events.add('b:start');
      await second.future;
      events.add('b:end');
      return 'b';
    });

    // The second operation must not have started while the first is pending.
    await Future<void>.delayed(Duration.zero);
    expect(events, ['a:start']);

    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['a:start', 'a:end', 'b:start']);

    second.complete();
    expect(await a, 'a');
    expect(await b, 'b');
    expect(events, ['a:start', 'a:end', 'b:start', 'b:end']);
  });

  test('a failed operation does not block the ones behind it', () async {
    final queue = ChatSessionWriteQueue();
    final ran = <String>[];

    final failing = queue.run<void>(() async {
      ran.add('failing');
      throw StateError('commit failed');
    });

    final following = queue.run(() async {
      ran.add('following');
      return 42;
    });

    // The error still reaches the caller that enqueued it.
    await expectLater(failing, throwsStateError);
    expect(await following, 42);
    expect(ran, ['failing', 'following']);
  });

  test('an idle queue still runs and returns each operation', () async {
    final queue = ChatSessionWriteQueue();
    expect(await queue.run(() async => 1), 1);
    expect(await queue.run(() async => 2), 2);
  });

  test('settle waits for pending writes', () async {
    final queue = ChatSessionWriteQueue();
    final write = Completer<void>();
    var settled = false;

    unawaited(queue.run(() => write.future));
    final barrier = queue.settle().then((_) => settled = true);

    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    write.complete();
    await barrier;
    expect(settled, isTrue);
  });

  test('settle includes writes enqueued while it is waiting', () async {
    final queue = ChatSessionWriteQueue();
    final first = Completer<void>();
    final second = Completer<void>();
    var settled = false;

    unawaited(queue.run(() => first.future));
    final barrier = queue.settle().then((_) => settled = true);
    unawaited(queue.run(() => second.future));

    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    second.complete();
    await barrier;
    expect(settled, isTrue);
  });

  group('publication claims', () {
    test('only the newest claim may repaint', () {
      final queue = ChatSessionWriteQueue();

      final swipe = queue.beginPublication();
      expect(queue.isCurrentPublication(swipe), isTrue);

      // The delete paints its shortened list, superseding the swipe that has
      // not committed yet. When that swipe's commit finally returns a
      // pre-delete row it must not put the bubbles back.
      final delete = queue.beginPublication();
      expect(queue.isCurrentPublication(swipe), isFalse);
      expect(queue.isCurrentPublication(delete), isTrue);
    });

    test('claims stay valid until something newer is claimed', () {
      final queue = ChatSessionWriteQueue();
      final only = queue.beginPublication();
      expect(queue.isCurrentPublication(only), isTrue);
      expect(queue.isCurrentPublication(only), isTrue);
    });
  });
}
