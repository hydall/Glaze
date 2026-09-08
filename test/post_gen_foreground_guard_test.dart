import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/services/post_gen_foreground_guard.dart';

void main() {
  group('runWithPostGenForeground', () {
    test('holds foreground until operation completes', () async {
      final events = <String>[];

      final result = await runWithPostGenForeground(
        onStarted: () async => events.add('started'),
        action: () async {
          events.add('action');
          return 42;
        },
        onFinished: () async => events.add('finished'),
      );

      expect(result, 42);
      expect(events, ['started', 'action', 'finished']);
    });

    test('releases foreground when operation throws', () async {
      final events = <String>[];

      await expectLater(
        runWithPostGenForeground<void>(
          onStarted: () async => events.add('started'),
          action: () async {
            events.add('action');
            throw StateError('boom');
          },
          onFinished: () async => events.add('finished'),
        ),
        throwsStateError,
      );

      expect(events, ['started', 'action', 'finished']);
    });
  });
}
